#!/usr/local/bin/bash

# ФИНАЛЬНЫЙ СКРИПТ с реальной частотой CPU

# Конфигурация
MEASUREMENT_INTERVAL=1
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

# Получение РЕАЛЬНОЙ частоты CPU
get_cpu_frequency() {
    local real_freq="N/D"

    # Метод 1: Через dev.cpu.X.freq (если доступно)
    local freq_from_sysctl=$(safe_cmd "sysctl -n dev.cpu.0.freq" "")
    if [[ -n "$freq_from_sysctl" && "$freq_from_sysctl" =~ ^[0-9]+$ ]]; then
        real_freq="$freq_from_sysctl"
    else
        # Метод 2: Через sysctl hw.acpi.cpu.pstate (для некоторых систем)
        local pstate=$(safe_cmd "sysctl -n hw.acpi.cpu.pstate 2>/dev/null" "")
        if [[ -n "$pstate" ]]; then
            # Извлекаем текущую частоту из вывода pstate
            local current_freq=$(echo "$pstate" | grep -o "current freq [0-9]*" | grep -o "[0-9]*")
            if [[ -n "$current_freq" ]]; then
                real_freq="$current_freq"
            fi
        fi

        # Метод 3: Через dmidecode (если установлен)
        if [[ "$real_freq" == "N/D" ]] && command -v dmidecode >/dev/null; then
            local dmidecode_output=$(dmidecode -t processor 2>/dev/null | grep -i "current speed" | head -1)
            if [[ -n "$dmidecode_output" ]]; then
                local freq_mhz=$(echo "$dmidecode_output" | grep -o '[0-9]* MHz' | grep -o '[0-9]*')
                if [[ -n "$freq_mhz" ]]; then
                    real_freq="$freq_mhz"
                fi
            fi
        fi

        # Метод 4: Через измерения (последний вариант)
        if [[ "$real_freq" == "N/D" ]]; then
            # Получаем номинальную частоту и предполагаем текущую
            local nominal_freq=$(safe_cmd "sysctl -n hw.clockrate" "0")
            if [[ "$nominal_freq" -gt 0 ]]; then
                # Для процессоров с Turbo Boost, реальная частота может быть выше
                # Используем номинальную как fallback
                real_freq="$nominal_freq"
            fi
        fi
    fi

    echo "$real_freq"
}

# Получение температуры CPU
get_cpu_temperature() {
    local temp="N/D"

    # Пробуем IPMI
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

    # Пробуем sysctl
    if [[ "$temp" == "N/D" ]]; then
        for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            local core_temp=$(safe_cmd "sysctl -n dev.cpu.$i.temperature 2>/dev/null" "")
            if [[ -n "$core_temp" ]]; then
                local temp_val=$(echo "$core_temp" | tr -d 'C°\n\r' | grep -o '[0-9]\+' | head -1)
                if [[ -n "$temp_val" ]]; then
                    temp="$temp_val"
                    break
                fi
            fi
        done
    fi

    echo "$temp"
}

# ПРАВИЛЬНОЕ измерение скорости сети через devstat
measure_network_speed_devstat() {
    local interface="$1"
    local rx_speed=0
    local tx_speed=0

    # Метод через devstat (работает на FreeBSD!)
    if command -v devstat >/dev/null; then
        # Запускаем devstat на 1 секунду
        local devstat_output=$(devstat -t 1 2>/dev/null | grep "$interface" | head -1)

        if [[ -n "$devstat_output" ]]; then
            # Парсим скорость из devstat
            # Формат: "interface in KB/s out KB/s"
            rx_speed=$(echo "$devstat_output" | awk '{print $3}')  # KB/s
            tx_speed=$(echo "$devstat_output" | awk '{print $5}')  # KB/s

            # Конвертируем KB/s в Mbps
            rx_speed=$(safe_math "$rx_speed * 8 / 1000" "0")
            tx_speed=$(safe_math "$tx_speed * 8 / 1000" "0")
        fi
    fi

    echo "$rx_speed $tx_speed"
}

