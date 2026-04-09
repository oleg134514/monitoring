#!/bin/bash

# Мониторинг для VyOS 1.5

# Конфигурация
MEASUREMENT_INTERVAL=2

# Логирование
log() {
    echo "$@" >&2
}

# Безопасная арифметика
safe_math() {
    local expr="$1"
    local default="$2"
    local result

    # Простая реализация через awk (bc может отсутствовать в VyOS)
    result=$(awk "BEGIN {printf \"%.2f\", $expr}" 2>/dev/null || echo "$default")
    echo "$result"
}

# Измерение скорости сети для VyOS (исправленная версия)
measure_network_speed_vyos() {
    local interface="$1"
    local rx_speed=0
    local tx_speed=0

    # Используем /proc/net/dev - более надежно
    if [[ -f "/proc/net/dev" ]]; then
        local stats1=$(grep "^[[:space:]]*$interface:" /proc/net/dev 2>/dev/null)
        if [[ -n "$stats1" ]]; then
            # Парсим RX/TX bytes (формат: interface: rx_bytes rx_packets ... tx_bytes tx_packets ...)
            local rx_bytes1=$(echo "$stats1" | awk '{print $2}')
            local tx_bytes1=$(echo "$stats1" | awk '{print $10}')

            sleep "$MEASUREMENT_INTERVAL"

            local stats2=$(grep "^[[:space:]]*$interface:" /proc/net/dev 2>/dev/null)
            if [[ -n "$stats2" ]]; then
                local rx_bytes2=$(echo "$stats2" | awk '{print $2}')
                local tx_bytes2=$(echo "$stats2" | awk '{print $10}')

                # Расчет разницы с проверкой переполнения 32-битного счетчика
                local rx_diff=0 tx_diff=0

                # Обработка переполнения (4.29 GB = 4294967296 bytes)
                if [[ $rx_bytes2 -lt $rx_bytes1 ]]; then
                    rx_diff=$((rx_bytes2 + 4294967296 - rx_bytes1))
                else
                    rx_diff=$((rx_bytes2 - rx_bytes1))
                fi

                if [[ $tx_bytes2 -lt $tx_bytes1 ]]; then
                    tx_diff=$((tx_bytes2 + 4294967296 - tx_bytes1))
                else
                    tx_diff=$((tx_bytes2 - tx_bytes1))
                fi

                # Конвертация bytes/s в Mbps
                # bytes * 8 bits/byte / interval seconds / 1000000 bits/Mbit
                rx_speed=$(safe_math "$rx_diff * 8 / $MEASUREMENT_INTERVAL / 1000000" "0")
                tx_speed=$(safe_math "$tx_diff * 8 / $MEASUREMENT_INTERVAL / 1000000" "0")

                log "DEBUG: rx_diff=$rx_diff, tx_diff=$tx_diff, rx_speed=$rx_speed, tx_speed=$tx_speed" >&2
            fi
        fi
    fi

    # Форматирование вывода
    rx_speed=$(printf "%.2f" "$rx_speed" 2>/dev/null || echo "0.00")
    tx_speed=$(printf "%.2f" "$tx_speed" 2>/dev/null || echo "0.00")

    echo "$rx_speed $tx_speed"
}

