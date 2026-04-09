#!/bin/bash

# Мониторинг для Proxmox VE 9 (Debian 12)

# Конфигурация
MEASUREMENT_INTERVAL=2  # Увеличено для точности измерения низких скоростей
MAX_SNAPSHOTS=5

# Логирование
log() {
    echo "$@" >&2
}

# Безопасное выполнение команд
safe_cmd() {
    local cmd="$1"
    local default="$2"
    local result
    result=$(eval "$cmd" 2>/dev/null || echo "")
    if [[ -z "$result" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

# Безопасная арифметика
safe_math() {
    local expr="$1"
    local default="$2"
    local result
    result=$(echo "scale=2; $expr" | bc 2>/dev/null || echo "$default")
    echo "$result"
}

# Получение реальной частоты CPU для Linux
get_cpu_frequency() {
    local real_freq="N/D"

    # Метод 1: Через /proc/cpuinfo
    local cpuinfo_freq=$(grep -i "cpu mhz" /proc/cpuinfo 2>/dev/null | head -1 | awk -F: '{print $2}' | tr -d ' ' | cut -d. -f1)
    if [[ -n "$cpuinfo_freq" && "$cpuinfo_freq" =~ ^[0-9]+$ ]]; then
        real_freq="$cpuinfo_freq"
    else
        # Метод 2: Через lscpu
        if command -v lscpu >/dev/null; then
            local lscpu_freq=$(lscpu | grep -i "cpu mhz" | awk '{print $3}' | cut -d. -f1)
            if [[ -n "$lscpu_freq" && "$lscpu_freq" =~ ^[0-9]+$ ]]; then
                real_freq="$lscpu_freq"
            fi
        fi

        # Метод 3: Через cpufreq-info (если установлен)
        if [[ "$real_freq" == "N/D" ]] && command -v cpufreq-info >/dev/null; then
            local cpufreq_info=$(cpufreq-info -f 2>/dev/null | head -1)
            if [[ -n "$cpufreq_info" && "$cpufreq_info" =~ ^[0-9]+$ ]]; then
                real_freq="$cpufreq_info"
            fi
        fi

        # Метод 4: Через sysfs
        if [[ "$real_freq" == "N/D" ]]; then
            local sysfs_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
            if [[ -n "$sysfs_freq" && "$sysfs_freq" =~ ^[0-9]+$ ]]; then
                # KHz в MHz
                real_freq=$((sysfs_freq / 1000))
            fi
        fi
    fi

    echo "$real_freq"
}

# Получение температуры CPU для Linux
get_cpu_temperature() {
    local temp="N/D"

    # Метод 1: Через IPMI (если есть)
    if command -v ipmitool >/dev/null; then
        local ipmi_out=$(ipmitool sdr type temperature 2>/dev/null)
        if [[ -n "$ipmi_out" ]]; then
            local temp_line=$(echo "$ipmi_out" | grep -i "cpu\|system" | head -1)
            if [[ -n "$temp_line" ]]; then
                local temp_val=$(echo "$temp_line" | tr -d '\n\r' | sed 's/.*|[[:space:]]*//' | grep -o '[0-9]\+' | head -1)
                [[ -n "$temp_val" ]] && temp="$temp_val"
            fi
        fi
    fi

    # Метод 2: Через lm-sensors (если установлен)
    if [[ "$temp" == "N/D" ]] && command -v sensors >/dev/null; then
        local sensors_output=$(sensors 2>/dev/null)
        if [[ -n "$sensors_output" ]]; then
            # Ищем температуру CPU в выводе sensors
            local temp_val=$(echo "$sensors_output" | grep -i "core\|cpu\|package" | head -1 | grep -o '+[0-9]*\.[0-9]*°C' | grep -o '[0-9]*' | head -1)
            if [[ -n "$temp_val" ]]; then
                temp="$temp_val"
            fi
        fi
    fi

    # Метод 3: Через sysfs (hwmon)
    if [[ "$temp" == "N/D" ]]; then
        # Ищем hwmon устройства для CPU
        for hwmon in /sys/class/hwmon/hwmon*; do
            if [[ -d "$hwmon" ]]; then
                local name=$(cat "$hwmon/name" 2>/dev/null)
                if [[ "$name" =~ (coretemp|k10temp|zenpower) ]]; then
                    for temp_file in "$hwmon"/temp*_input; do
                        if [[ -f "$temp_file" ]]; then
                            local temp_val=$(cat "$temp_file" 2>/dev/null)
                            if [[ -n "$temp_val" ]]; then
                                # millidegrees Celsius to degrees Celsius
                                temp=$((temp_val / 1000))
                                break 2
                            fi
                        fi
                    done
                fi
            fi
        done
    fi

    # Метод 4: Через thermal zone
    if [[ "$temp" == "N/D" ]]; then
        for thermal_zone in /sys/class/thermal/thermal_zone*; do
            if [[ -d "$thermal_zone" ]]; then
                local type=$(cat "$thermal_zone/type" 2>/dev/null)
                if [[ "$type" =~ (x86_pkg_temp|cpu-thermal) ]]; then
                    local temp_val=$(cat "$thermal_zone/temp" 2>/dev/null)
                    if [[ -n "$temp_val" ]]; then
                        # millidegrees Celsius to degrees Celsius
                        temp=$((temp_val / 1000))
                        break
                    fi
                fi
            fi
        done
    fi

    echo "$temp"
}

# Универсальное измерение скорости сети для Linux
measure_network_speed_universal() {
    local interface="$1"
    local rx_speed=0
    local tx_speed=0

    # Определяем наилучший метод получения статистики
    local method=""
    local rx_bytes1=0 tx_bytes1=0
    local rx_bytes2=0 tx_bytes2=0

    # Пробуем разные методы в порядке надежности
    if [[ -f "/sys/class/net/$interface/statistics/rx_bytes" ]]; then
        # Метод 1: /sys/class/net/ (самый быстрый и надежный для Linux)
        method="sysfs"
        rx_bytes1=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo "0")
        tx_bytes1=$(cat "/sys/class/net/$interface/statistics/tx_bytes" 2>/dev/null || echo "0")
    elif [[ -f "/proc/net/dev" ]]; then
        # Метод 2: /proc/net/dev (работает всегда)
        method="proc"
        local stats1=$(grep "^[[:space:]]*$interface:" /proc/net/dev 2>/dev/null)
        if [[ -n "$stats1" ]]; then
            rx_bytes1=$(echo "$stats1" | awk '{print $2}')
            tx_bytes1=$(echo "$stats1" | awk '{print $10}')
        fi
    elif command -v ip >/dev/null; then
        # Метод 3: ip -s (резервный метод)
        method="ip"
        local ip_output1=$(ip -s link show "$interface" 2>/dev/null)
        if [[ -n "$ip_output1" ]]; then
            rx_bytes1=$(echo "$ip_output1" | grep -A1 "RX:" | tail -1 | awk '{print $1}')
            tx_bytes1=$(echo "$ip_output1" | grep -A1 "TX:" | tail -1 | awk '{print $1}')
        fi
    fi

    # Если получили начальные значения, делаем замер через интервал
    if [[ "$method" != "" && "$rx_bytes1" != "0" ]]; then
        # Ждем дольше для низких скоростей, но не слишком долго
        local actual_interval=$MEASUREMENT_INTERVAL

        # Для низких скоростей (< 100 Mbps) увеличиваем интервал для точности
        if [[ $actual_interval -lt 2 ]]; then
            actual_interval=2
        fi

        sleep "$actual_interval"

        # Второй замер тем же методом
        case "$method" in
            "sysfs")
                rx_bytes2=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo "0")
                tx_bytes2=$(cat "/sys/class/net/$interface/statistics/tx_bytes" 2>/dev/null || echo "0")
                ;;
            "proc")
                local stats2=$(grep "^[[:space:]]*$interface:" /proc/net/dev 2>/dev/null)
                if [[ -n "$stats2" ]]; then
                    rx_bytes2=$(echo "$stats2" | awk '{print $2}')
                    tx_bytes2=$(echo "$stats2" | awk '{print $10}')
                fi
                ;;
            "ip")
                local ip_output2=$(ip -s link show "$interface" 2>/dev/null)
                if [[ -n "$ip_output2" ]]; then
                    rx_bytes2=$(echo "$ip_output2" | grep -A1 "RX:" | tail -1 | awk '{print $1}')
                    tx_bytes2=$(echo "$ip_output2" | grep -A1 "TX:" | tail -1 | awk '{print $1}')
                fi
                ;;
        esac

        # Расчет скорости с проверкой переполнения счетчика (32-bit vs 64-bit)
        local rx_diff=0 tx_diff=0

        # Обработка переполнения 32-битного счетчика (4.29 GB)
        if [[ $rx_bytes2 -lt $rx_bytes1 ]]; then
            # Счетчик переполнился, добавляем 2^32 = 4294967296
            rx_diff=$((rx_bytes2 + 4294967296 - rx_bytes1))
        else
            rx_diff=$((rx_bytes2 - rx_bytes1))
        fi

        if [[ $tx_bytes2 -lt $tx_bytes1 ]]; then
            tx_diff=$((tx_bytes2 + 4294967296 - tx_bytes1))
        else
            tx_diff=$((tx_bytes2 - tx_bytes1))
        fi

        # Конвертация в Mbps (биты в секунду)
        # bytes * 8 bits/byte / interval seconds / 1000000 bits/Mbit
        local rx_bps=$((rx_diff * 8))
        local tx_bps=$((tx_diff * 8))

        # Для высоких скоростей (> 1 Gbps) используем более точные формулы
        if [[ $rx_bps -gt 1000000000 ]] || [[ $tx_bps -gt 1000000000 ]]; then
            # Для Гбитных скоростей: байты в секунду * 8 / 1000000000
            rx_speed=$(safe_math "$rx_bps / $actual_interval / 1000000" "0")
            tx_speed=$(safe_math "$tx_bps / $actual_interval / 1000000" "0")
        else
            # Для низких скоростей: более точный расчет с плавающей точкой
            rx_speed=$(safe_math "scale=4; $rx_bps / $actual_interval / 1000000" "0")
            tx_speed=$(safe_math "scale=4; $tx_bps / $actual_interval / 1000000" "0")
        fi
    fi

    # Форматирование вывода
    # Для низких скоростей показываем больше знаков после запятой
    if (( $(echo "$rx_speed < 0.1" | bc -l 2>/dev/null || echo 0) )); then
        rx_speed=$(printf "%.4f" "$rx_speed" 2>/dev/null || echo "0.0000")
        tx_speed=$(printf "%.4f" "$tx_speed" 2>/dev/null || echo "0.0000")
    elif (( $(echo "$rx_speed < 10" | bc -l 2>/dev/null || echo 0) )); then
        rx_speed=$(printf "%.2f" "$rx_speed" 2>/dev/null || echo "0.00")
        tx_speed=$(printf "%.2f" "$tx_speed" 2>/dev/null || echo "0.00")
    else
        rx_speed=$(printf "%.1f" "$rx_speed" 2>/dev/null || echo "0.0")
        tx_speed=$(printf "%.1f" "$tx_speed" 2>/dev/null || echo "0.0")
    fi

    echo "$rx_speed $tx_speed"
}

