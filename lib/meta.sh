#!/usr/bin/env bash
# =================================================================
# DPX Meta Module - управление метаданными проектов
# Хранилище: ~/.config/dpx/projects.json
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_META_LOADED:-}" ]] && return 0
readonly _DPX_META_LOADED=1

# =================================================================
# ПУТЬ К ФАЙЛУ ХРАНИЛИЩА
# =================================================================

# Файл метаданных проектов
dpx_meta_file() {
    echo "${HOME}/.config/${TOOL_NAME}/projects.json"
}

# Инициализация хранилища (создаёт пустой файл если нет)
dpx_meta_init() {
    local meta_file
    meta_file=$(dpx_meta_file)

    if [[ ! -f "$meta_file" ]]; then
        mkdir -p "$(dirname "$meta_file")" 2>/dev/null
        echo '{"projects":{}}' > "$meta_file"
    fi
}

# =================================================================
# ЧТЕНИЕ МЕТАДАННЫХ
# =================================================================

# Получить значение по ключу для проекта
# dpx_meta_get <project_name> <key> [default]
dpx_meta_get() {
    local project_name="$1"
    local key="$2"
    local default="${3:-}"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    local value
    value=$(jq -r --arg name "$project_name" --arg k "$key" \
        '.projects[$name][$k] // empty' "$meta_file" 2>/dev/null)

    echo "${value:-$default}"
}

# Получить все метаданные проекта (JSON)
# dpx_meta_get_all <project_name>
dpx_meta_get_all() {
    local project_name="$1"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    jq -r --arg name "$project_name" \
        '.projects[$name] // empty' "$meta_file" 2>/dev/null
}

# Проверить наличие проекта в хранилище
dpx_meta_exists() {
    local project_name="$1"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    jq -e --arg name "$project_name" \
        '.projects[$name]' "$meta_file" >/dev/null 2>&1
}

# =================================================================
# ЗАПИСЬ МЕТАДАННЫХ
# =================================================================

# Установить значение для проекта
# dpx_meta_set <project_name> <key> <value>
dpx_meta_set() {
    local project_name="$1"
    local key="$2"
    local value="$3"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    local temp_file
    temp_file=$(create_temp_file)

    jq --arg name "$project_name" --arg k "$key" --arg v "$value" \
        '.projects[$name][$k] = $v' "$meta_file" > "$temp_file" 2>/dev/null

    mv "$temp_file" "$meta_file"
}

# Удалить ключ из проекта
# dpx_meta_unset <project_name> <key>
dpx_meta_unset() {
    local project_name="$1"
    local key="$2"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    local temp_file
    temp_file=$(create_temp_file)

    jq --arg name "$project_name" --arg k "$key" \
        'del(.projects[$name][$k])' "$meta_file" > "$temp_file" 2>/dev/null

    mv "$temp_file" "$meta_file"
}

# Удалить все метаданные проекта
# dpx_meta_delete <project_name>
dpx_meta_delete() {
    local project_name="$1"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    local temp_file
    temp_file=$(create_temp_file)

    jq --arg name "$project_name" \
        'del(.projects[$name])' "$meta_file" > "$temp_file" 2>/dev/null

    mv "$temp_file" "$meta_file"
}

# =================================================================
# СПЕЦИАЛИЗИРОВАННЫЕ ГЕТТЕРЫ
# =================================================================

# Получить php_max
dpx_get_php_max() {
    dpx_meta_get "$1" "php_max" "-"
}

# Получить тип проекта
dpx_get_project_type() {
    dpx_meta_get "$1" "type" "-"
}

# Получить заметки
dpx_get_notes() {
    dpx_meta_get "$1" "notes" "-"
}

# Получить дату тестирования
dpx_get_tested() {
    dpx_meta_get "$1" "tested" "-"
}