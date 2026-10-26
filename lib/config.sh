#!/usr/bin/env bash
# =================================================================
# DPX Config Module - management configuration
# =================================================================

# Quoted tildes in DEFAULT_CONFIG are literal defaults expanded later by
# the config path resolver; they must not expand at parse time.
# shellcheck disable=SC2088

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
    # [P-7] Retention for *_LOCAL_BACKUP_*.sql protective dumps created
    # by db pull / db restore before overwriting the local database.
    ["local_backup_keep"]="3"

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
    # Canonical global storage aliases. These are kept in sync with the
    # legacy keys above and exported for integrations using DPX_* names.
    ["DPX_PROJECTS_DIR"]=""
    ["DPX_DB_LOCAL_DIR"]=""
    ["DPX_DB_PROD_DIR"]=""
    ["DPX_BACKUP_DIR"]=""
)

# =================================================================
# DOWNLOAD CONFIGURATIONS
# =================================================================

load_config() {
    # Load cascade (Merge) without elif!
    # Each next overwrites only need keies
    #
    # [FIX P-3] PRECEDENCE (lowest -> highest):
    #   1. /etc/dpx/dpx.conf                 — system-wide defaults
    #   2. ${DPX_ROOT}/config/dpx.conf       — repo-local seed/defaults
    #      (shipped values only; NEVER overrides explicit user settings)
    #   3. ~/.config/dpx/dpx.conf            — user application config
    #   4. ~/.config/dpx/config              — user canonical global paths
    # The repo-local file is deliberately loaded BEFORE the user files so
    # it can only seed defaults the user has not set anywhere else.
    local global_config="/etc/${TOOL_NAME}/${TOOL_NAME}.conf"
    local user_config="$HOME/.config/${TOOL_NAME}/${TOOL_NAME}.conf"
    local canonical_config="$HOME/.config/${TOOL_NAME}/config"
    local local_config="${DPX_ROOT}/config/${TOOL_NAME}.conf"

    [[ -f "$global_config" ]] && _parse_config_file "$global_config"
    [[ -f "$local_config" ]]  && _parse_config_file "$local_config"

    # User-owned files may contain credentials. Re-secure legacy 0644
    # files on every load; a chmod failure is reported but does not make
    # the whole CLI unusable.
    if [[ -f "$user_config" ]]; then
        _config_secure_file "$user_config" \
            || print_warning "Failed to secure permissions on $user_config (expected 0600)." >&2
        _parse_config_file "$user_config"
    fi
    if [[ -f "$canonical_config" ]]; then
        _config_secure_file "$canonical_config" \
            || print_warning "Failed to secure permissions on $canonical_config (expected 0600)." >&2
        _parse_config_file "$canonical_config"
    fi
    _sync_global_path_config

    if declare -F dpx_detect_lang >/dev/null; then
        dpx_detect_lang
    fi
}

_expand_config_path() {
    local value="$1"
    value="${value//\$HOME/$HOME}"
    value="${value//\$WORKSPACE_ROOT/${DEFAULT_CONFIG[workspace_root]}}"

    # [Finding 6] Tilde expansion — leading form only, standard contract:
    #   ~/anything  -> $HOME/anything
    #   ~            -> $HOME          (bare tilde)
    #   ~user/...    -> NOT expanded (user homes are out of scope; left
    #                   literal so the misconfiguration stays visible)
    # The `~` patterns below are quoted so bash does not expand the RHS
    # at parse time and the tests actually fire.
    if [[ "$value" == "~" ]]; then
        value="$HOME"
    elif [[ "$value" == "~/"* ]]; then
        value="$HOME/${value#\~/}"
    fi
    printf '%s\n' "$value"
}

