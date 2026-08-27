#!/usr/bin/env bash
# =================================================================
# DPX Database Module - import, export, replace URL
# Version: v1.6.0 — strict identifiers and SQL literal escaping
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_DATABASE_LOADED:-}" ]] && return 0
readonly _DPX_DATABASE_LOADED=1

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"

# =================================================================
# SINGLE POINT EXTRACT db_prefix (v1.4.20)
#
# grep from wp-config.php — WITHOUT call PHP generally.
# Validation: only [a-zA-Z0-9_]. Durings invalid — fatal.
# All functions module use THIS function.
# =================================================================

db_validate_identifier() {
    validate_safe_identifier "$1" "${2:-database identifier}"
}

db_escape_sql_literal() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s\n' "$value"
}

db_get_prefix() {
    local project_path="$1"
    local config_file="${project_path}/wp-config.php"

    if [[ ! -f "$config_file" ]]; then
        print_error "db_get_prefix: wp-config.php not found: $config_file" >&2
        return 1
    fi

    local prefix
    prefix=$(grep -E '^\s*\$table_prefix\s*=' "$config_file" 2>/dev/null \
        | grep -oE "['\"].*[\'\"]" | tr -d "'\"" | head -1)

    # Fallback for standard installs
    [[ -z "$prefix" ]] && prefix="wp_"

    # Validation: only letters, digits, underscore
    db_validate_identifier "$prefix" "table prefix" || return 1

    echo "$prefix"
}

# =================================================================
# DYNAMIC DEFIN NAMEDS database FROM CONFIG CMS [FIX refresh]
#
# Extracts name bases data without call container:
#   WordPress : define('DB_NAME', '...');      from wp-config.php
#   Joomla    : public $db = '...';            from configuration.php
#   OpenCart  : define('DB_DATABASE', '...');  from config.php
#
# Priority: regex by config -> WP-CLI (only WordPress, best effort:
# `ddev wp config get DB_NAME` exact for non-standard configs).
#
# CONTRACT: STDOUT — name database (may was empty); UI — in STDERR.
# Empty output = determin not remove, caller makes fallback
# on name project.
# =================================================================

