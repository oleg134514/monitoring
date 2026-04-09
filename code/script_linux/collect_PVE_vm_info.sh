#!/bin/bash

# Получаем текущую дату для логирования (не используется для файлов, только для сообщений)
CURRENT_DATE=$(date +%Y%m%d_%H%M%S)

# Функция для безопасного получения имени ВМ
get_vm_name() {
    local vm_id="$1"
    local name=""

    name=$(qm list 2>/dev/null | awk -v id="$vm_id" '$1 == id {print $2}')

    if [[ -z "$name" ]] && [[ -f "/etc/pve/qemu-server/${vm_id}.conf" ]]; then
        name=$(grep -oP '^name:\s*\K.+' "/etc/pve/qemu-server/${vm_id}.conf" | head -n1)
    fi

    name=$(echo "$name" | sed "s/^['\"]//;s/['\"]$//")

    echo "${name:-Unknown}"
}

# Функция для безопасного получения имени контейнера
get_ct_name() {
    local ct_id="$1"
    local name=""

    name=$(pct list 2>/dev/null | awk -v id="$ct_id" '$1 == id {print $3}')

    if [[ -z "$name" ]] && [[ -f "/etc/pve/lxc/${ct_id}.conf" ]]; then
        name=$(grep -oP '^hostname:\s*\K.+' "/etc/pve/lxc/${ct_id}.conf" | head -n1)
    fi

    name=$(echo "$name" | sed "s/^['\"]//;s/['\"]$//")

    echo "${name:-Unknown}"
}

# Функция для получения статуса
get_status() {
    local vm_id="$1"

    if qm status "$vm_id" 2>&1 | grep -q "status:"; then
        if qm status "$vm_id" 2>/dev/null | grep -q "status: running"; then
            echo "running"
        else
            echo "stopped"
        fi
    elif pct status "$vm_id" 2>&1 | grep -q "status:"; then
        if pct status "$vm_id" 2>/dev/null | grep -q "status: running"; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "unknown"
    fi
}

# Функция для получения выделенной памяти ВМ из конфигурационного файла
get_vm_allocated_memory() {
    local vm_id="$1"
    local memory=0

    if [[ -f "/etc/pve/qemu-server/${vm_id}.conf" ]]; then
        memory=$(grep -oP '^memory:\s*\K\d+' "/etc/pve/qemu-server/${vm_id}.conf" | head -n1)
    fi

    echo "${memory:-0}"
}

# Функция для получения выделенной памяти контейнера из конфигурационного файла
get_ct_allocated_memory() {
    local ct_id="$1"
    local memory=0

    if [[ -f "/etc/pve/lxc/${ct_id}.conf" ]]; then
        memory=$(grep -oP '^memory:\s*\K\d+' "/etc/pve/lxc/${ct_id}.conf" | head -n1)
    fi

    echo "${memory:-0}"
}

# Функция для получения используемой памяти ВМ (в МБ)
get_vm_used_memory() {
    local vm_id="$1"
    local memory_used=0

    if [[ -f "/var/run/qemu-server/${vm_id}.pid" ]]; then
        local pid=$(cat "/var/run/qemu-server/${vm_id}.pid" 2>/dev/null)
        if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
            memory_used=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}')
        fi
    fi

    if [[ -z "$memory_used" ]] || [[ "$memory_used" == "0" ]]; then
        memory_used=$(qm status "$vm_id" 2>/dev/null | grep -oP 'memory:\s*\K\d+')
    fi

    echo "${memory_used:-0}"
}

# Функция для получения используемой памяти контейнера (в МБ) - УПРОЩЕННАЯ ВЕРСИЯ
get_ct_used_memory() {
    local ct_id="$1"
    local memory_used=0

    # Метод 1: получаем использование памяти напрямую из контейнера через free -m
    if pct status "$ct_id" 2>/dev/null | grep -q "status: running"; then
        # Получаем used память (третья колонка в выводе free -m)
        memory_used=$(pct exec "$ct_id" -- timeout 2 free -m 2>/dev/null | grep "Mem:" | awk '{print $3}')
    fi

    # Метод 2: если не сработало, пробуем получить через процессы
    if [[ -z "$memory_used" ]] || [[ "$memory_used" == "0" ]]; then
        local ct_pid=$(pct status "$ct_id" 2>/dev/null | grep -oP 'pid:\s*\K\d+')
        if [[ -n "$ct_pid" ]]; then
            # Получаем все процессы контейнера (сам процесс и его дети)
            local all_pids="$ct_pid $(pgrep -P "$ct_pid" 2>/dev/null | tr '\n' ' ')"
            local total_rss=0

            for pid in $all_pids; do
                local pid_rss=$(ps -o rss= -p "$pid" 2>/dev/null)
                if [[ -n "$pid_rss" ]]; then
                    total_rss=$((total_rss + pid_rss))
                fi
            done

            if [[ "$total_rss" -gt 0 ]]; then
                memory_used=$((total_rss / 1024))
            fi
        fi
    fi

    echo "${memory_used:-0}"
}

