#!/bin/bash

CONTAINER_NAME="workspace"
LOG_FILE="logs/update-php-fpm.log"
isDevelop=true
isCheck=false

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    if [ "$isDevelop" = true ]; then

        local message="$1"
        local color="${2:-$NC}"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

        echo -e "[$timestamp] ${color}${message}${NC}" | tee -a "$LOG_FILE"
    fi
}

log "Script started" "$GREEN"
log "Looking for information about the system..." "$BLUE"

CPU_CORES=$(docker exec "$CONTAINER_NAME" nproc)
log "Number of processor cores: $CPU_CORES"

MEMORY_AVAILABLE=$(docker exec "$CONTAINER_NAME" awk '/^MemAvailable:/{print $2/1024}' /proc/meminfo)
MEMORY_AVAILABLE=$(echo "$MEMORY_AVAILABLE" | awk '{print int($1+0.5)}')
log "Available free memory: $MEMORY_AVAILABLE MB"

FPM_MEMORY_INFO=$(docker exec "$CONTAINER_NAME" sh -c '

    FPM_PROCESS_MEMORY_TOTAL_KB=0
    FPM_PROCESS_COUNT=0

    for pid in /proc/[0-9]*; do
        if [ -e "$pid/status" ]; then
            cmdline=$(awk -F: "/^Name/{print \$2}" $pid/status | xargs)
            if [ "$cmdline" = "php-fpm" ]; then
                mem=$(awk -F: "/^VmRSS/{print \$2}" $pid/status | xargs | tr -d " kB")
                if [ -n "$mem" ]; then
                    FPM_PROCESS_MEMORY_TOTAL_KB=$(expr $FPM_PROCESS_MEMORY_TOTAL_KB + $mem)
                    FPM_PROCESS_COUNT=$(expr $FPM_PROCESS_COUNT + 1)
                fi
            fi
        fi
    done

    if [ $FPM_PROCESS_COUNT -gt 0 ]; then
        AVERAGE_MEMORY_KB=$(expr $FPM_PROCESS_MEMORY_TOTAL_KB / $FPM_PROCESS_COUNT)
        FPM_PROCESS_MEMORY_TOTAL_MB=$(expr $FPM_PROCESS_MEMORY_TOTAL_KB / 1024)
        FPM_PROCESS_REMAINDER_TOTAL=$(expr $FPM_PROCESS_MEMORY_TOTAL_KB % 1024)
        FPM_PROCESS_MEMORY_AVERAGE_MB=$(expr $AVERAGE_MEMORY_KB / 1024)
        FPM_PROCESS_REMAINDER_AVERAGE=$(expr $AVERAGE_MEMORY_KB % 1024)
        
        echo "$FPM_PROCESS_MEMORY_AVERAGE_MB.$FPM_PROCESS_REMAINDER_AVERAGE"
    else
        echo "5"
    fi
')

FPM_PROCESS_MEMORY_AVERAGE_MB=$(echo "$FPM_MEMORY_INFO" | awk -F. '{print $1}')
log "Average memory value per php-fpm process: $FPM_PROCESS_MEMORY_AVERAGE_MB MB"

log "Calculating new values..." "$BLUE"

MAX_CHILDREN=$((MEMORY_AVAILABLE / FPM_PROCESS_MEMORY_AVERAGE_MB))
log "MAX_CHILDREN counted value: $MAX_CHILDREN"

START_SERVERS=$((4 * CPU_CORES))
log "START_SERVERS counted value: $START_SERVERS"

MIN_SPARE_SERVERS=$((2 * CPU_CORES))
log "MIN_SPARE_SERVERS counted value: $MIN_SPARE_SERVERS"

MAX_SPARE_SERVERS=$((4 * CPU_CORES))
log "MAX_SPARE_SERVERS counted value: $MAX_SPARE_SERVERS"

SED_COMMANDS=$(cat <<EOF
s/pm\.max_children\s*=\s*[0-9]*/pm.max_children = $MAX_CHILDREN/;
s/pm\.start_servers\s*=\s*[0-9]*/pm.start_servers = $START_SERVERS/;
s/pm\.min_spare_servers\s*=\s*[0-9]*/pm.min_spare_servers = $MIN_SPARE_SERVERS/;
s/pm\.max_spare_servers\s*=\s*[0-9]*/pm.max_spare_servers = $MAX_SPARE_SERVERS/;
EOF
)

log "Updating php-fpm configuration..." "$BLUE"

update_output=$(docker exec "$CONTAINER_NAME" bash -c "
    cd /usr/local/etc/php-fpm.d &&
    sed -i '$SED_COMMANDS' www.conf
" 2>&1)

if [ $? -eq 0 ]; then
    log "Configuration update done successfully" "$GREEN"
    docker exec "$CONTAINER_NAME" bash -c "php-fpm reload"

    if [ "$isCheck" = true ]; then
        docker exec "$CONTAINER_NAME" cat /usr/local/etc/php-fpm.d/www.conf
    fi
else
    log "Configuration update failed: $update_output" "$RED"
    log "Script stoped" "$RED"
    exit 1
fi

log "Script finished" "$GREEN"