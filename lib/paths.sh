#!/usr/bin/env bash
# =================================================================
# DPX Paths Module - определение путей, кроссплатформенное разрешение
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_PATHS_LOADED:-}" ]] && return 0
readonly _DPX_PATHS_LOADED=1

# =================================================================
# ОПРЕДЕЛЕНИЕ ОС (BSD/GNU совместимость)
# =================================================================

DPX_OS_TYPE="linux"
DPX_SED_INPLACE_EXT=""

dpx_detect_os() {
    case "${OSTYPE:-}" in
        darwin*)
            DPX_OS_TYPE="macos"
            DPX_SED_INPLACE_EXT=".bak"
            ;;
        linux*)
            DPX_OS_TYPE="linux"
            ;;
        *)
            DPX_OS_TYPE="other"
            ;;
    esac
}
dpx_detect_os

# =================================================================
# КРОССПЛАТФОРМЕННОЕ РАЗРЕШЕНИЕ ПУТЕЙ
# =================================================================

# Надёжное разрешение симлинков (GNU/BSD совместимое)
dpx_resolve_symlink() {
    local source="$1"
    local dir
    local max_iterations=50
    local iteration=0

    while [[ -L "$source" ]] && [[ $iteration -lt $max_iterations ]]; do
        dir="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || return 1
        source="$(readlink "$source" 2>/dev/null)" || return 1
        [[ "$source" != /* ]] && source="${dir}/${source}"
        ((iteration++))
    done

    # Защита от циклических симлинков
    [[ $iteration -ge $max_iterations ]] && return 1

    # Возвращаем АБСОЛЮТНУЮ директорию, если путь существует
    if [[ -e "$source" ]]; then
        # Переходим в папку и печатаем ее полный путь (не относительный!)
        cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
        return 0
    fi

    return 1
}

# Определение корневой директории проекта
dpx_get_root() {
    local source="${BASH_SOURCE[0]:-$0}"
    local dir

    # Пытаемся разрешить симлинки
    if dir="$(dpx_resolve_symlink "$source")" && [[ -n "$dir" ]]; then
        : # успешно
    else
        # Fallback: простое определение без разрешения симлинков
        dir="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || {
            echo "FATAL: Cannot determine script root" >&2
            return 1
        }
    fi

    # Поднимаемся из lib/commands/tests на уровень выше
    case "$(basename "$dir")" in
        lib|commands|tests)
            dir="$(dirname "$dir")"
            ;;
    esac

    # Валидация
    if [[ -z "$dir" ]] || [[ ! -d "$dir" ]]; then
        echo "FATAL: Invalid root directory: '$dir'" >&2
        return 1
    fi

    echo "$dir"
}

# =================================================================
# ИНИЦИАЛИЗАЦИЯ DPX_ROOT
# =================================================================

if [[ -z "${DPX_ROOT:-}" ]]; then
    DPX_ROOT="$(dpx_get_root)" || exit 1
fi
readonly DPX_ROOT

# =================================================================
# ЭКСПОРТ
# =================================================================

export DPX_ROOT DPX_OS_TYPE DPX_SED_INPLACE_EXT