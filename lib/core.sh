#!/usr/bin/env bash
# =================================================================
# DPX Core - загрузчик модулей (Loader)
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_CORE_LOADED:-}" ]] && return 0
readonly _DPX_CORE_LOADED=1

# =================================================================
# КОНСТАНТЫ (только уникальные для core.sh)
# =================================================================

readonly TOOL_NAME="${TOOL_NAME:-dpx}"

# Единый источник версии (Single Source of Truth) — читаем из .version
if [[ -f "${DPX_ROOT}/.version" ]]; then
    readonly DPX_VERSION="$(head -1 "${DPX_ROOT}/.version" | tr -d '[:space:]')"
else
    readonly DPX_VERSION="0.0.0-unknown"
fi

# =================================================================
# ЗАГРУЗКА БАЗОВЫХ МОДУЛЕЙ (порядок важен!)
# =================================================================

# paths.sh - определяет DPX_ROOT, DPX_OS_TYPE, DPX_SED_INPLACE_EXT
source "${DPX_ROOT}/lib/paths.sh"

# io.sh - функции вывода (print_*, COLOR_*)
source "${DPX_ROOT}/lib/io.sh"

# utils.sh - общие утилиты
source "${DPX_ROOT}/lib/utils.sh"

# config.sh - загрузка конфигурации
source "${DPX_ROOT}/lib/config.sh"

# args.sh - парсинг аргументов
source "${DPX_ROOT}/lib/args.sh"

# checks.sh - проверки зависимостей, версий, константы MIN_*
source "${DPX_ROOT}/lib/checks.sh"

# sudo.sh - безопасная работа с привилегиями и файлами (Safe Sudo Protocol)
source "${DPX_ROOT}/lib/sudo.sh"

# meta.sh - управление метаданными проектов
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# КРОССПЛАТФОРМЕННОЕ ОПРЕДЕЛЕНИЕ ДОМАШНЕЙ ДИРЕКТОРИИ
# =================================================================

dpx_get_real_home() {
    local home

    if [[ -n "${SUDO_USER:-}" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        else
            home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        fi
    fi

    if [[ -z "${home:-}" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            home=$(dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        else
            home=$(getent passwd "$USER" 2>/dev/null | cut -d: -f6)
        fi
    fi

    echo "${home:-$HOME}"
}

# Определяем REAL_HOME ДО загрузки конфигурации
REAL_HOME=$(dpx_get_real_home)
readonly REAL_HOME

# =================================================================
# ИНИЦИАЛИЗАЦИЯ КОНФИГУРАЦИИ И ПУТЕЙ
# =================================================================

# Загружаем конфигурацию
load_config

# =================================================================
# РАСКРЫТИЕ ПУТЕЙ В КОНФИГУРАЦИИ
# =================================================================

# 1. Вычисляем и раскрываем главный WORKSPACE_ROOT
DPX_WORKSPACE="${DEFAULT_CONFIG[workspace_root]}"
DPX_WORKSPACE="${DPX_WORKSPACE//\$HOME/$REAL_HOME}"
DPX_WORKSPACE="${DPX_WORKSPACE/#\~/$REAL_HOME}"

# 2. Функция раскрытия путей с поддержкой $WORKSPACE_ROOT
expand_path() {
    local path="$1"
    path="${path//\$WORKSPACE_ROOT/$DPX_WORKSPACE}"
    path="${path//\$HOME/$REAL_HOME}"
    path="${path/#\~/$REAL_HOME}"
    echo "$path"
}

# 3. Раскрываем пути во ВСЕХ значениях DEFAULT_CONFIG
_dpx_expand_key=
for _dpx_expand_key in "${!DEFAULT_CONFIG[@]}"; do
    DEFAULT_CONFIG["$_dpx_expand_key"]=$(expand_path "${DEFAULT_CONFIG[$_dpx_expand_key]}")
done

# Получаем корневую директорию проектов
PROJECTS_ROOT=$(get_config "ddev_projects_base_path")
export PROJECTS_ROOT

# =================================================================
# ФУНКЦИИ ЯДРА
# =================================================================

core_rotate_backups() {
    local project_name="$1"
    local backup_dir="$2"
    local type_prefix="$3"
    local keep_count="${4:-3}"

    [[ ! -d "$backup_dir" ]] && return 0

    local skip_count=$((keep_count + 1))
    local files_to_delete

    files_to_delete=$(cd "$backup_dir" && command ls -1t "${project_name}_${type_prefix}_"*.sql 2>/dev/null | tail -n +"$skip_count")

    [[ -z "$files_to_delete" ]] && return 0

    local count=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if rm -f "${backup_dir}/${file}" 2>/dev/null; then
            ((count++))
        fi
    done <<< "$files_to_delete"

    if (( count > 0 )); then
        print_info "Ротация: удалено $count старых файлов (оставлено $keep_count)."
    fi
}

# =================================================================
# ЭКСПОРТ
# =================================================================

export TOOL_NAME DPX_VERSION REAL_HOME DPX_WORKSPACE