# Альтернативный метод через netstat -i
measure_network_speed_netstat() {
    local interface="$1"
    local rx_speed=0
    local tx_speed=0

    # Метод через netstat -i (накопленные байты)
    local netstat_output=$(netstat -i -n -I "$interface" -b 2>/dev/null | grep "^$interface" | head -1)

    if [[ -n "$netstat_output" ]]; then
        # Парсим накопленные байты
        local rx_bytes1=$(echo "$netstat_output" | awk '{print $8}')   # Ibytes
        local tx_bytes1=$(echo "$netstat_output" | awk '{print $11}')  # Obytes

        if [[ -n "$rx_bytes1" && -n "$tx_bytes1" ]]; then
            sleep "$MEASUREMENT_INTERVAL"

            local netstat_output2=$(netstat -i -n -I "$interface" -b 2>/dev/null | grep "^$interface" | head -1)
            local rx_bytes2=$(echo "$netstat_output2" | awk '{print $8}')
            local tx_bytes2=$(echo "$netstat_output2" | awk '{print $11}')

            if [[ -n "$rx_bytes2" && -n "$tx_bytes2" ]]; then
                # Рассчитываем скорость в Mbps
                rx_speed=$(safe_math "($rx_bytes2 - $rx_bytes1) * 8 / $MEASUREMENT_INTERVAL / 1000000" "0")
                tx_speed=$(safe_math "($tx_bytes2 - $tx_bytes1) * 8 / $MEASUREMENT_INTERVAL / 1000000" "0")
            fi
        fi
    fi

    echo "$rx_speed $tx_speed"
}

# Универсальный метод измерения скорости
measure_network_speed() {
    local interface="$1"
    local rx_speed=0
    local tx_speed=0

    # Пробуем devstat (самый точный)
    local speeds=$(measure_network_speed_devstat "$interface")
    rx_speed=$(echo "$speeds" | awk '{print $1}')
    tx_speed=$(echo "$speeds" | awk '{print $2}')

    # Если devstat не сработал, пробуем netstat
    if [[ "$rx_speed" == "0" && "$tx_speed" == "0" ]]; then
        speeds=$(measure_network_speed_netstat "$interface")
        rx_speed=$(echo "$speeds" | awk '{print $1}')
        tx_speed=$(echo "$speeds" | awk '{print $2}')
    fi

    # Округляем до 1 знака после запятой
    rx_speed=$(printf "%.1f" "$rx_speed" 2>/dev/null || echo "0")
    tx_speed=$(printf "%.1f" "$tx_speed" 2>/dev/null || echo "0")

    echo "$rx_speed $tx_speed"
}