db_get_db_name() {
    local project_path="$1"
    local cms_type="${2:-}"

    if [[ -z "$cms_type" ]]; then
        cms_type=$(detect_cms_type "$project_path" 2>/dev/null || echo "$CMS_TYPE_PHP")
    fi

    local config_file db_name=""

    case "$cms_type" in
        "$CMS_TYPE_WORDPRESS")
            config_file="$project_path/wp-config.php"
            if [[ -f "$config_file" ]]; then
                # Variants: define('DB_NAME','x'); define( "DB_NAME", "x" ); and t.p.
                db_name=$(grep -E "define[[:space:]]*\([[:space:]]*['\"]DB_NAME['\"]" "$config_file" 2>/dev/null \
                    | head -1 \
                    | sed -E "s/.*define[[:space:]]*\([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/")
            fi
            ;;
        "$CMS_TYPE_JOOMLA")
            config_file="$project_path/configuration.php"
            if [[ -f "$config_file" ]]; then
                # public $db = 'xyz'; — with any count whitespaces
                db_name=$(grep -E 'public[[:space:]]+\$db[[:space:]]*=' "$config_file" 2>/dev/null \
                    | head -1 \
                    | sed -E "s/.*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/")
            fi
            ;;
        "$CMS_TYPE_OPENCART" | "$CMS_TYPE_OCSTORE")
            config_file="$project_path/config.php"
            if [[ -f "$config_file" ]]; then
                db_name=$(grep -E "define[[:space:]]*\([[:space:]]*['\"]DB_DATABASE['\"]" "$config_file" 2>/dev/null \
                    | head -1 \
                    | sed -E "s/.*define[[:space:]]*\([[:space:]]*['\"]DB_DATABASE['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/")
            fi
            ;;
    esac

    # DDEV config may explicitly override the conventional `db` name.
    if [[ -z "$db_name" && -f "$project_path/.ddev/config.yaml" ]]; then
        db_name=$(grep -E '^(database_name|db_name):[[:space:]]*' "$project_path/.ddev/config.yaml" 2>/dev/null \
            | head -1 | sed -E 's/^[^:]+:[[:space:]]*//')
        db_name="${db_name//$'\r'/}"
        db_name="${db_name%%#*}"
        db_name="${db_name#"${db_name%%[![:space:]]*}"}"
        db_name="${db_name%"${db_name##*[![:space:]]}"}"
        db_name="${db_name#\"}"
        db_name="${db_name%\"}"
        db_name="${db_name#\'}"
        db_name="${db_name%\'}"
    fi

    # Laravel and other dotenv-based applications commonly keep the DB name
    # in .env rather than a CMS PHP configuration file.
    if [[ -z "$db_name" && -f "$project_path/.env" ]]; then
        db_name=$(grep -E '^(DB_DATABASE|DB_NAME)[[:space:]]*=' "$project_path/.env" 2>/dev/null \
            | head -1 | sed -E 's/^[^=]+=[[:space:]]*//')
        db_name="${db_name//$'\r'/}"
        db_name="${db_name%%#*}"
        db_name="${db_name#"${db_name%%[![:space:]]*}"}"
        db_name="${db_name%"${db_name##*[![:space:]]}"}"
        db_name="${db_name#\"}"
        db_name="${db_name%\"}"
        db_name="${db_name#\'}"
        db_name="${db_name%\'}"
    fi

    # WP-CLI fallback: only ifs regex not triggered and this WordPress.
    # v1.5.1: PHP diagnostics suppressed NATIVELY at engine level
    # (display_errors=0 + E_DEPRECATED masked) and WP-CLI runs with
    # --quiet — STDOUT contains ONLY the payload, no grep filtering.
    if [[ -z "$db_name" && "$cms_type" == "$CMS_TYPE_WORDPRESS" ]]; then
        db_name=$(cd "$project_path" 2>/dev/null \
            && ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" \
                /usr/local/bin/wp config get DB_NAME --quiet --allow-root 2>/dev/null \
            | head -1) || db_name=""
    fi

    # Validation: name database — only safe symbols (protect from garbage).
    # The CMS-defined name is authoritative; if it is invalid, abort.
    # Heuristic values from .env / .ddev/config.yaml are soft — bad
    # formatting (CRLF, inline comments, hyphens) means "not detected"
    # and the caller falls back to the project name.
    if [[ -n "$db_name" ]]; then
        if ! db_validate_identifier "$db_name" "database name"; then
            if [[ "$cms_type" == "$CMS_TYPE_WORDPRESS" \
               || "$cms_type" == "$CMS_TYPE_JOOMLA" \
               || "$cms_type" == "$CMS_TYPE_OPENCART" \
               || "$cms_type" == "$CMS_TYPE_OCSTORE" ]]; then
                return 1
            fi
            db_name=""
        fi
    fi

    echo "$db_name"
}

db_resolve_name_interactive() {
    local project_path="$1" cms_type="${2:-}" fallback="${3:-}"
    local db_name=""
    db_name="$(db_get_db_name "$project_path" "$cms_type")" || return 1
    if [[ -z "$db_name" && -t 0 ]]; then
        prompt_input "Database name" "$fallback" db_name
    fi
    printf '%s\n' "${db_name:-$fallback}"
}

# Newest-first dump picker. UI goes to stderr and the selected absolute path
# is the only stdout value, preserving command-substitution contracts.
#
# Interactive with a prefix match: the user always sees the list and
# picks a number. When the prefix misses and stdin is not a real tty
# the picker refuses, because "default to entry 1" against a list of
# other projects' dumps would silently overwrite the local DB.
db_pick_dump_file() {
    local directory="$1" prefix="${2:-}"
    [[ -d "$directory" ]] || return 1

    local -a files=()
    if [[ -n "$prefix" ]]; then
        mapfile -t files < <(command ls -1t "$directory"/"$prefix"*.sql "$directory"/"$prefix"*.sql.gz 2>/dev/null)
    fi
    if (( ${#files[@]} == 0 )); then
        # Refuse a widened list (other projects' dumps) without a tty.
        [[ -t 0 ]] || return 1
        mapfile -t files < <(command ls -1t "$directory"/*.sql "$directory"/*.sql.gz 2>/dev/null)
        (( ${#files[@]} > 0 )) && [[ -n "$prefix" ]] \
            && print_warning "No dump matches prefix '${prefix}' — listing every dump in ${directory}." >&2
    fi
    (( ${#files[@]} > 0 )) || return 1

    print_info "Available database dumps (newest first):" >&2
    local i
    for i in "${!files[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "$(basename "${files[i]}")" >&2
    done
    local choice=""
    read -r -p "Select dump [1]: " choice || return 1
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )) || return 1
    printf '%s\n' "${files[$((choice - 1))]}"
}

# =================================================================
# SQL-ONLY: Reading option from database directly via ddev mysql
#
# NO WAY WP-CLI. Clean SQL to MySQL.
# Returns truncated value via stdout.
#
# v1.5.1: grep filtering REMOVED. Scalar SELECT returns a single row,
# so the payload is taken as the LAST stdout line — any leading
# container/PHP chatter (if the wrapper ever emits it) is discarded
# natively instead of being pattern-matched away by grep.
# =================================================================

db_sql_get_option() {
    local project_path="$1"
    local option_name="$2"
    local option_sql

    option_sql="$(db_escape_sql_literal "$option_name")"

    local prefix
    prefix=$(db_get_prefix "$project_path") || return 1

    local value
    value=$(cd "$project_path" && ddev mysql -N -B -e "SELECT option_value FROM ${prefix}options WHERE option_name='${option_sql}';" 2>/dev/null \
        | tail -1)

    # Cleanup from whitespace and \r
    value="${value// /}"
    value="${value%$'\r'}"
    value="${value%/}"

    echo "$value"
}

# =================================================================
# SQL-ONLY: Delete transients by mask via ddev mysql
#
# Uses for Flatsome and other plugins, whoses transients
# need clean without downloads PHP/WP-CLI.
# v1.4.21: stderr suppressed, stdout not filter (DELETE not
# returns data, only affected rows).
# =================================================================

db_sql_delete_transients() {
    local project_path="$1"
    local mask="$2"  # e.g. 'flatsome_%' ors 'elementor_%'
    local mask_sql

    mask_sql="$(db_escape_sql_literal "$mask")"

    local prefix
    prefix=$(db_get_prefix "$project_path") || return 1

    (cd "$project_path" && ddev mysql -N -B -e "DELETE FROM ${prefix}options WHERE option_name LIKE '_transient_${mask_sql}' OR option_name LIKE '_transient_timeout_${mask_sql}';" 2>/dev/null) || true
}

# =================================================================
# SQL-ONLY: Count remaining old URL in database (debug)
#
# Scans wp_options and wp_postmeta on subject old URL.
# Uses for diagnostics mixed URL.
# =================================================================

db_sql_count_old_url() {
    local project_path="$1"
    local old_url="$2"
    local old_url_sql

    old_url_sql="$(db_escape_sql_literal "$old_url")"

    local prefix
    prefix=$(db_get_prefix "$project_path") || return 1

    local count=0
    count=$(cd "$project_path" && ddev mysql -N -B -e "
        SELECT (
            SELECT COUNT(*) FROM ${prefix}options WHERE option_value LIKE '%${old_url_sql}%'
        ) + (
            SELECT COUNT(*) FROM ${prefix}postmeta WHERE meta_value LIKE '%${old_url_sql}%'
        );" 2>/dev/null \
        | tail -1)

    echo "${count:-0}"
}

# =================================================================
# PATHS
# =================================================================

get_db_prod_path() {
    get_config "db_prod_path"
}

get_db_local_path() {
    get_config "db_local_path"
}

# =================================================================
# IMPORT Ands EXPORT (WITHOUT FORCED GZIP)
# =================================================================

# Import dump in database project.
#
# [ISSUE 2] Before import performs soft-restart containers
# (ddev_soft_restart): resets MySQL-connection and state
# InnoDB, snapshot lock timeouts and errors buffers on hot
# imports (often Joomla-update, structural patches).
#
# ARGUMENTS:
#   $1 — path to dump (.sql / .sql.gz)
#   $2 — project_path
#   $3 — pre_flush: "true" (by default) execute soft-restart,
#        "false" — skipp (e.g., ser small imports).
db_import() {
    local sql_file="$1"
    local project_path="$2"
    local pre_flush="${3:-true}"

    [[ -n "$project_path" ]] && cd "$project_path" || return 1
    validate_file "$sql_file" "SQL file" || return 1

    print_step "auto" "Import bases data [$(basename "$sql_file")]"

    # Name DDEV-project = name directors project (see. projects_list)
    local project_name
    project_name=$(basename "$project_path")

    # [ISSUE 2] Flush state MySQL before hot import
    if [[ "$pre_flush" == "true" ]]; then
        print_info "Soft-restart containers (flush connection MySQL)..." >&2
        if ! ddev_soft_restart "$project_name"; then
            print_warning "Soft-restart not remove — continue without flush state."
        fi
    fi

    # [ISSUE 2] Import via wrapper with fallback (--name/--src -> cd/--file)
    if ddev_import_db "$project_name" "$project_path" "$sql_file"; then
        print_success "Base data imported."
        return 0
    else
        print_error "Error durings import bases data."
        return 1
    fi
}

db_export() {
    local output_file="$1"
    local project_path="$2"
    local gzip="${3:-false}"

    [[ -n "$project_path" ]] && cd "$project_path" || return 1
    ensure_directory "$(dirname "$output_file")"

    print_step "auto" "$(t msg.db.export)"

    if ddev export-db --gzip="$gzip" --file="$output_file" >/dev/null 2>&1; then
        print_success "Export completion: $(basename "$output_file")"
        return 0
    else
        print_error "Error durings export bases data."
        return 1
    fi
}

# =================================================================
# LOCAL BACKUP (Snap / Refresh Backup)
# =================================================================

db_backup_local() {
    local project_name="$1"
    local project_path="$2"
    local backup_dir="${3:-$(get_db_local_path)}"
    local tag="${4:-LOCAL_BACKUP}"

    ensure_directory "$backup_dir"

    local filename
    filename=$(db_generate_export_filename "$project_name" "$tag")
    local backup_file="${backup_dir}/${filename%.gz}"

    print_step "auto" "Create reserve cops before operation..." >&2

    if db_export "$backup_file" "$project_path" "false" >&2; then
        echo "$backup_file"
        return 0
    else
        return 1
    fi
}

# =================================================================
# IMPORT With REPLACE URL (for non-WordPress projects)
#
# v1.5.1: raw `sed` URL substitution REMOVED. Raw byte replace breaks
# PHP-serialized payloads (Joomla configuration.php strings, OpenCart
# settings, CMS widgets stored as `s:LEN:"VALUE";`): the byte-length
# header becomes stale and unserialize() silently fails after import.
#
# Replacement pipeline (SERIALIZATION-SAFE):
#   1. Dump + helper (lib/php_helpers/dpx_serialize_safe_replace.php)
#      are staged into "${project_path}/.dpx/tmp/" — inside the DDEV
#      bind mount, so container sees them under /var/www/html.
#   2. Helper runs INSIDE the container via `ddev exec php` with
#      engine-level diagnostics suppression:
#        -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED"
#      It rewrites URL occurrences AND recomputes s:N:"..."; byte
#      lengths. Executing in the container makes behavior identical
#      on macOS (BSD sed/awk absent from the equation) and Linux.
#   3. Patched dump imported through regular db_import().
# =================================================================

db_import_with_replace() {
    local sql_file="$1"
    local old_url="$2"
    local new_url="$3"
    local project_path="$4"

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then
        print_error "db_import_with_replace: project directory not found: $project_path" >&2
        return 1
    fi

    local helper_src="${DPX_ROOT}/lib/php_helpers/dpx_serialize_safe_replace.php"
    if [[ ! -f "$helper_src" ]]; then
        print_error "db_import_with_replace: serialization-safe helper missing: $helper_src" >&2
        return 1
    fi

    print_step "auto" "Preparation SQL with serialization-safe URL replace..."

    # Stage input + helper inside the project (visible to container at /var/www/html)
    local work_rel=".dpx/tmp"
    local work_dir="${project_path}/${work_rel}"
    ensure_directory "$work_dir" || return 1

    local helper_rel="${work_rel}/dpx_serialize_safe_replace.php"
    local in_rel="${work_rel}/dpx_import_in.sql"
    local out_rel="${work_rel}/dpx_import_out.sql"

    if ! cp "$sql_file" "${project_path}/${in_rel}" \
        || ! cp "$helper_src" "${project_path}/${helper_rel}"; then
        print_error "db_import_with_replace: failed to stage files in ${work_dir}" >&2
        rm -f "${project_path}/${in_rel}" "${project_path}/${out_rel}" "${project_path}/${helper_rel}"
        return 1
    fi

    print_info "URL replacs: $old_url -> $new_url (byte-length aware)"

    # Replace EXCLUSIVELY inside DDEV container: identical PHP engine
    # on macOS/Linux, no host sed involved at all.
    local replace_output="" replace_rc=0
    replace_output=$(
        cd "$project_path" || exit 1
        ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" \
            "$helper_rel" "--old=${old_url}" "--new=${new_url}" \
            "--in=${in_rel}" "--out=${out_rel}" 2>&1
    ) || replace_rc=$?

    echo "[DEBUG] serialization-safe replace: rc=$replace_rc ${replace_output:-(no output)}" \
        >> "${project_path}/.dpx/debug.log" 2>/dev/null

    if [[ $replace_rc -ne 0 || ! -s "${project_path}/${out_rel}" ]]; then
        print_error "db_import_with_replace: serialization-safe replace FAILED inside container (rc=$replace_rc)." >&2
        print_error "Import aborted — database was NOT touched. Details: ${project_path}/.dpx/debug.log" >&2
        rm -f "${project_path}/${in_rel}" "${project_path}/${out_rel}" "${project_path}/${helper_rel}"
        return 1
    fi

    if db_import "${project_path}/${out_rel}" "$project_path"; then
        rm -f "${project_path}/${in_rel}" "${project_path}/${out_rel}" "${project_path}/${helper_rel}"
        return 0
    else
        rm -f "${project_path}/${in_rel}" "${project_path}/${out_rel}" "${project_path}/${helper_rel}"
        return 1
    fi
}

# =================================================================
# CLEAR CACHE — Nuclear flush cache WordPress (v1.4.25)
#
# Delegates specific cleanup plugins/then in cms_flush_advanced_caches()
# (Plugin Engine: lib/cms/wp-handlers/*.sh).
# Here remains only basic WP-cleanup and file cache.
#
# [ISSUE 1] Protective fuse: function page WordPress-specific.
# For non-WP projects — no-op with clear message (no way wp-cli).
# =================================================================

db_wp_clear_cache() {
    local project_path="$1"

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then return 1; fi

    # [ISSUE 1] Defense-in-depth: non-WP project -> skip WP-routine
    local detected_cms
    detected_cms=$(detect_cms_type "$project_path" 2>/dev/null || echo "unknown")
    if [[ "$detected_cms" != "$CMS_TYPE_WORDPRESS" ]]; then
        print_info "Project not is WordPress ($(get_cms_name "$detected_cms")) — cleanup cache WP skipped." >&2
        return 0
    fi

    # Delegate cleanup specific cache (Elementor, Flatsome and t.d.) in CMS-module
    cms_flush_advanced_caches "$project_path" "wordpress"

    # WP-CLI: transients + Redis flush
    # Note: wp cache flush already performs internals cms_flush_advanced_caches()
    print_step "auto" "Delete transients and cleanup Redis..." >&2
    (
        cd "$project_path" || exit 1
        ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" /usr/local/bin/wp transient delete --all --quiet --allow-root >/dev/null 2>&1
        ddev redis-cli flushall >/dev/null 2>&1
    ) || true

    # Nuclear cleanup static file cache
    print_step "auto" "Cleanup file cache WordPress..." >&2
    (
        cd "$project_path" || exit 1
        ddev exec rm -rf /var/www/html/wp-content/cache/* 2>/dev/null
        ddev exec rm -rf /var/www/html/wp-content/wphb-cache/* 2>/dev/null
    ) || true
}

# =================================================================
# POST-IMPORT DISPATCHER BY TYPE CMS (v1.4.26) [ISSUE 1]
#
# Single point post-processing after import/restore database.
# WordPress-routine invokes ONLY for wordpress; for remaining
# types — with action and clear message.
#
# ARGUMENTS:
#   $1 — project_path
#   $2 — cms_type (wordpress|joomla|opencart|php)
# =================================================================

db_post_import_cms() {
    local project_path="$1"
    local cms_type="${2:-}"

    # Type not passed — determin by structure files project
    if [[ -z "$cms_type" ]]; then
        cms_type=$(detect_cms_type "$project_path" 2>/dev/null || echo "$CMS_TYPE_PHP")
    fi

    case "$cms_type" in
        "$CMS_TYPE_WORDPRESS")
            print_info "Project WordPress: check availabilities and cleanup cache..." >&2
            (
                cd "$project_path" || exit 1
                if ddev exec wp core is-installed >/dev/null 2>&1; then
                    print_success "WordPress accessible."
                    db_wp_clear_cache "$project_path"
                else
                    print_warning "WordPress unavailable (wp core is-installed returned error)."
                    print_info   "Verify wp-config.php and status container: ddev describe"
                fi
            ) >&2
            ;;
        "$CMS_TYPE_JOOMLA")
            print_info "Project Joomla: cleanup cache Joomla (cache/, administrator/cache/)..." >&2
            (
                cd "$project_path" || exit 1
                find cache administrator/cache -mindepth 1 ! -name 'index.html' -delete 2>/dev/null
            ) >&2
            print_success "Joomla: cache flushed. Verify configuration.php durings problems connected to database."
            ;;
        "$CMS_TYPE_OPENCART")
            print_info "Project OpenCart: cleanup system/storage/cache and modification..." >&2
            (
                cd "$project_path" || exit 1
                find system/storage/cache system/storage/modification -mindepth 1 ! -name 'index.html' -delete 2>/dev/null
            ) >&2
            print_success "OpenCart: cache modification flushed. Update then in admin panel durings necessities."
            ;;
        *)
            print_info "Type project: $(get_cms_name "$cms_type") — post-processing cache not requires." >&2
            ;;
    esac
}

# =================================================================
# SNAPSHOT MANAGEMENT (v1.4.18)
# Death paranoids: trust DDEV exit code, not searching files physicals.
# =================================================================

db_create_snapshot() {
    local project_path="$1"
    local tag="${2:-dpx_tunnel}"

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then
        print_error "db_create_snapshot: director project not specified." >&2
        return 1
    fi

    local snapshot_name="${tag}_$(date +%H%M%S)"
    print_step "auto" "Safety Snapshot: $snapshot_name..." >&2

    # Create snapshot, suppress interactive.
    # IMPORTANT: Ifs $? == 0, means DDEV guarantees, that snapshot consumes.
    dpx_exec_and_log "$project_path" ddev snapshot --name="$snapshot_name" --yes >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        print_success "Snapshot create: $snapshot_name" >&2
        echo "$snapshot_name" # Return name for caller'and
        return 0
    else
        print_error "CRITICAL: Snapshot creation failed! Mutation database BLOCKED." >&2
        return 1
    fi
}

# Restores database from ddev snapshot.
# All UI → stderr. Nothing not returns via stdout.
#
# ARGUMENTS:
#   $1 — project_path
#   $2 — snapshot_name
db_restore_snapshot() {
    local project_path="$1"
    local snapshot_name="$2"

    if [[ -z "$project_path" ]]; then
        print_error "db_restore_snapshot: director project not specified."
        return 1
    fi

    if [[ -z "$snapshot_name" ]]; then
        print_error "db_restore_snapshot: name snapshot not specified."
        return 1
    fi

    print_step "auto" "Restore database from snapshot: $snapshot_name..."
    (
        cd "$project_path" || exit 1
        ddev snapshot restore "$snapshot_name" 2>/dev/null
    ) >&2
    local restore_result=$?

    if [[ $restore_result -eq 0 ]]; then
        print_success "database restore from snapshot: $snapshot_name"
        return 0
    else
        print_error "Not remove restore snapshot: $snapshot_name"
        print_error "Execute manual: ddev snapshot restore $snapshot_name"
        return 1
    fi
}

# =================================================================
# SMART REPLACE TUNNEL (v1.4.23) — Main engine migrations
#
# ARCHITECTURE:
#   - Snapshot creates OUTSIDE this functions (Atomicity sessions)
#   - db_prefix extracts VIA db_get_prefix() (SINGLE point)
#   - Validation ONLY via SQL (db_sql_get_option)
#   - Flatsome transients clean via SQL (without WP-CLI)
#   - WP-CLI uses ONLY for search-replace (serialization)
#
# v1.4.23 — THREES PASS: HTTPS -> HTTP -> Bare Domain
#   Reason: protocol-relative (//domain) NOT catches bare domains
#   in setups menu and builders (Flatsome, Elementor).
#
#   Correctly order (safe):
#     1. https://OLD → https://NEW  (exact HTTPS)
#     2. http://OLD  → https://NEW  (HTTP → HTTPS, tunnel always HTTPS)
#     3. OLD       → NEW          (bare domain — catches menu, builders)
#
#   First two pass clean out all occurrence with protocols,
#   third pass safe replaces all leftover without risk
#   create double protocols (https://https://...).
#
#   DEBUG: each pass prints result wp search-replace
#   (include count replace) in debug.log.
# =================================================================

db_smart_replace_tunnel() {
    local old_url="$1"
    local new_url="$2"
    local project_path="$3"

    if [[ -z "$old_url" || -z "$new_url" || -z "$project_path" ]]; then return 1; fi
    if [[ "$old_url" == "$new_url" ]]; then return 0; fi

    # Single point extract prefix
    local db_prefix
    db_prefix=$(db_get_prefix "$project_path") || {
        print_error "Not remove extract db_prefix. Stop!" >&2
        return 1
    }

    local snapshot_name
    snapshot_name=$(db_create_snapshot "$project_path")
    local snap_rc=$?

    if [[ $snap_rc -ne 0 || -z "$snapshot_name" ]]; then
        print_error "Not remove create Safety Snapshot. Stop!" >&2
        return 1
    fi

    echo "" >&2
    print_info "${COLOR_BOLD}${COLOR_YELLOW}[WAIT]${COLOR_RESET} Deep migration database (--precise). This take time..." >&2

    # Extract bare domains for built exact pass
    local old_bare
    old_bare=$(echo "$old_url" | sed 's|https\?://||;s|/$||')
    local new_bare
    new_bare=$(echo "$new_url" | sed 's|https\?://||;s|/$||')

    local replace_rc=0
    local replace_output=""

    # ==================================================================
    # PASS 1: HTTPS exact
    # https://grandmebel.lo → https://cloudflare...
    # ==================================================================
    print_step "auto" "[1/3] Replace HTTPS: $old_url -> $new_url" >&2
    replace_output=$(
        cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" \
        /usr/local/bin/wp search-replace "$old_url" "$new_url" \
        --all-tables --precise --skip-plugins --skip-themes --allow-root \
        2>/dev/null
    )
    replace_rc=$?
    # Log result (even ifs empty)
    echo "[DEBUG] Pass 1 (HTTPS): rc=$replace_rc output=${replace_output:-'(empty)'}" >> "${project_path}/.dpx/debug.log" 2>/dev/null
    if [[ -n "$replace_output" ]]; then
        print_info "  → $replace_output" >&2
    fi

    if [[ $replace_rc -ne 0 ]]; then
        print_error "Error replaces HTTPS (pass 1)." >&2
        [[ -n "$snapshot_name" ]] && db_restore_snapshot "$project_path" "$snapshot_name"
        return 1
    fi

    sleep 1; sync 2>/dev/null || true

    # ==================================================================
    # PASS 2: HTTP → HTTPS
    # http://grandmebel.lo → https://cloudflare...
    # Tunnel always HTTPS, therefore HTTP-links convert.
    # ==================================================================
    local old_http="http://${old_bare}"
    # Only ifs old_url was HTTPS (standard case DDEV)
    if [[ "$old_url" == https://* && -n "$old_bare" ]]; then
        print_step "auto" "[2/3] Replace HTTP→HTTPS: $old_http -> $new_url" >&2
        replace_output=$(
            cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" \
            /usr/local/bin/wp search-replace "$old_http" "$new_url" \
            --all-tables --precise --skip-plugins --skip-themes --allow-root \
            2>/dev/null
        )
        replace_rc=$?
        echo "[DEBUG] Pass 2 (HTTP): rc=$replace_rc output=${replace_output:-'(empty)'}" >> "${project_path}/.dpx/debug.log" 2>/dev/null
        if [[ -n "$replace_output" ]]; then
            print_info "  → $replace_output" >&2
        fi
        sleep 1; sync 2>/dev/null || true
    else
        print_info "[2/3] Skipped (old_url not HTTPS)" >&2
    fi

    # ==================================================================
    # PASS 3: Bare domain (without protocol)
    # Catches menu, setups builders and serialized arraies
    # ==================================================================
    if [[ -n "$old_bare" && "$old_bare" != "$new_bare" ]]; then
        print_step "auto" "[3/3] Replace bare domain: $old_bare -> $new_bare" >&2
        replace_output=$(
            cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" \
            /usr/local/bin/wp search-replace "$old_bare" "$new_bare" \
            --all-tables --precise --skip-plugins --skip-themes --allow-root \
            2>/dev/null
        )
        replace_rc=$?
        echo "[DEBUG] Pass 3 (Bare): rc=$replace_rc output=${replace_output:-'(empty)'}" >> "${project_path}/.dpx/debug.log" 2>/dev/null
        if [[ -n "$replace_output" ]]; then
            print_info "  → $replace_output" >&2
        fi
        sleep 1; sync 2>/dev/null || true
    fi

    # Clean cache BEFORE validation (Flatsome via SQL, remaining via WP-CLI)
    db_wp_clear_cache "$project_path"

    # ==================================================================
    # DIAGNOSTICS: count remaining old URL (debug)
    # ==================================================================
    local remaining=0
    remaining=$(db_sql_count_old_url "$project_path" "$old_bare")
    echo "[DEBUG] Remaining old_url ('$old_bare') in DB: $remaining" >> "${project_path}/.dpx/debug.log" 2>/dev/null
    if (( remaining > 0 )); then
        print_warning "Diagnostics: in database remaining $remaining occurrence old URL (details in .dpx/debug.log)" >&2
    fi

    # PAGE SQL VALIDATION — no way WP-CLI!
    print_info "Validation: direct SQL-request to database (ddev mysql)..." >&2

    local actual_url="" attempt=0
    while (( attempt < 3 )); do
        actual_url=$(db_sql_get_option "$project_path" "home") || actual_url=""

        if [[ -n "$actual_url" && "$actual_url" == *"$new_bare"* ]]; then
            print_success "Validation OK: SQL home = $actual_url" >&2
            break
        fi

        ((attempt++))
        if (( attempt < 3 )); then
            print_warning "database in process records (attempt $attempt/3). Waiting 2 sec..." >&2
            sleep 2; sync 2>/dev/null || true
        fi
    done

    # FAIL-SAFE: FATAL STOP
    if [[ "$actual_url" != *"$new_bare"* ]]; then
        print_error "FATAL ERROR: SQL-validation fail!" >&2
        print_error "Expected: *$new_bare*, received from database: $actual_url" >&2
        print_error "SQL: SELECT option_value FROM ${db_prefix}options WHERE option_name='home';" >&2
        [[ -n "$snapshot_name" ]] && db_restore_snapshot "$project_path" "$snapshot_name"
        return 1
    fi

    echo "$snapshot_name"
}

# =================================================================
# SMART REPLACE — General migration URL (v1.4.23)
#
# Universal function for export on production and manual
# migrations. Not includes cleanup cache (caller solves).
# WP-CLI with PHP-isolation for search-replace.
#
# v1.4.23: Threes pass — HTTPS -> HTTP -> Bare Domain.
# =================================================================

db_wp_smart_replace() {
    local old_url="$1"
    local new_url="$2"
    local project_path="$3"

    if [[ -z "$old_url" || -z "$new_url" || -z "$project_path" ]]; then
        print_error "db_wp_smart_replace: not specifieds arguments (old_url new_url project_path)."
        return 1
    fi

    if [[ ! -d "$project_path" ]]; then
        print_error "db_wp_smart_replace: director project not found: $project_path"
        return 1
    fi

    if [[ "$old_url" == "$new_url" ]]; then
        print_info "old_url and new_url match ($old_url). Replace skipped."
        return 0
    fi

    # Safety Snapshot
    local snapshot_name="pre_replace_$(date +%s)"
    print_step "auto" "Safety Snapshot: $snapshot_name..."
    (
        cd "$project_path" || exit 1
        ddev snapshot --name="$snapshot_name" --yes >/dev/null 2>&1
    )
    if [[ $? -eq 0 ]]; then
        print_success "Safety Snapshot create: $snapshot_name"
    else
        print_warning "Not remove create snapshot. Continue without insurances."
    fi

    # Warning
    print_info "Attention: deep replace (--precise) on big bases may busy until 1 minutes."

    # Extract bare domains for three exact pass
    local old_bare_domain
    old_bare_domain=$(echo "$old_url" | sed 's|https\?://||;s|/$||')
    local new_bare_domain
    new_bare_domain=$(echo "$new_url" | sed 's|https\?://||;s|/$||')

    # Pass 1: HTTPS exact
    print_step "auto" "[1/3] Replace HTTPS: $old_url -> $new_url"
    (
        cd "$project_path" || exit 1
        ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" /usr/local/bin/wp search-replace \
            "$old_url" "$new_url" \
            --all-tables --precise --skip-plugins --skip-themes --allow-root 2>/dev/null
    )
    if [[ $? -ne 0 ]]; then
        print_error "Error replaces full URL."
        return 1
    fi

    # Pass 2: HTTP → HTTPS
    if [[ "$old_url" == https://* && -n "$old_bare_domain" ]]; then
        print_step "auto" "[2/3] Replace HTTP→HTTPS: http://${old_bare_domain} -> $new_url"
        (
            cd "$project_path" || exit 1
            ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" /usr/local/bin/wp search-replace \
                "http://${old_bare_domain}" "$new_url" \
                --all-tables --precise --skip-plugins --skip-themes --allow-root 2>/dev/null
        ) || print_warning "Replace HTTP→HTTPS completion with error."
    fi

    # Pass 3: Bare domain
    if [[ -n "$old_bare_domain" ]]; then
        print_step "auto" "[3/3] Replace bare domain: ${old_bare_domain} -> ${new_bare_domain}"
        (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" /usr/local/bin/wp search-replace "${old_bare_domain}" "${new_bare_domain}" --all-tables --precise --skip-plugins --skip-themes --allow-root 2>/dev/null) || true
    fi

    print_success "Triple replace URL completion."
    return 0
}

# =================================================================
# WP-CLI EXPORT With SAFE REPLACE (v1.4.21)
#
# Uses db_wp_smart_replace (--precise + triple-pass).
# =================================================================

db_wp_export_safe() {
    local output_file="$1"
    local local_url="$2"
    local prod_url="$3"
    local project_path="$4"

    [[ -n "$project_path" ]] && cd "$project_path" || return 1

    print_step "auto" "Export with replace URL for production..."

    if ! db_wp_smart_replace "$local_url" "$prod_url" "$project_path"; then
        print_error "Not remove execute replace URL before export."
        return 1
    fi

    db_wp_clear_cache "$project_path"

    if ddev export-db --file="$output_file" >/dev/null 2>&1; then
        print_success "Base export: $(basename "$output_file")"

        if ! db_wp_smart_replace "$prod_url" "$local_url" "$project_path"; then
            print_error "CRITICAL ERROR: not remove back URL reverse!"
            print_error "Execute manual: ddev snapshot restore <name_snapshot>"
            return 1
        fi

        db_wp_clear_cache "$project_path"
        print_info "URL in local base restors."
        return 0
    else
        print_error "Error export bases."
        print_warning "Attempt restore URL after errors export..."
        db_wp_smart_replace "$prod_url" "$local_url" "$project_path" || true
        db_wp_clear_cache "$project_path" 2>/dev/null || true
        return 1
    fi
}

# =================================================================
# HELPER
# =================================================================

db_get_prod_filepath() {
    local filename="$1"
    local base_path=$(get_db_prod_path)
    echo "${base_path}/${filename}.sql"
}

db_generate_export_filename() {
    local project_name="$1"
    local suffix="${2:-FROM_LOCAL}"
    local tag=$(echo "$suffix" | tr '[:lower:]' '[:upper:]')
    local ts=$(date +"%y%m%d_%H%M")
    echo "${project_name}_${tag}_${ts}.sql"
}

# =================================================================
# EXPORT FUNCTION
# =================================================================

export -f get_db_prod_path get_db_local_path db_import db_export
export -f db_backup_local db_import_with_replace db_wp_export_safe
export -f db_wp_smart_replace db_wp_clear_cache db_post_import_cms
export -f db_create_snapshot db_restore_snapshot db_smart_replace_tunnel
export -f db_get_prod_filepath db_generate_export_filename
export -f db_validate_identifier db_escape_sql_literal db_get_prefix db_sql_get_option db_sql_delete_transients
export -f db_sql_count_old_url db_get_db_name
