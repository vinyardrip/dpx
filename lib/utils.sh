#!/usr/bin/env bash
# =================================================================
# DPX Utils Module - общие утилиты
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_UTILS_LOADED:-}" ]] && return 0
readonly _DPX_UTILS_LOADED=1

# =================================================================
# ВРЕМЯ И ДАТА
# =================================================================

get_current_date() {
    date +%Y-%m-%d
}

get_timestamp() {
    date +%s
}

# =================================================================
# ВРЕМЕННЫЕ ФАЙЛЫ
# =================================================================

create_temp_file() {
    mktemp "${TMPDIR:-/tmp}/dpx_XXXXXX"
}

create_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/dpx_XXXXXX"
}

# =================================================================
# ФАЙЛОВАЯ СИСТЕМА
# =================================================================

ensure_directory() {
    local path="$1"
    [[ ! -d "$path" ]] && mkdir -p "$path"
}

ensure_parent_directory() {
    local file="$1"
    ensure_directory "$(dirname "$file")"
}

# =================================================================
# ВАЛИДАЦИЯ
# =================================================================

validate_directory() {
    local path="$1"
    local description="${2:-директория}"

    if [[ -z "$path" ]]; then
        print_error "Путь к $description не указан."
        return 1
    fi

    if [[ ! -d "$path" ]]; then
        print_error "$description не найдена: $path"
        return 1
    fi

    return 0
}

validate_file() {
    local path="$1"
    local description="${2:-файл}"

    if [[ -z "$path" ]]; then
        print_error "Путь к $description не указан."
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        print_error "$description не найден: $path"
        return 1
    fi

    return 0
}

validate_non_empty() {
    local value="$1"
    local description="${2:-значение}"

    if [[ -z "$value" ]]; then
        print_error "$description не может быть пустым."
        return 1
    fi

    return 0
}

validate_project_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Имя проекта не может быть пустым."
        return 1
    fi

    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
        print_error "Имя проекта может содержать только строчные буквы, цифры и дефисы."
        return 1
    fi

    return 0
}

# =================================================================
# ИНТЕРАКТИВНОСТЬ
# =================================================================

confirm() {
    local prompt="${1:-Продолжить?}"
    local default="${2:-n}"
    local full_prompt

    case "$default" in
        y|Y) full_prompt="$prompt (Y/n): " ;;
        *)   full_prompt="$prompt (y/n): " ;;
    esac

    read -r -p "$full_prompt" response
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"
    local full_prompt

    if [[ -n "$default" ]]; then
        full_prompt="$prompt [$default]: "
    else
        full_prompt="$prompt: "
    fi

    read -r -p "$full_prompt" value
    value="${value:-$default}"

    if [[ -n "$var_name" ]]; then
        # printf -v безопасно записывает значение в переменную без парсинга
        # (защита от Bash Injection через eval)
        printf -v "$var_name" "%s" "$value"
    else
        echo "$value"
    fi
}

# Простой выбор из списка (без нумерации)
prompt_choice() {
    local prompt="$1"
    shift
    local choices=("$@")
    local default="${choices[0]}"
    local choices_str=$(IFS=/; echo "${choices[*]}")

    read -r -p "$prompt ($choices_str) [$default]: " response

    if [[ -n "$response" ]]; then
        # Проверяем, есть ли введённое значение в списке
        for choice in "${choices[@]}"; do
            [[ "$response" == "$choice" ]] && echo "$choice" && return
        done
        # Если не найдено, возвращаем default
        echo "$default"
    else
        echo "$default"
    fi
}

# =================================================================
# DEEP LOGGING (v1.4.14)
#
# dpx_exec_and_log — обёртка для выполнения команд с логированием.
#
# Выполняет команду в контексте директории проекта (cd "$project_path"),
# показывает вывод пользователю (stdout/stderr) и гарантированно пишет
# полную строку запуска + результат в файл .dpx/debug.log внутри проекта.
#
# v1.4.22: КОМАНДА ВЫПОЛНЯЕТСЯ В PROJECT CONTEXT.
# Все ddev-команды (snapshot, mysql, exec) требуют запуска из
# директории проекта. Обёртка автоматически делает cd перед
# выполнением, поэтому callers НЕ должны сами cd.
#
# ПРИМЕНЕНИЕ:
#   dpx_exec_and_log "$project_path" ddev exec wp cache flush --allow-root
#   dpx_exec_and_log "$project_path" ddev snapshot --name="$snap" --cleanup
#
# АРГУМЕНТЫ:
#   $1       — project_path (для cd + определения пути к .dpx/debug.log)
#   $2, ...  — команда и её аргументы
#
# RETURN: exit code первого процесса в пайплайне (PIPESTATUS[0])
# =================================================================
dpx_exec_and_log() {
    local project_path="$1"
    shift

    local log_dir="${project_path}/.dpx"
    local log_file="${log_dir}/debug.log"
    mkdir -p "$log_dir" 2>/dev/null

    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Пишем саму команду в лог
    echo -e "\n[$timestamp] EXEC (cd ${project_path}): $*" >> "$log_file"

    # Выполняем команду в контексте проекта (subshell для изоляции cd)
    # Сохраняем код возврата первого процесса в пайплайне
    (cd "$project_path" && "$@") 2>&1 | tee -a "$log_file"
    return ${PIPESTATUS[0]}
}

# =================================================================
# БЕЗОПАСНЫЙ SED
# =================================================================

safe_sed_inplace() {
    local pattern="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        print_error "Файл не найден: $file"
        return 1
    fi

    if [[ "$DPX_OS_TYPE" == "macos" ]]; then
        sed -i "${DPX_SED_INPLACE_EXT}" "$pattern" "$file"
        # Автоочистка .bak на macOS (sed -i .bak создаёт резервную копию)
        rm -f "${file}${DPX_SED_INPLACE_EXT}" 2>/dev/null || true
    else
        sed -i "$pattern" "$file"
    fi
}

safe_sed_stream() {
    local pattern="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        print_error "Файл не найден: $file"
        return 1
    fi

    sed "$pattern" "$file"
}

# =================================================================
# ЭКСПОРТ
# =================================================================
# Примечание: export -f не требуется при использовании source
export -f dpx_exec_and_log