_sync_global_path_config() {
    local projects local_db prod_db backups
    projects="${DEFAULT_CONFIG[DPX_PROJECTS_DIR]:-}"
    [[ -z "$projects" ]] && projects="${DEFAULT_CONFIG[ddev_projects_base_path]:-\$HOME/projects/php}"
    projects="$(_expand_config_path "$projects")"
    local_db="${DEFAULT_CONFIG[DPX_DB_LOCAL_DIR]:-}"
    [[ -z "$local_db" ]] && local_db="${DEFAULT_CONFIG[db_local_path]:-\$HOME/projects/db_local}"
    prod_db="${DEFAULT_CONFIG[DPX_DB_PROD_DIR]:-}"
    [[ -z "$prod_db" ]] && prod_db="${DEFAULT_CONFIG[db_prod_path]:-\$HOME/projects/db_prod}"
    backups="${DEFAULT_CONFIG[DPX_BACKUP_DIR]:-}"
    [[ -z "$backups" ]] && backups="${DEFAULT_CONFIG[full_backup_path]:-\$HOME/projects/backups}"
    local_db="$(_expand_config_path "$local_db")"
    prod_db="$(_expand_config_path "$prod_db")"
    backups="$(_expand_config_path "$backups")"

    export DPX_PROJECTS_DIR="$projects" DPX_DB_LOCAL_DIR="$local_db" \
        DPX_DB_PROD_DIR="$prod_db" DPX_BACKUP_DIR="$backups"
    DEFAULT_CONFIG[DPX_PROJECTS_DIR]="$projects"
    DEFAULT_CONFIG[DPX_DB_LOCAL_DIR]="$local_db"
    DEFAULT_CONFIG[DPX_DB_PROD_DIR]="$prod_db"
    DEFAULT_CONFIG[DPX_BACKUP_DIR]="$backups"
    DEFAULT_CONFIG[ddev_projects_base_path]="$projects"
    DEFAULT_CONFIG[db_local_path]="$local_db"
    DEFAULT_CONFIG[db_prod_path]="$prod_db"
    DEFAULT_CONFIG[full_backup_path]="$backups"
}

# Config file value codec.
#
# Writers emit `key = value` for simple values so existing configs stay
# human-readable. Values containing whitespace, '#', quotes, or
# backslashes are emitted as a double-quoted string with '\\' and '\"'
# escapes. Newline/CR bytes are rejected outright: they would turn one
# assignment into additional config lines (key injection).
_config_validate_key() {
    local key="$1"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
        print_error "Invalid config key: ${key}" >&2
        return 1
    fi
    return 0
}

_config_ensure_trailing_newline() {
    local file="$1"
    local last_byte=""

    [[ -s "$file" ]] || return 0
    if ! last_byte="$(tail -c 1 "$file" 2>/dev/null)"; then
        return 1
    fi
    # Command substitution strips a trailing newline, so an empty result
    # means the file already ends with the separator we need.
    [[ -z "$last_byte" ]] && return 0
    printf '\n' >> "$file"
}

_config_serialize_value() {
    local value="$1"

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        print_error "Config values must not contain newline or carriage-return characters." >&2
        return 1
    fi

    if [[ -z "$value" ]]; then
        printf '""'
        return 0
    fi

    local force_quote=0
    [[ "$value" == *[[:space:]]* ]] && force_quote=1
    [[ "$value" == *'#'* ]] && force_quote=1
    [[ "$value" == *'"'* ]] && force_quote=1
    [[ "$value" == *"'"* ]] && force_quote=1
    [[ "$value" == *\\* ]] && force_quote=1

    if (( force_quote == 0 )); then
        printf '%s' "$value"
        return 0
    fi

    local escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '"%s"' "$escaped"
}