# Получение информации о памяти для Linux
get_memory_info_linux() {
    # Читаем /proc/meminfo
    local mem_total_kb=$(grep -i "^MemTotal:" /proc/meminfo | awk '{print $2}')
    local mem_free_kb=$(grep -i "^MemFree:" /proc/meminfo | awk '{print $2}')
    local mem_available_kb=$(grep -i "^MemAvailable:" /proc/meminfo | awk '{print $2}')
    local buffers_kb=$(grep -i "^Buffers:" /proc/meminfo | awk '{print $2}')
    local cached_kb=$(grep -i "^Cached:" /proc/meminfo | awk '{print $2}')

    # Конвертируем в GB
    local mem_total_gb=$(safe_math "$mem_total_kb / 1048576" "0")
    local mem_free_gb=$(safe_math "$mem_free_kb / 1048576" "0")
    local mem_available_gb=$(safe_math "$mem_available_kb / 1048576" "0")

    # Использованная память = Total - Available (более точный расчет для Linux)
    local mem_used_gb=$(safe_math "$mem_total_gb - $mem_available_gb" "0")

    # Округляем
    mem_total_gb=$(printf "%.2f" "$mem_total_gb")
    mem_used_gb=$(printf "%.2f" "$mem_used_gb")
    mem_free_gb=$(printf "%.2f" "$mem_free_gb")
    mem_available_gb=$(printf "%.2f" "$mem_available_gb")

    echo "$mem_total_gb $mem_used_gb $mem_free_gb $mem_available_gb"
}

