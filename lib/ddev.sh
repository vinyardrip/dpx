#!/usr/bin/env bash
# =================================================================
# DPX Library: ddev - Toolkit management DDEV
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_DDEV_LOADED:-}" ]] && return 0
readonly _DPX_DDEV_LOADED=1

# =================================================================
# CHECK STATUS PROJECTS
# =================================================================

# Check whether a specific project is running
# [FIX] DDEV 1.25+ prints tables with frames (│), that breaks awk '{print $1}'
# Use grep with regular expression for search nameds project
ddev_is_project_running() {
    local name="$1"
    # Searching name project, ignore frames table DDEV 1.25+ (│) and asterisks (*)
    ddev list --active-only 2>/dev/null | grep -qE "(^|[^a-zA-Z0-9_-])${name}([^a-zA-Z0-9_-]|$)"
}

# Check existence project in DDEV
ddev_project_exists() {
    local project_name="$1"
    ddev describe "$project_name" >/dev/null 2>&1
}

# =================================================================
# MANAGEMENT PROJECTS
# =================================================================

# Safe start project (with check paths)
# Important: cd in subshell, so that not "leak" in other director
safe_start_ddev_project() {
    dpx_debug_trace "ddev.call" "command=start" "project=$1" "path=$2"
    local name="$1"
    local path="$2"

    print_info "Start project $name..."
    (
        cd "$path" >/dev/null 2>&1 || exit 1
        ddev start
    ) || return 1
}

# Start project DDEV
ddev_start_project() {
    dpx_debug_trace "ddev.call" "command=start" "project=$1" "path=$2"
    local project_name="$1"
    local project_path="$2"

    print_info "Start DDEV project: $project_name"
    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        ddev start
    ) || return 1
}

# Stop project DDEV
ddev_stop_project() {
    dpx_debug_trace "ddev.call" "command=stop" "project=$1"
    local project_name="$1"

    print_info "Stop DDEV project: $project_name"
    ddev stop "$project_name" 2>&1
}

# Delete project DDEV
ddev_delete_project() {
    dpx_debug_trace "ddev.call" "command=delete" "project=$1"
    local project_name="$1"

    print_warning "Delete DDEV project: $project_name"
    ddev delete "$project_name" -y 2>&1
}

# Open project in browser
ddev_launch() {
    local project_name="$1"
    print_info "Open in browser..."
    ddev launch "$project_name" 2>/dev/null </dev/null &
}

# =================================================================
# SOFT RESTART (Issue: MySQL locks & buffer errors on hot imports)
#
# Non-blocking restart containers project before heavy operation
# with database: resets connection and state InnoDB/max_allowed_packet
# without interactive confirmation.
#
# Compatibility DDEV:
#   - First probe form from DPX-workflow: ddev restart --name=...
#   - Old/new versions DDEV without flag --name -> fallback
#     "ddev restart <project>" (positional argument works in all
#     version and not requires cd).
# =================================================================

ddev_soft_restart() {
    dpx_debug_trace "ddev.call" "command=restart" "project=$1" "path=$2"
    local project_name="$1"

    if [[ -z "$project_name" ]]; then
        print_error "ddev_soft_restart: name project not specified."
        return 1
    fi

    # Form by specifications DPX (may not support version DDEV)
    if ddev restart "--name=${project_name}" >/dev/null 2>&1; then
        return 0
    fi

    # Universal fallback: positional name project
    ddev restart "$project_name" >/dev/null 2>&1
}

