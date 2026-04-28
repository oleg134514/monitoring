#!/bin/sh
# =============================================
# Обёртка для XigmaNAS мониторинга — цикл 60 секунд
# Запускается через rc.d или в фоне
# =============================================

SCRIPT_DIR="/root/monitor"
CONF_FILE="${SCRIPT_DIR}/agent_xigmanas.conf"

# Читаем конфиг если есть
if [ -f "$CONF_FILE" ]; then
    while IFS='=' read -r key val; do
        [ -z "$key" ] && continue
        case "$key" in
            \#*) continue ;;
        esac
        export "$key"="$val"
    done <<EOF
$(grep -v '^\s*#' "$CONF_FILE" | grep '=')
EOF
fi

log() { echo "$@" >&2; }

log "Запуск XigmaNAS monitoring loop (интервал 60с)..."

while true; do
    if [ -f "${SCRIPT_DIR}/collect_status_xigmanas_info.sh" ]; then
        /usr/local/bin/bash "${SCRIPT_DIR}/collect_status_xigmanas_info.sh"
    else
        /usr/local/bin/bash /usr/local/bin/monitor/collect_status_xigmanas_info.sh
    fi
    sleep 60
done