# Функция для получения CPU использования для контейнеров LXC - УПРОЩЕННАЯ ВЕРСИЯ
get_ct_cpu_usage() {
    local ct_id="$1"
    local cpu_usage=0

    # Метод 1: получаем через процессы контейнера
    local ct_pid=$(pct status "$ct_id" 2>/dev/null | grep -oP 'pid:\s*\K\d+')
    if [[ -n "$ct_pid" ]]; then
        # Получаем все процессы контейнера
        local all_pids="$ct_pid $(pgrep -P "$ct_pid" 2>/dev/null | tr '\n' ' ')"
        local total_cpu=0

        for pid in $all_pids; do
            local pid_cpu=$(ps -p "$pid" -o %cpu --no-headers 2>/dev/null)
            if [[ -n "$pid_cpu" ]]; then
                total_cpu=$(echo "$total_cpu + $pid_cpu" | bc -l 2>/dev/null)
            fi
        done

        cpu_usage=$(printf "%.2f" "$total_cpu" 2>/dev/null || echo "0")
    fi

    # Метод 2: если не сработало, пробуем получить изнутри контейнера
    if [[ "$cpu_usage" == "0" ]] || [[ -z "$cpu_usage" ]]; then
        if pct status "$ct_id" 2>/dev/null | grep -q "status: running"; then
            # Получаем загрузку CPU за 1 секунду
            cpu_usage=$(pct exec "$ct_id" -- timeout 2 top -bn1 2>/dev/null | grep -i "cpu(s)" | awk -F, '{print $1}' | awk '{print $2}' | cut -d'%' -f1)
            cpu_usage=$(printf "%.2f" "$cpu_usage" 2>/dev/null || echo "0")
        fi
    fi

    echo "$cpu_usage"
}

# Функция для получения CPU использования для ВМ
get_vm_cpu_usage() {
    local vm_id="$1"
    local cpu_usage=0

    if [[ -f "/var/run/qemu-server/${vm_id}.pid" ]]; then
        local pid=$(cat "/var/run/qemu-server/${vm_id}.pid" 2>/dev/null)
        if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
            cpu_usage=$(ps -p "$pid" -o %cpu 2>/dev/null | tail -n1 | awk '{print $1}')
            cpu_usage=$(printf "%.2f" "$cpu_usage" 2>/dev/null || echo "0")
        fi
    fi

    echo "$cpu_usage"
}

# Функция для получения информации о ВМ (KVM)
get_vm_info() {
    local vm_id="$1"

    local name=$(get_vm_name "$vm_id")
    local status=$(get_status "$vm_id")
    local cpu_usage=0
    local memory_allocated=$(get_vm_allocated_memory "$vm_id")
    local memory_used=0

    if [[ "$status" == "running" ]]; then
        cpu_usage=$(get_vm_cpu_usage "$vm_id")
        memory_used=$(get_vm_used_memory "$vm_id")
    fi

    name=$(echo "$name" | sed 's/"/\\"/g')

    echo "{\"id\": $vm_id, \"type\": \"vm\", \"name\": \"$name\", \"status\": \"$status\", \"cpu_usage\": $cpu_usage, \"memory_used\": $memory_used, \"memory_allocated\": $memory_allocated}"
}

# Функция для получения информации о контейнере (LXC)
get_ct_info() {
    local ct_id="$1"

    local name=$(get_ct_name "$ct_id")
    local status=$(get_status "$ct_id")
    local cpu_usage=0
    local memory_allocated=$(get_ct_allocated_memory "$ct_id")
    local memory_used=0

    if [[ "$status" == "running" ]]; then
        cpu_usage=$(get_ct_cpu_usage "$ct_id")
        memory_used=$(get_ct_used_memory "$ct_id")
    fi

    name=$(echo "$name" | sed 's/"/\\"/g')

    echo "{\"id\": $ct_id, \"type\": \"lxc\", \"name\": \"$name\", \"status\": \"$status\", \"cpu_usage\": $cpu_usage, \"memory_used\": $memory_used, \"memory_allocated\": $memory_allocated}"
}

# Основная часть скрипта — сбор в переменную JSON без файла
JSON="["

first_entry=true

echo "Сбор информации о виртуальных машинах..." >&2
vm_list=$(qm list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
if [[ -n "$vm_list" ]]; then
    for vm in $vm_list; do
        echo "Обработка ВМ $vm..." >&2

        if [[ "$first_entry" == true ]]; then
            first_entry=false
        else
            JSON+=","
        fi

        vm_info=$(get_vm_info "$vm" 2>/dev/null)
        JSON+="$vm_info"
    done
fi

echo "Сбор информации о контейнерах..." >&2
ct_list=$(pct list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
if [[ -n "$ct_list" ]]; then
    for ct in $ct_list; do
        echo "Обработка контейнера $ct..." >&2

        if [[ "$first_entry" == true ]]; then
            first_entry=false
        else
            JSON+=","
        fi

        ct_info=$(get_ct_info "$ct" 2>/dev/null)
        JSON+="$ct_info"
    done
fi

JSON+="]"

# Отправка по сети
echo "$JSON" | nc -w 3 000.000.000.111 1234 2>/dev/null #  000.000.000.111:1234 - заменить на адрес и порт сервера получателя

# Логирование для отладки
count=$(echo "$JSON" | grep -o '"id"' | wc -l)
echo "JSON-массив с $count объектами (VM и LXC) отправлен на 000.000.000.111:1234" >&2 #  000.000.000.111:1234 - заменить на адрес и порт сервера получателя