# Получение информации о дисках для Linux
get_disk_info_linux() {
    local disk="$1"
    local disk_type="UNKNOWN"
    local health="N/D"
    local temp="N/D"
    local model="N/D"
    local serial="N/D"
    local health_percent=100

    # Определяем тип диска по имени
    if [[ "$disk" =~ ^sd[a-z]$ ]] || [[ "$disk" =~ ^nvme[0-9]n[0-9]$ ]]; then
        # Проверяем, SSD это или HDD
        local is_ssd=$(cat "/sys/block/$disk/queue/rotational" 2>/dev/null || echo "1")
        if [[ "$is_ssd" == "0" ]]; then
            disk_type="SSD"
        else
            disk_type="HDD"
        fi

        # SMART данные
        if command -v smartctl >/dev/null; then
            local smart_output=$(smartctl -a "/dev/$disk" 2>/dev/null)

            if [[ $? -eq 0 ]]; then
                # Модель
                model=$(echo "$smart_output" | grep -i "device model:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/"/\\"/g')
                [[ -z "$model" ]] && model=$(echo "$smart_output" | grep -i "product:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/"/\\"/g')

                # Серийник
                serial=$(echo "$smart_output" | grep -i "serial number:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                # Температура
                temp=$(echo "$smart_output" | grep -i "temperature_celsius" | awk '{print $10}')
                if [[ -z "$temp" ]]; then
                    temp=$(echo "$smart_output" | grep -i "current drive temperature" | awk '{print $4}')
                fi

                # Здоровье
                if echo "$smart_output" | grep -q "PASSED\|OK"; then
                    health="PASSED"
                elif echo "$smart_output" | grep -q "FAILED"; then
                    health="FAILED"
                    health_percent=0
                else
                    health="UNKNOWN"
                fi

                # Процент здоровья для SSD
                if [[ "$disk_type" == "SSD" ]]; then
                    local wear_leveling=$(echo "$smart_output" | grep -i "wear_leveling_count\|media_wearout_indicator" | awk '{print $4}')
                    local percent_used=$(echo "$smart_output" | grep -i "percentage_used\|percent_lifetime_used" | awk '{print $3}' | tr -d '%')

                    if [[ -n "$wear_leveling" && "$wear_leveling" != "-" ]]; then
                        health_percent="$wear_leveling"
                    elif [[ -n "$percent_used" ]]; then
                        health_percent=$((100 - percent_used))
                    fi

                    # Корректируем границы
                    if [[ "$health_percent" -gt 100 ]]; then
                        health_percent=100
                    elif [[ "$health_percent" -lt 0 ]]; then
                        health_percent=0
                    fi
                fi
            fi
        fi
    elif [[ "$disk" =~ ^md[0-9]+$ ]]; then
        disk_type="RAID"
    fi

    echo "$health|$temp|$model|$serial|$health_percent|$disk_type"
}

# Получение информации о ZFS для Linux
get_zfs_info_linux() {
    local zfs_data="[]"

    if command -v zpool >/dev/null; then
        local pools=$(zpool list -H -o name 2>/dev/null)
        local pool_array="["
        local first_pool=true

        for pool in $pools; do
            [[ "$first_pool" == true ]] || pool_array+=","
            first_pool=false

            local pool_info=$(zpool list -H -o size,free,health "$pool" 2>/dev/null || echo "0 0 UNKNOWN")
            local pool_size=$(echo "$pool_info" | awk '{print $1}')
            local pool_free=$(echo "$pool_info" | awk '{print $2}')
            local pool_health=$(echo "$pool_info" | awk '{print $3}')

            # Конвертация в GB
            local size_gb=0
            local free_gb=0

            if [[ "$pool_size" =~ ([0-9.]+)T ]]; then
                size_gb=$(safe_math "${BASH_REMATCH[1]} * 1024" "0")
            elif [[ "$pool_size" =~ ([0-9.]+)G ]]; then
                size_gb="${BASH_REMATCH[1]}"
            elif [[ "$pool_size" =~ ([0-9.]+)M ]]; then
                size_gb=$(safe_math "${BASH_REMATCH[1]} / 1024" "0")
            else
                size_gb=$(safe_math "$pool_size / 1073741824" "0")
            fi

            if [[ "$pool_free" =~ ([0-9.]+)T ]]; then
                free_gb=$(safe_math "${BASH_REMATCH[1]} * 1024" "0")
            elif [[ "$pool_free" =~ ([0-9.]+)G ]]; then
                free_gb="${BASH_REMATCH[1]}"
            elif [[ "$pool_free" =~ ([0-9.]+)M ]]; then
                free_gb=$(safe_math "${BASH_REMATCH[1]} / 1024" "0")
            else
                free_gb=$(safe_math "$pool_free / 1073741824" "0")
            fi

            # Снапшоты
            local snapshots_array="[]"
            local snapshots=$(zfs list -t snapshot -o name,creation -s creation -r "$pool" 2>/dev/null | tail -n +2 | tail -n "$MAX_SNAPSHOTS")

            if [[ -n "$snapshots" ]]; then
                snapshots_array="["
                local first_snap=true
                while IFS= read -r snap; do
                    [[ "$first_snap" == true ]] || snapshots_array+=","
                    first_snap=false

                    local snap_name=$(echo "$snap" | awk '{print $1}' | sed 's/.*@//')
                    local snap_date=$(echo "$snap" | awk '{print $2" "$3" "$4" "$5}')
                    local snap_iso="N/D"

                    if [[ -n "$snap_date" ]]; then
                        snap_iso=$(date -d "$snap_date" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "N/D")
                    fi

                    snapshots_array+="{\"name\":\"$snap_name\",\"created\":\"$snap_iso\"}"
                done <<< "$snapshots"
                snapshots_array+="]"
            fi

            pool_array+="{\"name\":\"$pool\",\"size_gb\":$size_gb,\"free_gb\":$free_gb,\"health\":\"$pool_health\",\"snapshots\":$snapshots_array}"
        done

        pool_array+="]"
        zfs_data="$pool_array"
    fi

    echo "$zfs_data"
}

# Улучшенное определение активного интерфейса для Proxmox
get_active_interface_linux() {
    # В Proxmox vmbr0 - это мост, но статистика на нем может быть недоступна
    # Ищем физический интерфейс, который входит в мост

    # Список всех физических интерфейсов
    local phys_ifaces=$(ls /sys/class/net/ 2>/dev/null | grep -E '^enp|^eth|^ens|^eno' | grep -v "\.\|\:")

    # Если нашли физические интерфейсы
    for iface in $phys_ifaces; do
        # Проверяем, есть ли статистика
        if [[ -f "/sys/class/net/$iface/statistics/rx_bytes" ]]; then
            echo "$iface"
            return 0
        fi
    done

    # Если не нашли физические, ищем любые с IP
    local ip_iface=$(ip -o -4 addr show 2>/dev/null | grep -v "lo\|docker" | awk '{print $2}' | head -1)
    if [[ -n "$ip_iface" ]]; then
        echo "$ip_iface"
        return 0
    fi

    # Fallback - возвращаем vmbr0
    echo "vmbr0"
}

# Основная функция для Linux
collect_all_linux() {
    log "Начало сбора метрик (Linux)..."

    # Системная информация
    log "Сбор системной информации..."
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hostname=$(hostname -s)
    local uptime_raw=$(safe_cmd "uptime" "")
    local uptime="N/D"
    if [[ -n "$uptime_raw" ]]; then
        uptime=$(echo "$uptime_raw" | sed 's/.*up //;s/,.*//')
    fi

    # CPU информация
    log "Сбор информации о процессоре..."
    local cpu_model=$(grep -i "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/"/\\"/g')
    local cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "0")
    local load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    local cpu_freq_nominal=$(lscpu 2>/dev/null | grep -i "cpu max mhz" | awk '{print $4}' | cut -d. -f1 || echo "0")
    local cpu_freq_real=$(get_cpu_frequency)
    local cpu_temp=$(get_cpu_temperature)

    # Память
    log "Сбор информации о памяти..."
    local memory_info=$(get_memory_info_linux)
    local mem_total_gb=$(echo "$memory_info" | awk '{print $1}')
    local mem_used_gb=$(echo "$memory_info" | awk '{print $2}')
    local mem_free_gb=$(echo "$memory_info" | awk '{print $3}')
    local mem_available_gb=$(echo "$memory_info" | awk '{print $4}')

    # Сеть
    log "Сбор информации о сети..."
    local net_iface=$(get_active_interface_linux)
    local rx_mbps=0
    local tx_mbps=0

    if [[ "$net_iface" != "N/D" ]]; then
        local speeds=$(measure_network_speed_universal "$net_iface")
        rx_mbps=$(echo "$speeds" | awk '{print $1}')
        tx_mbps=$(echo "$speeds" | awk '{print $2}')
    fi

    # ZFS (если используется)
    log "Сбор информации о ZFS..."
    local zfs_data=$(get_zfs_info_linux)

    # Диски
    log "Сбор информации о дисках..."
    local disks_data="[]"
    local disks=$(ls /sys/block/ 2>/dev/null | grep -E '^(sd|nvme|vd|xvd|hd)' || echo "")

    if [[ -n "$disks" ]]; then
        local disk_array="["
        local first_disk=true

        for disk in $disks; do
            # Пропускаем виртуальные и разделы
            if [[ "$disk" =~ [0-9]$ ]] || [[ "$disk" =~ ^(loop|ram|dm-) ]]; then
                continue
            fi

            [[ "$first_disk" == true ]] || disk_array+=","
            first_disk=false

            # Информация о диске
            local disk_info=$(get_disk_info_linux "$disk")
            local health=$(echo "$disk_info" | cut -d'|' -f1)
            local temp=$(echo "$disk_info" | cut -d'|' -f2)
            local model=$(echo "$disk_info" | cut -d'|' -f3)
            local serial=$(echo "$disk_info" | cut -d'|' -f4)
            local health_percent=$(echo "$disk_info" | cut -d'|' -f5)
            local disk_type=$(echo "$disk_info" | cut -d'|' -f6)

            # Размер диска
            local size_sectors=$(cat "/sys/block/$disk/size" 2>/dev/null || echo "0")
            local size_gb=$(safe_math "$size_sectors * 512 / 1073741824" "0")

            disk_array+="{\"device\":\"$disk\",\"type\":\"$disk_type\",\"model\":\"$model\",\"serial\":\"$serial\",\"size_gb\":$size_gb,\"health\":\"$health\",\"health_percent\":$health_percent,\"temperature_c\":\"$temp\"}"
        done

        disk_array+="]"
        disks_data="$disk_array"
    fi

# В конце функции collect_all_linux() замените блок формирования JSON на:

    # Добавляем ip_server в начало
    local json_output="{"
    json_output+="\"ip_server\": \"000.000.000.000\","  # 000.000.000.000 - заменить на ip сервера PVE
    json_output+="\"system\":{\"timestamp\":\"$timestamp\",\"hostname\":\"$hostname\",\"uptime\":\"$uptime\"},"
    json_output+="\"cpu\":{\"model\":\"$cpu_model\",\"frequency_nominal_mhz\":$cpu_freq_nominal,\"frequency_real_mhz\":\"$cpu_freq_real\",\"cores\":$cpu_cores,\"temperature_c\":\"$cpu_temp\",\"load_avg\":$load_avg},"
    json_output+="\"memory\":{\"total_gb\":$mem_total_gb,\"used_gb\":$mem_used_gb,\"free_gb\":$mem_free_gb,\"available_gb\":$mem_available_gb},"
    json_output+="\"network\":{\"interface\":\"$net_iface\",\"rx_mbps\":$rx_mbps,\"tx_mbps\":$tx_mbps},"
    json_output+="\"zfs_pools\":$zfs_data,"
    json_output+="\"disks\":$disks_data"
    json_output+="}"

    # Отправка
    echo "$json_output" | nc -w 5 000.000.000.111 1234 2>/dev/null #  000.000.000.111:1234 - заменить на адрес и порт сервера получателя
    log "Метрики с ip_server=000.000.000.000 отправлены на 000.000.000.111:1234" # 000.000.000.000 - заменить на ip сервера PVE, 000.000.000.111:1234 - заменить на адрес и порт сервера получателя
}

# Определяем ОС и запускаем соответствующую функцию
detect_os_and_run() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "debian" ]] || [[ "$ID" == "ubuntu" ]] || [[ "$ID" =~ centos|rhel|fedora ]]; then
            collect_all_linux
        else
            echo "{\"error\":\"Unsupported OS: $ID\"}"
            exit 1
        fi
    elif [[ $(uname -s) == "FreeBSD" ]]; then
        # Запускаем оригинальный скрипт для FreeBSD
        # Нужно импортировать оригинальные функции или вызвать внешний скрипт
        echo "{\"error\":\"FreeBSD version should be called separately\"}"
        exit 1
    else
        echo "{\"error\":\"Cannot detect OS\"}"
        exit 1
    fi
}

# Запуск
detect_os_and_run
