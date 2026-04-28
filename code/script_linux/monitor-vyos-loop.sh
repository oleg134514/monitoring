#!/bin/bash
# =============================================
# Обёртка для VyOS мониторинга — цикл 10 секунд
# Запускается как systemd-сервис
# =============================================

SCRIPT_DIR="/home/oleg_admin"
CONF_FILE="${SCRIPT_DIR}/agent_vyos.conf"

# Читаем конфиг если есть
if [ -f "$CONF_FILE" ]; then
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        export "$key"="$val"
    done < <(grep -v '^\s*#' "$CONF_FILE" | grep '=')
fi

MONITOR_SERVER="${MONITOR_SERVER:-http://localhost:1234}"

log() { echo "$@" >&2; }

log "Запуск VyOS monitoring loop (интервал 10с)..."

while true; do
    # Путь к скрипту
    if [ -f "${SCRIPT_DIR}/collect_vyos_info.sh" ]; then
        "${SCRIPT_DIR}/collect_vyos_info.sh"
    else
        /usr/local/bin/monitor/collect_vyos_info.sh
    fi
    sleep 10
done