# Import dump in database project.
#
# Single wrapper over ddev import-db:
#   1) Form from DPX-workflow: ddev import-db --name=... --src=...
#   2) Fallback (guaranteed compatible): cd in project +
#      ddev import-db --file=... (pattern always code DPX).
#
# ARGUMENTS:
#   $1 — project_name (for form with --name)
#   $2 — project_path (for fallback cd)
#   $3 — path to dump (.sql / .sql.gz)
ddev_import_db() {
    dpx_debug_trace "ddev.call" "command=import-db" "project=$1" "path=$2"
    local project_name="$1"
    local project_path="$2"
    local db_file="$3"

    validate_file "$db_file" "Database dump" || return 1

    # Specification DPX: --name + --src
    if ddev import-db \
        "--name=${project_name}" \
        "--src=${db_file}" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback: classic path via cd (isolation in subshell)
    (
        cd "$project_path" 2>/dev/null || exit 1
        ddev import-db "--file=${db_file}"
    ) >/dev/null 2>&1
}

# =================================================================
# CONFIGURATION
# =================================================================

# Get current version PHP from config project
ddev_get_php_version() {
    local project_path="$1"
    local config_file="${project_path}/.ddev/config.yaml"

    if [[ -f "$config_file" ]]; then
        grep -E "^php_version:" "$config_file" | awk '{print $2}' | tr -d '"' | tr -d "'"
    else
        echo "unknown"
    fi
}

# Setup DDEV project
ddev_configure_project() {
    local project_name="$1"
    local project_type="$2"
    local php_version="$3"
    local db_type="$4"
    local db_version="$5"
    local docroot="${6:-}"
    local project_tld="${7:-lo}"

    print_step "auto" "Configuration DDEV..."

    ddev config --project-name "$project_name" \
        --project-type "$project_type" \
        --php-version "$php_version" \
        --database "${db_type}:${db_version}" \
        --docroot "$docroot" \
        --webserver-type apache-fpm \
        --project-tld "$project_tld" 2>&1
}

# =================================================================
# WP-CLI COMMANDS
# =================================================================

# WP-CLI install WordPress
ddev_wp_install() {
    local project_path="$1"
    local site_url="$2"
    local site_title="$3"
    local admin_user="$4"
    local admin_pass="$5"
    local admin_email="$6"
    local locale="${7:-ru_RU}"

    print_step "3" "Install WordPress via WP-CLI"

    # Weight code in subshell for isolations cd
    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1

        # Download WordPress
        print_info "Download WordPress ($locale)..."
        ddev wp core download --locale="$locale" 2>&1 || {
            print_error "Error downloads WordPress"
            exit 1
        }

        # Create wp-config.php
        print_info "Create wp-config.php..."
        ddev wp config create --dbname=db --dbuser=db --dbpass=db --dbhost=db 2>&1 || {
            print_error "Error create wp-config.php"
            exit 1
        }

        # Install WordPress
        print_info "Install WordPress..."
        ddev wp core install \
            --url="$site_url" \
            --title="$site_title" \
            --admin_user="$admin_user" \
            --admin_password="$admin_pass" \
            --admin_email="$admin_email" 2>&1 || {
            print_error "Error installs WordPress"
            exit 1
        }

        print_success "WordPress success installed."
    ) || return 1
}

# WP-CLI search-replace
ddev_wp_search_replace() {
    local old_url="$1"
    local new_url="$2"
    local project_path="$3"

    print_info "Replace URL: $old_url -> $new_url"
    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        ddev exec wp search-replace "$old_url" "$new_url" --all-tables --allow-root 2>&1
    ) || return 1
}

# WP-CLI delete then
ddev_wp_theme_delete() {
    local themes="$1"
    local project_path="$2"

    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        for theme in $themes; do
            ddev wp theme delete "$theme" 2>/dev/null || true
        done
    )
}

# WP-CLI delete plugins
ddev_wp_plugin_delete() {
    local plugins="$1"
    local project_path="$2"

    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        for plugin in $plugins; do
            ddev wp plugin delete "$plugin" 2>/dev/null || true
        done
    )
}