# Основная функция для VyOS
collect_all_vyos() {
    log "Начало сбора метрик (VyOS)..."

    # Системная информация
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "N/D")
    local hostname=$(hostname 2>/dev/null || echo "vyos")

    # Uptime - более аккуратный парсинг
    local uptime_raw=$(uptime 2>/dev/null || echo "")
    local uptime="N/D"
    if [[ -n "$uptime_raw" ]]; then
        # Берем все после "up" до первой запятой с нагрузкой
        uptime=$(echo "$uptime_raw" | sed 's/.*up //;s/, *load average.*//')
    fi

    # Версия VyOS - исправленный парсинг
    local vyos_version_raw=$(show version 2>/dev/null | grep "Version:" | head -1 || echo "")
    local vyos_version="N/D"
    if [[ -n "$vyos_version_raw" ]]; then
        vyos_version=$(echo "$vyos_version_raw" | awk '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    # CPU информация - load average
    local load_avg_raw=$(uptime 2>/dev/null | grep -o "load average: [0-9.]*, [0-9.]*, [0-9.]*" || echo "")
    local load_avg="0.00"
    if [[ -n "$load_avg_raw" ]]; then
        # Берем среднюю за 1 минуту (первое значение)
        load_avg=$(echo "$load_avg_raw" | awk -F'[:,]' '{print $2}' | awk '{print $1}')
    fi

    # Подробная информация о CPU через top
    local cpu_info="N/D"
    if command -v top >/dev/null; then
        cpu_info=$(top -bn1 | grep "%Cpu" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "N/D")
    fi

    # Память через /proc/meminfo
    local mem_total_kb=$(grep -i "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local mem_free_kb=$(grep -i "^MemFree:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local mem_available_kb=$(grep -i "^MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")

    # Конвертация в GB
    local mem_total_gb=$(safe_math "$mem_total_kb / 1048576" "0")
    local mem_free_gb=$(safe_math "$mem_free_kb / 1048576" "0")
    local mem_available_gb=$(safe_math "$mem_available_kb / 1048576" "0")
    local mem_used_gb=$(safe_math "$mem_total_gb - $mem_available_gb" "0")

    # Диски - исправленный парсинг
    local disk_total_gb=0
    local disk_used_gb=0
    local disk_free_gb=0

    local disk_info=$(df -k / 2>/dev/null | tail -1)  # Используем -k для байтов
    if [[ -n "$disk_info" ]]; then
        disk_total_gb=$(safe_math "$(echo "$disk_info" | awk '{print $2}') / 1048576" "0")
        disk_used_gb=$(safe_math "$(echo "$disk_info" | awk '{print $3}') / 1048576" "0")
        disk_free_gb=$(safe_math "$(echo "$disk_info" | awk '{print $4}') / 1048576" "0")
    fi

    # Сеть - определяем основной интерфейс
    local net_iface="eth0"
    if command -v ip >/dev/null; then
        # Проверяем доступность eth0, иначе берем первый не-loopback
        if ip link show eth0 >/dev/null 2>&1; then
            net_iface="eth0"
        else
            net_iface=$(ip link show 2>/dev/null | grep -o "^[0-9]\+: [^:]*" | awk '{print $2}' | tr -d ':' | grep -v "lo" | head -1 || echo "eth0")
        fi
    fi

    # Измеряем скорость сети (исправленная функция)
    local rx_mbps=0
    local tx_mbps=0

    if [[ "$net_iface" != "N/D" ]] && [[ "$net_iface" != "" ]]; then
        log "Измерение скорости на интерфейсе: $net_iface" >&2
        local speeds=$(measure_network_speed_vyos "$net_iface")
        rx_mbps=$(echo "$speeds" | awk '{print $1}')
        tx_mbps=$(echo "$speeds" | awk '{print $2}')
    fi

    # Общая статистика сети
    local total_rx_gb=0
    local total_tx_gb=0

    if [[ -f "/proc/net/dev" ]] && [[ "$net_iface" != "N/D" ]] && [[ "$net_iface" != "" ]]; then
        local stats=$(grep "^[[:space:]]*$net_iface:" /proc/net/dev 2>/dev/null)
        if [[ -n "$stats" ]]; then
            local total_rx_bytes=$(echo "$stats" | awk '{print $2}')
            local total_tx_bytes=$(echo "$stats" | awk '{print $10}')

            total_rx_gb=$(safe_math "$total_rx_bytes / 1073741824" "0")
            total_tx_gb=$(safe_math "$total_tx_bytes / 1073741824" "0")
        fi
    fi

# В конце collect_all_vyos() замените на:

    local json_output="{"
    json_output+="\"ip_server\": \"172.16.76.0\","
    json_output+="\"system\":{"
    json_output+="\"timestamp\":\"$timestamp\","
    json_output+="\"hostname\":\"$hostname\","
    json_output+="\"uptime\":\"$uptime\","
    json_output+="\"type\":\"vyos\","
    json_output+="\"version\":\"$vyos_version\""
    json_output+="},"
    json_output+="\"cpu\":{"
    json_output+="\"load_avg\":$load_avg,"
    json_output+="\"info\":\"$cpu_info\""
    json_output+="},"
    json_output+="\"memory\":{"
    json_output+="\"total_gb\":$mem_total_gb,"
    json_output+="\"used_gb\":$mem_used_gb,"
    json_output+="\"free_gb\":$mem_free_gb,"
    json_output+="\"available_gb\":$mem_available_gb"
    json_output+="},"
    json_output+="\"disk\":{"
    json_output+="\"total_gb\":$disk_total_gb,"
    json_output+="\"used_gb\":$disk_used_gb,"
    json_output+="\"free_gb\":$disk_free_gb"
    json_output+="},"
    json_output+="\"network\":{"
    json_output+="\"interface\":\"$net_iface\","
    json_output+="\"rx_mbps\":$rx_mbps,"
    json_output+="\"tx_mbps\":$tx_mbps,"
    json_output+="\"total_rx_gb\":$total_rx_gb,"
    json_output+="\"total_tx_gb\":$total_tx_gb"
    json_output+="}"
    json_output+="}"

    echo "$json_output" | nc -w 3 000.000.000.111 1234 2>/dev/null #  000.000.000.111:1234 - заменить на адрес и порт сервера получателя
    log "Метрики VyOS с ip_server=000.000.000.000 отправлены на 000.000.000.111:1234" >&2 # 000.000.000.000 - заменить на ip сервера PVE, 000.000.000.111:1234 - заменить на адрес и порт сервера получателя
}

# Определение ОС
detect_os_and_run() {
    # Проверяем, что это VyOS
    if [[ -f /etc/vyos_version ]] || [[ -d /opt/vyatta ]] || command -v show >/dev/null 2>&1; then
        collect_all_vyos
    else
        echo "{\"error\":\"Not a VyOS system\"}"
        exit 1
    fi
}

# Запуск
detect_os_and_run