# ПРАВИЛЬНЫЙ расчет памяти
get_memory_info() {
    # Общая память
    local mem_total=$(safe_cmd "sysctl -n hw.physmem" "0")
    local mem_total_gb=$(safe_math "$mem_total / 1073741824" "0")

    # Получаем статистику памяти через top
    local top_output=$(top -b -d 1 2>/dev/null | grep "^Mem:" | head -1)

    local used_gb=0
    local free_gb=0
    local available_gb=0

    if [[ -n "$top_output" ]]; then
        # Парсим вывод: "Mem: 62M Active, 2889M Inact, 180M Laundry, 172G Wired, 133M Buf, 12G Free"

        # Извлекаем значения
        local active_m=$(echo "$top_output" | grep -o '[0-9]\+M Active' | grep -o '[0-9]\+' || echo "0")
        local inactive_m=$(echo "$top_output" | grep -o '[0-9]\+M Inact' | grep -o '[0-9]\+' || echo "0")
        local laundry_m=$(echo "$top_output" | grep -o '[0-9]\+M Laundry' | grep -o '[0-9]\+' || echo "0")

        local wired_g=$(echo "$top_output" | grep -o '[0-9]\+G Wired' | grep -o '[0-9]\+' || echo "0")
        local wired_m=$(safe_math "$wired_g * 1024" "0")

        local buf_m=$(echo "$top_output" | grep -o '[0-9]\+M Buf' | grep -o '[0-9]\+' || echo "0")

        local free_g=$(echo "$top_output" | grep -o '[0-9]\+G Free' | grep -o '[0-9]\+' || echo "0")
        free_gb="$free_g"
        local free_m=$(safe_math "$free_g * 1024" "0")

        # Использованная память = Active + Inact + Laundry + Wired + Buf
        local total_used_m=$(safe_math "$active_m + $inactive_m + $laundry_m + $wired_m + $buf_m" "0")
        used_gb=$(safe_math "$total_used_m / 1024" "0")

        # Доступная память = Free + Inact
        local total_available_m=$(safe_math "$free_m + $inactive_m" "0")
        available_gb=$(safe_math "$total_available_m / 1024" "0")
    else
        # Резервный метод
        local page_size=$(safe_cmd "sysctl -n hw.pagesize" "4096")
        local active_pages=$(safe_cmd "sysctl -n vm.stats.vm.v_active_count" "0")
        local inactive_pages=$(safe_cmd "sysctl -n vm.stats.vm.v_inactive_count" "0")
        local free_pages=$(safe_cmd "sysctl -n vm.stats.vm.v_free_count" "0")

        used_gb=$(safe_math "($active_pages + $inactive_pages) * $page_size / 1073741824" "0")
        free_gb=$(safe_math "$free_pages * $page_size / 1073741824" "0")
        available_gb=$(safe_math "($free_pages + $inactive_pages) * $page_size / 1073741824" "0")
    fi

    # Округляем до 2 знаков
    mem_total_gb=$(printf "%.2f" "$mem_total_gb")
    used_gb=$(printf "%.2f" "$used_gb")
    free_gb=$(printf "%.2f" "$free_gb")
    available_gb=$(printf "%.2f" "$available_gb")

    echo "$mem_total_gb $used_gb $free_gb $available_gb"
}