# =================================================================
# ROUTER TLS HEALTH PROBE & AUTO-RECOVERY (v1.7.0)
#
# `ddev-router` frequently drops or misplaces TLS certificates for
# long-running containers, producing NET::ERR_CERT_COMMON_NAME_INVALID
# in browsers. This module offers a non-blocking probe and a focused
# `ddev restart` recovery path so the dpx start wrapper can refresh
# stale bindings without bothering the user.
#
# The probe is a strict-TLS HEAD request against the project's primary
# URL with a 1.5s cap. The strict (no -k) handshake is deliberate:
#  - exit 0  -> HTTPS endpoint answered over a valid cert chain
#  - exit 35/51/60 -> TLS / cert hostname mismatch -> "degraded"
#  - exit 7/28/6/... -> connection failure / timeout / DNS -> "unreachable"
# =================================================================

# Returns one of: running | degraded | unreachable.
# $1 - project_name (required)
# $2 - project_path (optional; used to resolve the primary URL via
#       `ddev describe -j` for projects with custom domains)
ddev_check_http_health() {
    local project_name="$1"
    local project_path="${2:-}"

    if [[ -z "$project_name" ]]; then
        echo "unreachable"
        return 0
    fi

    local healthcheck_timeout="${DPX_HEALTHCHECK_TIMEOUT:-1.5}"
    local project_tld
    project_tld=$(get_config "project_tld" "lo" 2>/dev/null || echo "lo")
    local url="https://${project_name}.${project_tld}"

    # Prefer the real primary URL DDEV knows about (custom domains).
    if [[ -n "$project_path" ]] && command -v ddev >/dev/null 2>&1; then
        local detected
        detected=$(cd "$project_path" 2>/dev/null && ddev describe "$project_name" -j 2>/dev/null \
            | (command -v jq >/dev/null 2>&1 && jq -r '.raw.primary_url // empty' || cat) \
            2>/dev/null)
        # Extract https URL from the JSON blob (jq absent fallback).
        if [[ "$detected" == http* ]]; then
            url="$detected"
        fi
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "running"
        return 0
    fi

    # Strict-TLS HEAD: any valid response (even HTTP 4xx/5xx) is "running".
    curl -sI --max-time "$healthcheck_timeout" "$url" >/dev/null 2>&1
    local rc=$?
    case "$rc" in
        0)        echo "running" ;;
        35|51|60) echo "degraded" ;;
        *)        echo "unreachable" ;;
    esac
}

# When a project is already in `running` state but the local probe
# reports a degraded/unreachable HTTPS endpoint, force `ddev restart`
# so ddev-router re-issues / rebinds the correct TLS certificate.
# Caller-supplied args: $1=project_name  $2=project_path (cd context).
# Returns 0 on success, non-zero if restart fails.
ddev_auto_recover_router() {
    local project_name="$1"
    local project_path="$2"

    print_info "$(t ddev.router.desync.info)"

    dpx_debug_trace "ddev.call" "command=restart" "project=$project_name" "reason=stale_router_ssl"

    if [[ -n "$project_path" ]]; then
        (
            cd "$project_path" 2>/dev/null || exit 1
            ddev restart
        )
    else
        ddev restart "$project_name"
    fi
}

# Probe an already-running project; if the ddev-router is desynced,
# recover automatically. Returns 0 when the project is reachable
# (or has been successfully recovered) and 1 when recovery failed.
ddev_probe_and_recover_if_running() {
    local project_name="$1"
    local project_path="$2"

    if [[ -z "$project_name" ]]; then
        return 0
    fi

    # Only relevant when the project is already in `running` state
    # (ddev start would otherwise be a no-op and the browser would
    # keep hitting the stale router cert).
    if ! ddev_is_project_running "$project_name"; then
        return 0
    fi

    local health
    health=$(ddev_check_http_health "$project_name" "$project_path")

    case "$health" in
        running)
            return 0
            ;;
        degraded|unreachable)
            ddev_auto_recover_router "$project_name" "$project_path"
            return $?
            ;;
        *)
            return 0
            ;;
    esac
}
