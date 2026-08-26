#!/usr/bin/env bash
# =================================================================
# DPX Config Module - management configuration
# =================================================================

[[ -n "${_DPX_CONFIG_LOADED:-}" ]] && return 0
readonly _DPX_CONFIG_LOADED=1

# =================================================================
# CONFIGURATION BY DEFAULT
# =================================================================

declare -A DEFAULT_CONFIG=(
    # --- BASIC PATH TO EVERYONE (WORKSPACE) ---
    ["workspace_root"]="~/projects/work"

    # --- DYNAMIC PATHS (use $WORKSPACE_ROOT) ---
    ["db_prod_path"]="\$WORKSPACE_ROOT/db_prod"
    ["db_local_path"]="\$WORKSPACE_ROOT/db_local"
    ["ddev_projects_base_path"]="\$WORKSPACE_ROOT/php"
    ["devilbox_path_root"]="\$WORKSPACE_ROOT/devilbox"
    ["devilbox_data_base_path"]="\$WORKSPACE_ROOT/devilbox/data"
    ["starter_theme_path"]="\$WORKSPACE_ROOT/_s-template"

    # --- FULL BACKUPS PROJECTS (files + database) ---
    ["full_backup_path"]="\$WORKSPACE_ROOT/backups"
    ["full_backup_keep"]="3"

    # --- REMAINING SETUPS ---
    ["default_php_version"]="7.4"
    ["default_db_type"]="mysql"
    ["default_db_version"]="5.7"
    ["default_prod_tld"]="by"
    ["admin_user"]="admin"
    ["admin_email"]="admin@example.com"
    ["admin_pass"]="admin"
    ["project_tld"]="lo"
)

# =================================================================
# DOWNLOAD CONFIGURATIONS
# =================================================================

load_config() {
    # Load cascade (Merge) without elif!
    # Each next overwrites only need keies
    local global_config="/etc/${TOOL_NAME}/${TOOL_NAME}.conf"
    local user_config="$HOME/.config/${TOOL_NAME}/${TOOL_NAME}.conf"
    local local_config="${DPX_ROOT}/config/${TOOL_NAME}.conf"

    [[ -f "$global_config" ]] && _parse_config_file "$global_config"
    [[ -f "$user_config" ]]   && _parse_config_file "$user_config"
    [[ -f "$local_config" ]]  && _parse_config_file "$local_config"
}

# Parsing configuration file
_parse_config_file() {
    local config_file="$1"
    local key value

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        # Skip empty lines
        [[ -z "$key" ]] && continue

        # Remove whitespaces around key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        # Cleanup value from whitespaces UNTIL quotes (otherwise quotes not remove)
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # Remove quotes from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        DEFAULT_CONFIG["$key"]="$value"
    done < "$config_file"
}

# =================================================================
# ACCESSORS CONFIGURATIONS
# =================================================================

get_config() {
    local key="$1"
    local default="${2:-}"
    echo "${DEFAULT_CONFIG[$key]:-$default}"
}

set_config() {
    local key="$1"
    local value="$2"
    DEFAULT_CONFIG["$key"]="$value"
}

has_config() {
    local key="$1"
    [[ -n "${DEFAULT_CONFIG[$key]:-}" ]]
}

list_config() {
    local key
    for key in "${!DEFAULT_CONFIG[@]}"; do
        printf "%-30s = %s\n" "$key" "${DEFAULT_CONFIG[$key]}"
    done | sort
}

# =================================================================
# SPECIALIZED GETTERS
# =================================================================

get_db_prod_path() {
    get_config "db_prod_path"
}

get_db_local_path() {
    get_config "db_local_path"
}

get_ddev_projects_path() {
    get_config "ddev_projects_base_path"
}

get_devilbox_path() {
    get_config "devilbox_path_root"
}

get_default_php_version() {
    get_config "default_php_version"
}

get_project_tld() {
    get_config "project_tld"
}