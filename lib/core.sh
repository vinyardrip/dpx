#!/usr/bin/env bash
# =================================================================
# DPX Core - loader module (Loader)
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_CORE_LOADED:-}" ]] && return 0
readonly _DPX_CORE_LOADED=1

# =================================================================
# CONSTANTS (only unique for core.sh)
# =================================================================

readonly TOOL_NAME="${TOOL_NAME:-dpx}"

# Single source versions (Single Source of Truth) — read from .version
if [[ -f "${DPX_ROOT}/.version" ]]; then
    readonly DPX_VERSION="$(head -1 "${DPX_ROOT}/.version" | tr -d '[:space:]')"
else
    readonly DPX_VERSION="0.0.0-unknown"
fi

# =================================================================
# DOWNLOAD BASIC MODULE (order important!)
# =================================================================

# paths.sh - detects DPX_ROOT, DPX_OS_TYPE, DPX_SED_INPLACE_EXT
source "${DPX_ROOT}/lib/paths.sh"

# config.sh - download configurations
source "${DPX_ROOT}/lib/config.sh"
# i18n.sh - locale detection & message translation (DPX_LANG/LC_ALL/LANG)
source "${DPX_ROOT}/lib/i18n.sh"

# io.sh - output functions (print_*, COLOR_*); English default, ru via locale
source "${DPX_ROOT}/lib/io.sh"

# utils.sh - general utilities
source "${DPX_ROOT}/lib/utils.sh"


# args.sh - parsing arguments
source "${DPX_ROOT}/lib/args.sh"

# checks.sh - checks dependency, version, constants MIN_*
source "${DPX_ROOT}/lib/checks.sh"

# sudo.sh - safe work with privilegeds and files (Safe Sudo Protocol)
source "${DPX_ROOT}/lib/sudo.sh"

# meta.sh - management metadatas projects
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# CROSS-PLATFORM DEFIN HOME DIRECTORS
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

# Determin REAL_HOME UNTIL downloads configurations
REAL_HOME=$(dpx_get_real_home)
readonly REAL_HOME

# =================================================================
# INITIALIZATION CONFIGURATIONS Ands PATH
# =================================================================

# Load configuration
load_config
dpx_detect_lang   # resolve CLI language now that user config is loaded

# =================================================================
# EXPANDED PATH In CONFIGURATIONS
# =================================================================

# 1. Compute and expand main WORKSPACE_ROOT
DPX_WORKSPACE="${DEFAULT_CONFIG[workspace_root]}"
DPX_WORKSPACE="${DPX_WORKSPACE//\$HOME/$REAL_HOME}"
DPX_WORKSPACE="${DPX_WORKSPACE/#\~/$REAL_HOME}"

# 2. Function expanded path with support $WORKSPACE_ROOT
expand_path() {
    local path="$1"
    path="${path//\$WORKSPACE_ROOT/$DPX_WORKSPACE}"
    path="${path//\$HOME/$REAL_HOME}"
    path="${path/#\~/$REAL_HOME}"
    echo "$path"
}

# 3. Expand paths in ALL value DEFAULT_CONFIG
_dpx_expand_key=
for _dpx_expand_key in "${!DEFAULT_CONFIG[@]}"; do
    DEFAULT_CONFIG["$_dpx_expand_key"]=$(expand_path "${DEFAULT_CONFIG[$_dpx_expand_key]}")
done

# Get root director projects
PROJECTS_ROOT=$(get_config "ddev_projects_base_path")
export PROJECTS_ROOT

# =================================================================
# FUNCTIONS CORE
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
        print_info "Rotation: delete $count old files (left $keep_count)."
    fi
}

# =================================================================
# EXPORT
# =================================================================

export TOOL_NAME DPX_VERSION REAL_HOME DPX_WORKSPACE