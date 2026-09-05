#!/usr/bin/env bash
# =================================================================
# DPX Paths Module - defin path, cross-platform permission
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_PATHS_LOADED:-}" ]] && return 0
readonly _DPX_PATHS_LOADED=1

# =================================================================
# DEFIN OS (BSD/GNU compatibility)
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
# CROSS-PLATFORM PERMISSION PATH
# =================================================================

# Reliable permission symlinks (GNU/BSD compatible)
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

    # Protect from cyclic symlinks
    [[ $iteration -ge $max_iterations ]] && return 1

    # Return ABSOLUTE director, ifs path exist
    if [[ -e "$source" ]]; then
        # Transition in folder and print its full path (not relative!)
        cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
        return 0
    fi

    return 1
}

# Determine the project root directory
dpx_get_root() {
    local source="${BASH_SOURCE[0]:-$0}"
    local dir

    # Trying resolve symlinks
    if dir="$(dpx_resolve_symlink "$source")" && [[ -n "$dir" ]]; then
        : # success
    else
        # Fallback: simple defin without permission symlinks
        dir="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || {
            echo "FATAL: Cannot determine script root" >&2
            return 1
        }
    fi

    # Bring up from lib/command/tests on level above
    case "$(basename "$dir")" in
        lib|command|tests)
            dir="$(dirname "$dir")"
            ;;
    esac

    # Validation
    if [[ -z "$dir" ]] || [[ ! -d "$dir" ]]; then
        echo "FATAL: Invalid root directory: '$dir'" >&2
        return 1
    fi

    echo "$dir"
}

# =================================================================
# INITIALIZATION DPX_ROOT
# =================================================================

if [[ -z "${DPX_ROOT:-}" ]]; then
    DPX_ROOT="$(dpx_get_root)" || exit 1
fi
readonly DPX_ROOT

# =================================================================
# EXPORT
# =================================================================

export DPX_ROOT DPX_OS_TYPE DPX_SED_INPLACE_EXT