# Decode a double-quoted value. $1 includes the opening quote. Unknown
# backslash escapes are preserved literally instead of being evaluated.
_config_decode_double_quoted() {
    local raw="$1"
    local decoded="" ch remainder
    local i=1 len=${#raw}

    while (( i < len )); do
        ch="${raw:i:1}"
        if [[ "$ch" == "\\" ]]; then
            i=$((i + 1))
            (( i < len )) || return 1
            ch="${raw:i:1}"
            case "$ch" in
                "\\"|'"') decoded+="$ch" ;;
                *) decoded+="\\$ch" ;;
            esac
        elif [[ "$ch" == '"' ]]; then
            remainder="${raw:i+1}"
            [[ "$remainder" =~ ^[[:space:]]*(#.*)?$ ]] || return 1
            printf '%s' "$decoded"
            return 0
        else
            decoded+="$ch"
        fi
        i=$((i + 1))
    done
    return 1
}

_config_decode_single_quoted() {
    local raw="$1"
    local rest remainder value

    [[ "$raw" == \'* ]] || return 1
    rest="${raw:1}"
    [[ "$rest" == *"'"* ]] || return 1

    value="${rest%%\'*}"
    remainder="${rest#*\'}"
    [[ "$remainder" =~ ^[[:space:]]*(#.*)?$ ]] || return 1
    printf '%s' "$value"
}

_config_parse_unquoted() {
    local value="$1"

    # A hash as the first non-space token is a comment with no value:
    # `key = # note` must not turn "# note" into the setting's value.
    if [[ "$value" == \#* ]]; then
        value=""
    fi

    # Strip at the FIRST whitespace+# marker. `%%` removes the longest
    # suffix, leaving the shortest prefix, so a value like
    # `abc # comment # more` becomes `abc` rather than `abc # comment`.
    if [[ "$value" == *[[:space:]]#* ]]; then
        value="${value%%[[:space:]]#*}"
    fi
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Parsing configuration file. A malformed quoted value aborts parsing:
# treating the remainder of a broken line as another assignment is what
# allowed a multi-line value to inject keys in the old parser.
_parse_config_file() {
    local config_file="$1"
    local line key value parsed

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore blank lines and comments after trimming leading whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Capture the complete RHS: unlike IFS='=', this keeps later '='.
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        if [[ "$value" == \"* ]]; then
            if ! parsed="$(_config_decode_double_quoted "$value")"; then
                print_error "Invalid double-quoted value for '${key}' in ${config_file}" >&2
                return 1
            fi
        elif [[ "$value" == \'* ]]; then
            if ! parsed="$(_config_decode_single_quoted "$value")"; then
                print_error "Invalid single-quoted value for '${key}' in ${config_file}" >&2
                return 1
            fi
        else
            parsed="$(_config_parse_unquoted "$value")"
        fi

        DEFAULT_CONFIG["$key"]="$parsed"
    done < "$config_file"
    return 0
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

    _config_validate_key "$key" || return 1
    _config_serialize_value "$value" >/dev/null || return 1
    DEFAULT_CONFIG["$key"]="$value"
    return 0
}

has_config() {
    local key="$1"
    [[ -n "${DEFAULT_CONFIG[$key]:-}" ]]
}

# Keys whose values must never be printed in plaintext by list_config
# (dpx config --show). Matched case-insensitively by substring.
declare -a _DPX_SECRET_CONFIG_KEYS=(
    "password"
    "pass"
    "token"
    "secret"
    "api_key"
)

_is_secret_config_key() {
    local key="${1,,}"
    local s
    for s in "${_DPX_SECRET_CONFIG_KEYS[@]}"; do
        [[ "$key" == *"$s"* ]] && return 0
    done
    return 1
}

list_config() {
    local key value
    for key in "${!DEFAULT_CONFIG[@]}"; do
        value="${DEFAULT_CONFIG[$key]}"
        if [[ -n "$value" ]] && _is_secret_config_key "$key"; then
            value="********"
        fi
        printf "%-30s = %s\n" "$key" "$value"
    done | sort
}

# =================================================================
# SPECIALIZED GETTERS
# =================================================================

# Canonicalize tunnel provider input. Accepted aliases are folded
# silently; unknown values are echoed back unchanged so callers can
# still reject them with their own error message.
#   cloudflared | cf -> cloudflare
#   ngrok            -> ngrok
config_normalize_provider() {
    local value="${1:-}"
    value="${value,,}"

    case "$value" in
        cloudflare|cloudflared|cf) printf '%s\n' "cloudflare" ;;
        ngrok)                     printf '%s\n' "ngrok" ;;
        *)                         printf '%s\n' "$value" ;;
    esac
}

# True when the value is a provider DPX can actually drive.
config_provider_is_valid() {
    case "$(config_normalize_provider "${1:-}")" in
        ngrok|cloudflare) return 0 ;;
        *) return 1 ;;
    esac
}

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

config_global_file() {
    printf '%s/.config/%s/config\n' "${HOME}" "$TOOL_NAME"
}

config_display_file() {
    config_global_file
}

# Files managed below may contain credentials (db_password, tokens):
# keep them readable by the owner only. A failed chmod is fatal because
# silently leaving the file at 0644 would defeat the protection.
_config_secure_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    chmod 600 "$file" 2>/dev/null
}

config_needs_first_run() {
    [[ ! -f "$(config_user_file)" && ! -f "$(config_global_file)" ]]
}

# Escape sed replacement metacharacters (&, \, and the s-delimiter |)
# so arbitrary user values can never corrupt the upsert expression.
_sed_escape_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"   # backslash first
    value="${value//&/\\&}"     # & expands to the whole match
    value="${value//|/\\|}"     # s||| delimiter
    printf '%s\n' "$value"
}

# Shared implementation for both user and canonical global config files.
#
# Guarantees:
#   - the target key has exactly one active assignment after the call;
#   - legacy duplicate assignments are collapsed, not multiplied;
#   - the file ends with a newline even when the old file did not;
#   - comments, blank lines and unrelated keys keep their order;
#   - values go through the quoting/escaping codec, never raw sed input.
_config_upsert_file_kv() {
    local file="$1" key="$2" value="$3"
    local serialized match_count escaped script line_number line
    local line_numbers
    local -a key_lines=()

    _config_validate_key "$key" || return 1
    serialized="$(_config_serialize_value "$value")" || return 1

    ensure_directory "$(dirname "$file")" || return 1

    # Create new files owner-only from the very first byte.
    if [[ ! -e "$file" ]]; then
        (umask 077 && : > "$file") || return 1
    fi
    if [[ ! -f "$file" ]]; then
        print_error "Config path is not a regular file: $file" >&2
        return 1
    fi

    # Re-secure before reading/writing: legacy 0644 files may already
    # contain credentials.
    if ! _config_secure_file "$file"; then
        print_error "Failed to secure permissions on $file (expected 0600)" >&2
        return 1
    fi

    match_count="$(grep -cE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null)" || true
    match_count="${match_count//[[:space:]]/}"
    if [[ ! "$match_count" =~ ^[0-9]+$ ]]; then
        print_error "Failed to inspect config file: $file" >&2
        return 1
    fi

    if (( match_count == 0 )); then
        _config_ensure_trailing_newline "$file" || return 1
        printf '%s = %s\n' "$key" "$serialized" >> "$file" || return 1
    else
        # Update the first assignment in place and delete any stale
        # duplicates. Keep original line numbers: sed deletes later lines
        # after evaluating the same input record stream.
        if ! line_numbers="$(grep -nE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null)"; then
            print_error "Failed to inspect config file: $file" >&2
            return 1
        fi
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            line_number="${line%%:*}"
            if [[ ! "$line_number" =~ ^[0-9]+$ ]]; then
                print_error "Failed to parse config line numbers: $file" >&2
                return 1
            fi
            key_lines+=("$line_number")
        done <<< "$line_numbers"

        if (( ${#key_lines[@]} == 0 )); then
            print_error "Failed to locate existing config key: $key" >&2
            return 1
        fi

        escaped="$(_sed_escape_replacement "$serialized")"
        script="${key_lines[0]}s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${escaped}|"
        local i
        for (( i=1; i<${#key_lines[@]}; i++ )); do
            script+=";${key_lines[i]}d"
        done
        safe_sed_inplace "$script" "$file" || return 1
    fi

    _config_ensure_trailing_newline "$file" || return 1
    if ! _config_secure_file "$file"; then
        print_error "Failed to secure permissions on $file (expected 0600)" >&2
        return 1
    fi
    return 0
}

# Upsert `key = value` into the user config, preserving all other
# lines (comments, custom keys). Creates parent directories.
config_upsert_kv() {
    _config_upsert_file_kv "$(config_user_file)" "$1" "$2"
}

config_upsert_global_kv() {
    _config_upsert_file_kv "$(config_global_file)" "$1" "$2"
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

    # Keep central data outside project webroots. Existing users retain their
    # configured legacy paths; new users receive predictable sibling folders.
    local db_local_dir db_prod_dir backup_dir
    db_local_dir="$(get_config 'DPX_DB_LOCAL_DIR' "$HOME/projects/db_local")"
    db_prod_dir="$(get_config 'DPX_DB_PROD_DIR' "$HOME/projects/db_prod")"
    backup_dir="$(get_config 'DPX_BACKUP_DIR' "$HOME/projects/backups")"
    prompt_input "$(t cfg.q.db_local_path)" "$db_local_dir" db_local_dir
    prompt_input "$(t cfg.q.db_prod_path)" "$db_prod_dir" db_prod_dir
    prompt_input "$(t cfg.q.backup_path)" "$backup_dir" backup_dir

    provider="$(config_normalize_provider "$(get_config 'default_tunnel_provider' 'ngrok')")"
    if config_needs_first_run && command -v cloudflared >/dev/null 2>&1 \
        && ! command -v ngrok >/dev/null 2>&1; then
        provider="cloudflare"
    fi
    while :; do
        prompt_input "$(t cfg.q.provider) (ngrok/cloudflare)" "$provider" provider
        if config_provider_is_valid "$provider"; then
            provider="$(config_normalize_provider "$provider")"
            break
        fi
        print_warning "$(t err.unknown.choice "$provider")"
    done

    db_user="$(get_config 'db_user' 'db')"
    prompt_input "$(t cfg.q.db_user)" "$db_user" db_user

    db_password="$(get_config 'db_password' 'db')"
    # Never echo the credential and never print the stored secret as a
    # prompt default (including non-TTY/forced wizard runs). Empty input
    # keeps the current/default value.
    local db_password_input=""
    IFS= read -r -s -p "$(t cfg.q.db_password): " db_password_input || true
    printf '\n' >&2
    [[ -n "$db_password_input" ]] && db_password="$db_password_input"

    lang="$(get_config 'cli_lang' 'auto')"
    while :; do
        prompt_input "$(t cfg.q.lang) (auto/en/ru)" "$lang" lang
        case "$lang" in
            auto|en|ru) break ;;
            *) print_warning "$(t err.unknown.choice "$lang")" ;;
        esac
    done

    config_upsert_kv "ddev_projects_base_path" "$projects_root" || return 1
    config_upsert_kv "db_local_path" "$db_local_dir"            || return 1
    config_upsert_kv "db_prod_path" "$db_prod_dir"              || return 1
    config_upsert_kv "full_backup_path" "$backup_dir"           || return 1
    config_upsert_kv "default_tunnel_provider" "$provider"       || return 1
    config_upsert_kv "db_user"                 "$db_user"       || return 1
    config_upsert_kv "db_password"             "$db_password"   || return 1
    config_upsert_kv "cli_lang"                "$lang"          || return 1

    config_upsert_global_kv "DPX_PROJECTS_DIR" "$projects_root"  || return 1
    config_upsert_global_kv "DPX_DB_LOCAL_DIR" "$db_local_dir"  || return 1
    config_upsert_global_kv "DPX_DB_PROD_DIR" "$db_prod_dir"    || return 1
    config_upsert_global_kv "DPX_BACKUP_DIR" "$backup_dir"       || return 1

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
