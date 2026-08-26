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
    ["default_tunnel_provider"]="ngrok"   # ngrok | cloudflare (dpx tunnel)
    ["db_user"]="db"                      # MySQL/MariaDB credentials used by scaffolders
    ["db_password"]="db"
    ["cli_lang"]="auto"                   # auto | en | ru (CLI output language)
    ["auto_update_check"]="true"          # daily non-blocking update notice (dpx update)
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
# =================================================================
# USER CONFIG FILE & FIRST-RUN WIZARD (v1.4.0)
#
# Canonical user configuration path: ~/.config/dpx/dpx.conf
# The wizard writes managed keys via upsert, preserving any manual
# lines the user added. Non-interactive sessions never hang: they
# receive a hint pointing at `dpx config`.
# =================================================================

config_user_file() {
    printf '%s/.config/%s/%s.conf\n' "${HOME}" "$TOOL_NAME" "$TOOL_NAME"
}

config_needs_first_run() {
    [[ ! -f "$(config_user_file)" ]]
}

# Upsert `key = value` into the user config, preserving all other
# lines (comments, custom keys). Creates parent directories.
config_upsert_kv() {
    local key="$1" value="$2"
    local file
    file="$(config_user_file)"
    ensure_directory "$(dirname "$file")"

    if [[ -f "$file" ]] && grep -qE "^${key}[[:space:]]*=" "$file"; then
        safe_sed_inplace "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
    else
        printf '%s = %s\n' "$key" "$value" >> "$file"
    fi
}

# Interactive first-run/setup wizard.
# STDOUT/STDERR: dialog; returns 0 in all non-fatal paths.
# $1 = optional "force": explicit `dpx config` runs even with piped
# stdin (answers/defaults are read); the first-run HOOK never forces.
config_run_wizard() {
    local force="${1:-}"
    # Safety: never hang automated/non-interactive sessions unless forced.
    if [[ "$force" != "force" && ! -t 0 ]]; then
        print_info "$(t cfg.firstrun.hint)"
        return 0
    fi

    local file
    file="$(config_user_file)"

    print_header "$(t cfg.wizard.title)"
    print_info  "$(t cfg.wizard.hint) $file"
    echo ""

    local projects_root provider db_user db_password lang

    projects_root="$(get_config 'ddev_projects_base_path' "$HOME/projects")"
    prompt_input "$(t cfg.q.projects_root)" "$projects_root" projects_root
    ensure_directory "$projects_root"

    provider="$(get_config 'default_tunnel_provider' 'ngrok')"
    while :; do
        prompt_input "$(t cfg.q.provider) (ngrok/cloudflare)" "$provider" provider
        case "$provider" in
            ngrok|cloudflare|cloudflared) provider="${provider%cloudflared}"; provider="${provider:-cloudflare}"
                [[ "$provider" == "cloudflared" ]] && provider="cloudflare"
                break ;;
            *) print_warning "$(t err.unknown.choice "$provider")" ;;
        esac
    done

    db_user="$(get_config 'db_user' 'db')"
    prompt_input "$(t cfg.q.db_user)" "$db_user" db_user

    db_password="$(get_config 'db_password' 'db')"
    prompt_input "$(t cfg.q.db_password)" "$db_password" db_password

    lang="$(get_config 'cli_lang' 'auto')"
    while :; do
        prompt_input "$(t cfg.q.lang) (auto/en/ru)" "$lang" lang
        case "$lang" in
            auto|en|ru) break ;;
            *) print_warning "$(t err.unknown.choice "$lang")" ;;
        esac
    done

    config_upsert_kv "ddev_projects_base_path" "$projects_root"
    config_upsert_kv "default_tunnel_provider" "$provider"
    config_upsert_kv "db_user"                 "$db_user"
    config_upsert_kv "db_password"             "$db_password"
    config_upsert_kv "cli_lang"                "$lang"

    load_config   # re-read so the current process uses new values
    dpx_detect_lang

    print_success "$(t cfg.saved): $file"
    return 0
}

# First-run hook invoked by the entry point before any command.
config_first_run_hook() {
    config_needs_first_run || return 0

    # Interactive terminals get the full wizard; automated sessions
    # must never hang - a short hint is enough.
    if [[ -t 0 && "${DPX_SKIP_FIRST_RUN:-}" != "1" ]]; then
        config_run_wizard
    else
        print_info "$(t cfg.firstrun.hint)"
    fi
    return 0
}