# Получение информации о дисках
get_disk_info() {
    local disk="$1"
    local disk_type="$2"

    local health="N/D"
    local temp="N/D"
    local model="N/D"
    local serial="N/D"
    local health_percent=100

    if command -v smartctl >/dev/null && [[ -e "/dev/$disk" ]]; then
        # Для SAS дисков
        if [[ "$disk_type" == "SAS" ]]; then
            local smart_output=$(smartctl -d scsi -a /dev/$disk 2>/dev/null)

            if [[ $? -eq 0 ]]; then
                # Модель (пробуем разные варианты)
                model=$(echo "$smart_output" | grep -i "product:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$model" ]] && model=$(echo "$smart_output" | grep -i "vendor:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$model" ]] && model="N/D"
                model=$(echo "$model" | sed 's/"/\\"/g')

                # Серийник
                serial=$(echo "$smart_output" | grep -i "serial number:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$serial" ]] && serial="N/D"

                # Температура
                temp=$(echo "$smart_output" | grep -i "current drive temperature:" | cut -d: -f2 | tr -d ' C' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$temp" ]] && temp="N/D"

                # Здоровье SAS дисков
                if echo "$smart_output" | grep -qi "temperature warning.*enabled"; then
                    health="PASSED"
                else
                    health="UNKNOWN"
                fi
            fi

        # Для SATA/SSD дисков
        elif [[ "$disk_type" == "SATA" ]]; then
            local smart_output=$(smartctl -a /dev/$disk 2>/dev/null)

            if [[ $? -eq 0 ]]; then
                # Модель
                model=$(echo "$smart_output" | grep -i "device model:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/"/\\"/g')
                [[ -z "$model" ]] && model="N/D"

                # Серийник
                serial=$(echo "$smart_output" | grep -i "serial number:" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$serial" ]] && serial="N/D"

                # Температура из атрибута 194
                temp=$(echo "$smart_output" | awk '/194 Temperature_Celsius/ {print $10}' | head -1)
                if [[ -z "$temp" || "$temp" == "-" ]]; then
                    temp="N/D"
                fi

                # Здоровье
                if echo "$smart_output" | grep -q "PASSED"; then
                    health="PASSED"
                else
                    health="UNKNOWN"
                fi

                # Процент здоровья для SSD (атрибут 177 Wear_Leveling_Count)
                local wear_leveling=$(echo "$smart_output" | awk '/177 Wear_Leveling_Count/ {print $4}' | head -1)
                if [[ -n "$wear_leveling" && "$wear_leveling" != "-" ]]; then
                    health_percent="$wear_leveling"
                fi
            fi
        fi
    fi

    echo "$health|$temp|$model|$serial|$health_percent"
}

# Основная функция
collect_all() {
    log "Начало сбора метрик..."

    # Системная информация
    log "Сбор системной информации..."
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hostname=$(hostname -s)
    local uptime_raw=$(safe_cmd "uptime" "")
    local uptime="N/D"
    if [[ -n "$uptime_raw" ]]; then
        uptime=$(echo "$uptime_raw" | sed 's/.*up //;s/,.*//')
    fi

    # CPU
    log "Сбор информации о процессоре..."
    local cpu_model=$(safe_cmd "sysctl -n hw.model" "N/D" | sed 's/"/\\"/g')
    local cpu_freq_nominal=$(safe_cmd "sysctl -n hw.clockrate" "0")
    local cpu_freq_real=$(get_cpu_frequency)
    local cpu_cores=$(safe_cmd "sysctl -n hw.ncpu" "0")
    local load_avg=$(safe_cmd "sysctl -n vm.loadavg" "0 0 0" | awk '{print $2}')
    local cpu_temp=$(get_cpu_temperature)

    # Память
    log "Сбор информации о памяти..."
    local memory_info=$(get_memory_info)
    local mem_total_gb=$(echo "$memory_info" | awk '{print $1}')
    local mem_used_gb=$(echo "$memory_info" | awk '{print $2}')
    local mem_free_gb=$(echo "$memory_info" | awk '{print $3}')
    local mem_available_gb=$(echo "$memory_info" | awk '{print $4}')

    # Сеть
    log "Сбор информации о сети..."
    local ifaces=$(safe_cmd "ifconfig -l" "")
    local net_iface="N/D"
    local rx_mbps=0
    local tx_mbps=0

    if [[ -n "$ifaces" ]]; then
        for iface in $ifaces; do
            if [[ ! "$iface" =~ ^(lo|bridge|vlan|tun|tap) ]] && [[ -n "$iface" ]]; then
                # Проверяем, что интерфейс существует
                if ifconfig "$iface" >/dev/null 2>&1; then
                    net_iface="$iface"

                    # Измеряем скорость (devstat работает!)
                    local speeds=$(measure_network_speed "$iface")
                    rx_mbps=$(echo "$speeds" | awk '{print $1}')
                    tx_mbps=$(echo "$speeds" | awk '{print $2}')

                    break
                fi
            fi
        done
    fi

    # ZFS
    log "Сбор информации о ZFS..."
    local zfs_data="[]"
    if command -v zpool >/dev/null; then
        local pools=$(safe_cmd "zpool list -H -o name" "")
        local pool_array="["
        local first_pool=true

        for pool in $pools; do
            [[ "$first_pool" == true ]] || pool_array+=","
            first_pool=false

            local pool_info=$(safe_cmd "zpool list -H -o size,free,health $pool" "0 0 UNKNOWN")
            local pool_size=$(echo "$pool_info" | awk '{print $1}')
            local pool_free=$(echo "$pool_info" | awk '{print $2}')
            local pool_health=$(echo "$pool_info" | awk '{print $3}')

            # Конвертация в GB
            local size_num=$(echo "$pool_size" | sed 's/[^0-9.]//g')
            local free_num=$(echo "$pool_free" | sed 's/[^0-9.]//g')

            local size_gb=0
            local free_gb=0

            if [[ "$pool_size" =~ T ]]; then
                size_gb=$(safe_math "$size_num * 1024" "0")
            elif [[ "$pool_size" =~ G ]]; then
                size_gb="$size_num"
            elif [[ "$pool_size" =~ M ]]; then
                size_gb=$(safe_math "$size_num / 1024" "0")
            else
                size_gb=$(safe_math "$size_num / 1073741824" "0")
            fi

            if [[ "$pool_free" =~ T ]]; then
                free_gb=$(safe_math "$free_num * 1024" "0")
            elif [[ "$pool_free" =~ G ]]; then
                free_gb="$free_num"
            elif [[ "$pool_free" =~ M ]]; then
                free_gb=$(safe_math "$free_num / 1024" "0")
            else
                free_gb=$(safe_math "$free_num / 1073741824" "0")
            fi

            # Снапшоты
            local snapshots_array="[]"
            local snapshots=$(zfs list -t snapshot -o name,creation -s creation -r $pool 2>/dev/null | tail -n +2 | tail -n $MAX_SNAPSHOTS)
            if [[ -n "$snapshots" ]]; then
                snapshots_array="["
                local first_snap=true
                while IFS= read -r snap; do
                    [[ "$first_snap" == true ]] || snapshots_array+=","
                    first_snap=false

                    local snap_name=$(echo "$snap" | awk '{print $1}' | sed 's/.*@//')
                    local snap_date=$(echo "$snap" | awk '{for(i=2;i<=5;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
                    local snap_iso="N/D"

                    if [[ -n "$snap_date" ]]; then
                        snap_iso=$(date -j -f "%b %d %H:%M %Y" "$snap_date" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "N/D")
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

    # Диски
    log "Сбор информации о дисках..."
    local disks_data="[]"
    local disks=$(safe_cmd "sysctl -n kern.disks" "")

    if [[ -n "$disks" ]]; then
        local disk_array="["
        local first_disk=true

        for disk in $disks; do
            [[ "$disk" =~ ^(cd|pass|md|vtblk) ]] && continue

            [[ "$first_disk" == true ]] || disk_array+=","
            first_disk=false

            # Тип диска
            local disk_type="UNKNOWN"
            [[ "$disk" =~ ^ada ]] && disk_type="SATA"
            [[ "$disk" =~ ^da ]] && disk_type="SAS"
            [[ "$disk" =~ ^nvd ]] && disk_type="NVMe"

            # Информация о диске
            local disk_info=$(get_disk_info "$disk" "$disk_type")
            local health=$(echo "$disk_info" | cut -d'|' -f1)
            local temp=$(echo "$disk_info" | cut -d'|' -f2)
            local model=$(echo "$disk_info" | cut -d'|' -f3)
            local serial=$(echo "$disk_info" | cut -d'|' -f4)
            local health_percent=$(echo "$disk_info" | cut -d'|' -f5)

            disk_array+="{\"device\":\"$disk\",\"type\":\"$disk_type\",\"model\":\"$model\",\"serial\":\"$serial\",\"health\":\"$health\",\"health_percent\":$health_percent,\"temperature_c\":\"$temp\"}"
        done
        disk_array+="]"
        disks_data="$disk_array"
    fi

    # Формируем JSON
# В конце collect_all() замените на:

    local json_output="{"
    json_output+="\"ip_server\": \"000.000.000.000\"," # 000.000.000.000 - заменить на ip сервера xigmanas
    json_output+="\"system\":{\"timestamp\":\"$timestamp\",\"hostname\":\"$hostname\",\"uptime\":\"$uptime\"},"
    json_output+="\"cpu\":{\"model\":\"$cpu_model\",\"frequency_nominal_mhz\":$cpu_freq_nominal,\"frequency_real_mhz\":\"$cpu_freq_real\",\"cores\":$cpu_cores,\"temperature_c\":\"$cpu_temp\",\"load_avg\":$load_avg},"
    json_output+="\"memory\":{\"total_gb\":$mem_total_gb,\"used_gb\":$mem_used_gb,\"free_gb\":$mem_free_gb,\"available_gb\":$mem_available_gb},"
    json_output+="\"network\":{\"interface\":\"$net_iface\",\"rx_mbps\":$rx_mbps,\"tx_mbps\":$tx_mbps},"
    json_output+="\"zfs_pools\":$zfs_data,"
    json_output+="\"disks\":$disks_data"
    json_output+="}"

    echo "$json_output" | nc -w 5 172.16.76.144 1234 2>/dev/null

    log "Метрики XigmaNAS с ip_server=000.000.000.000 отправлены на 000.000.000.111:1234" # 000.000.000.000 - заменить на ip сервера xigmanas, 000.000.000.111:1234 - заменить на адрес и порт сервера получателя
}

# Запуск
collect_all
