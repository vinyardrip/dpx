#!/usr/bin/env bash
# =================================================================
# DPX Command: tunnel - forwarding tunnel for show project client
# Providers: cloudflared (Cloudflare Tunnel), ngrok — both fully working
# Architecture: DPX_SMART_TUNNEL — self-activating block
# Version: v1.6.0 — ngrok provider (API-driven URL extraction + fallback parsers)
# =================================================================

# Connect modules
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"

# =================================================================
# CONSTANTS
# =================================================================

readonly TUNNEL_MARKER_START="/** DPX_SMART_TUNNEL */"
readonly TUNNEL_MARKER_END="/** END_DPX_SMART_TUNNEL */"
readonly TUNNEL_PROVIDER_CLOUDFLARE="cloudflare"
readonly TUNNEL_PROVIDER_NGROK="ngrok"
readonly WP_CONFIG_PROTECTED_TAIL=10

# =================================================================
# NGROK DRIVER — CONFIGURABLE PARAMETERS (v1.6.0)
#
# TUNNEL_NGROK_API_PORT     port local ngrok API (inspect);
#                           overrides via DPX_NGROK_API_PORT;
#                           durings given values in command adds
#                           --web-addr (supports ngrok v3).
# TUNNEL_NGROK_MAX_WAIT     budget expect public URL, seconds;
#                           DPX_NGROK_MAX_WAIT.
# TUNNEL_NGROK_POLL_INTERVAL interval polling API, seconds; DPX_NGROK_POLL_INTERVAL.
#
# Variable NOT readonly intentional: tests substitute interval,
# so that not wait full timeout.
# =================================================================

TUNNEL_NGROK_API_PORT="${DPX_NGROK_API_PORT:-4040}"
TUNNEL_NGROK_MAX_WAIT="${DPX_NGROK_MAX_WAIT:-10}"
TUNNEL_NGROK_POLL_INTERVAL="${DPX_NGROK_POLL_INTERVAL:-0.5}"

# =================================================================
# CROSS-PLATFORM PATH NORMALIZATION (v1.4.11)
# =================================================================

_dpx_realpath() {
    local target="$1"
    if [[ -z "$target" ]]; then echo ""; return 0; fi
    if command -v realpath >/dev/null 2>&1; then
        realpath -- "$target" 2>/dev/null
    elif command -v greadlink >/dev/null 2>&1; then
        greadlink -f -- "$target" 2>/dev/null
    elif command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
        readlink -f -- "$target" 2>/dev/null
    else
        echo "$target"
    fi
}

# =================================================================
# HELP
# =================================================================

show_tunnel_help() {
    cat << EOF
 ${COLOR_BOLD}tunnel${COLOR_RESET} - Forwarding tunnel for show project client

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} tunnel [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Creates public tunnel to local DDEV-project.
    For WordPress automatics:
      - Injects DPX_SMART_TUNNEL block in wp-config.php
      - Applies Nginx Hot-Patch for disabled absolute redirects.
      - Replaces URL in database via wp search-replace.
    Durings completions (Ctrl+C) performs full rollback:
    restore wp-config.php from snapshot (mv -f), return URL in database, rollback Nginx.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project DDEV
    --cms-type TYPE        Type CMS (wordpress, joomla, opencart, php)
    --provider PROVIDER    Provider tunnel: cloudflare | ngrok (both working)
    -y, --yes              Skipp confirmation
    -h, --help             Show this help
EOF
}

# =================================================================
# LEVEL 0: WP-CLI EXECUTOR
# =================================================================

tunnel_wp_exec() {
    local project_path="$1"
    shift

    local wp_cmd="php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp"
    local arg
    for arg in "$@"; do
        local escaped_arg="${arg//\'/\'\\\'\'}"
        wp_cmd+=" '${escaped_arg}'"
    done

    (
        cd "$project_path" || exit 1
        ddev exec "$wp_cmd" 2>/dev/null
    )
}

# =================================================================
# LEVEL 1: PROVIDERS TUNNEL
# =================================================================

tunnel_detect_providers() {
    local -a available=()
    if command -v cloudflared >/dev/null 2>&1; then
        available+=("$TUNNEL_PROVIDER_CLOUDFLARE")
    fi
    if command -v ngrok >/dev/null 2>&1; then
        available+=("$TUNNEL_PROVIDER_NGROK")
    fi
    printf '%s\n' "${available[@]}"
}

tunnel_select_provider() {
    local preferred="${1:-}"
    if [[ -n "$preferred" ]]; then
        echo "$preferred"
        return 0
    fi

    local providers
    providers=$(tunnel_detect_providers)
    local count
    count=$(echo "$providers" | wc -l)
    count="${count// /}"

    if (( count == 0 )); then
        return 1
    elif (( count == 1 )); then
        echo "$providers" | head -1
        return 0
    else
        print_header "Select provider tunnel"
        local i=1
        while IFS= read -r prov; do
            echo "  $i. $prov" >&2
            ((i++))
        done <<< "$providers"
        local choice
        read -r -p "Select [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            echo "$providers" | sed -n "${choice}p"
            return 0
        else
            return 1
        fi
    fi
}

tunnel_cloudflare_check() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        print_error "cloudflared not found."
        print_info "Install: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        return 1
    fi
    print_success "cloudflared found: $(cloudflared --version 2>&1 | head -1)"
    return 0
}

tunnel_cloudflare_start() {
    local target_url="$1"
    local log_file="$2"
    local host_header="${3:-}"

    local -a cf_cmd=(cloudflared tunnel --url "$target_url")

    # Before Host-header for Traefik.
    if [[ -n "$host_header" ]]; then
        cf_cmd+=(--http-host-header "$host_header")
    fi

    "${cf_cmd[@]}" > "$log_file" 2>&1 &
    local pid=$!

    print_info "cloudflared run (PID: $pid)..."
    print_info "Expect URL tunnel..."

    local tunnel_url=""
    local max_wait=30
    local waited=0

    while (( waited < max_wait )); do
        if [[ -f "$log_file" ]]; then
            tunnel_url=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1)
            if [[ -n "$tunnel_url" ]]; then break; fi
        fi
        sleep 1
        ((waited++))
        printf "." >&2
    done
    echo "" >&2

    if [[ -z "$tunnel_url" ]]; then
        print_error "Not remove get URL tunnel for ${max_wait} seconds."
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
        return 1
    fi

    _DPX_TUNNEL_PID="$pid"
    _DPX_TUNNEL_URL="$tunnel_url"
    print_success "Tunnel create: $tunnel_url"
    return 0
}

tunnel_cloudflare_stop() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_info "Stop cloudflared (PID: $pid)..."
        kill "$pid" 2>/dev/null
        local wait_count=0
        while kill -0 "$pid" 2>/dev/null && (( wait_count < 10 )); do
            sleep 0.5
            ((wait_count++))
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        print_success "cloudflared stopped."
    fi
}

# =================================================================
# NGROK DRIVER (v1.6.0)
#
# Contract identical cloudflare-driver:
#   start(target_url, log_file, host_header) -> _DPX_TUNNEL_PID/_DPX_TUNNEL_URL;
#   stop(pid) — TERM, grace, KILL.
#
# Public URL extracts from local API ngrok
# (http://127.0.0.1:<port>/api/tunnels) with chain parsers:
#   jq -> python3 -> grep/cut fallback.
# Selects ONLY https:// endpoint (specification DPX).
# =================================================================

# Parser JSON via jq: first https-endpoint from array tunnels.
_tunnel_ngrok_parse_jq() {
    local payload="$1"
    printf '%s' "$payload" | jq -r '[.tunnels[]? | select(.public_url? | startswith("https"))][0].public_url // empty' 2>/dev/null
}

# Parser JSON via python3 (fallback, when jq missing).
_tunnel_ngrok_parse_python() {
    local payload="$1"
    python3 - "$payload" 2>/dev/null << 'PYEOF'
import json, sys
try:
    data = json.loads(sys.argv[1])
    for t in data.get("tunnels", []):
        u = t.get("public_url", "")
        if isinstance(u, str) and u.startswith("https"):
            print(u)
            break
except Exception:
    pass
PYEOF
}

# Last line: grep+cut by raw JSON (without external dependency).
_tunnel_ngrok_parse_grep() {
    local payload="$1"
    printf '%s' "$payload" \
        | grep -oE '"public_url"[[:space:]]*:[[:space:]]*"https://[^"]+"' \
        | head -1 \
        | cut -d'"' -f4
}

# Dispatcher parsers by availabilities tools.
tunnel_ngrok_parse_api() {
    local payload="$1"
    if command -v jq >/dev/null 2>&1; then
        _tunnel_ngrok_parse_jq "$payload" && return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        _tunnel_ngrok_parse_python "$payload" && return 0
    fi
    _tunnel_ngrok_parse_grep "$payload"
}

# GET local inspect-API; empty output durings any error networks.
tunnel_ngrok_fetch_api() {
    curl -sf --max-time 2 "http://127.0.0.1:${TUNNEL_NGROK_API_PORT}/api/tunnels" 2>/dev/null || true
}

# Loop expect public URL with general budget TUNNEL_NGROK_MAX_WAIT.
# Early exit, ifs process ngrok died (error configurations/authtoken).
tunnel_ngrok_wait_public_url() {
    local deadline=$(( SECONDS + TUNNEL_NGROK_MAX_WAIT ))
    local payload url=""

    while (( SECONDS < deadline )); do
        if [[ -n "${_DPX_TUNNEL_PID:-}" ]] && ! kill -0 "${_DPX_TUNNEL_PID}" 2>/dev/null; then
            return 1
        fi

        payload="$(tunnel_ngrok_fetch_api)"
        if [[ -n "$payload" ]]; then
            url="$(tunnel_ngrok_parse_api "$payload")"
            if [[ -n "$url" ]]; then
                printf '%s\n' "$url"
                return 0
            fi
        fi

        printf '.' >&2
        sleep "$TUNNEL_NGROK_POLL_INTERVAL"
    done

    return 1
}

tunnel_ngrok_check() {
    if ! command -v ngrok >/dev/null 2>&1; then
        print_error "ngrok not found."
        print_info "Install:"
        print_info "  macOS:          brew install ngrok"
        print_info "  Ubuntu/Debian:  snap install ngrok  (ors .deb with ngrok.com/download)"
        print_info "  Arch:           yay -S ngrok"
        print_info "After installs authorize: ngrok config add-authtoken <TOKEN>"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl not found — ngrok-driver needed access to local API."
        return 1
    fi
    print_success "ngrok found: $(ngrok --version 2>&1 | head -1)"
    return 0
}

tunnel_ngrok_start() {
    local target_url="$1"
    local log_file="$2"
    local host_header="${3:-}"

    local -a cmd=(ngrok http)

    # DDEV-router routes by Host: without header requests
    # on multi-project machine land in default vhost.
    [[ -n "$host_header" ]] && cmd+=("--host-header=${host_header}")
    # Legacy option ngrok v2; v3 ignores regions via config.
    [[ -n "${DPX_NGROK_REGION:-}" ]] && cmd+=("--region=${DPX_NGROK_REGION}")
    # Pinned inspect-API can only on v3 (--web-addr); includes explicit.
    [[ -n "${DPX_NGROK_API_PORT:-}" ]] && cmd+=("--web-addr=127.0.0.1:${TUNNEL_NGROK_API_PORT}")

    cmd+=("$target_url")

    "${cmd[@]}" > "$log_file" 2>&1 &
    local pid=$!
    _DPX_TUNNEL_PID="$pid"

    print_info "ngrok run (PID: $pid); expect HTTPS URL (until ${TUNNEL_NGROK_MAX_WAIT} with)..."

    local tunnel_url=""
    tunnel_url=$(tunnel_ngrok_wait_public_url) || tunnel_url=""
    echo "" >&2

    if [[ -z "$tunnel_url" ]]; then
        if ! kill -0 "$pid" 2>/dev/null; then
            print_error "ngrok complete immediately after start. Last lines log:"
            tail -5 "$log_file" 2>/dev/null | sed 's/^/    /' >&2
            if grep -qiE 'ERR_NGROK_4018|authtoken' "$log_file" 2>/dev/null; then
                print_info "Requires authtoken: ngrok config add-authtoken <TOKEN>"
            fi
        else
            print_error "API ngrok not returned HTTPS URL for ${TUNNEL_NGROK_MAX_WAIT} with."
            kill "$pid" 2>/dev/null || true
        fi
        return 1
    fi

    _DPX_TUNNEL_URL="$tunnel_url"
    print_success "Tunnel create: $tunnel_url"
    return 0
}

tunnel_ngrok_stop() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_info "Stop ngrok (PID: $pid)..."
        kill "$pid" 2>/dev/null
        local wait_count=0
        while kill -0 "$pid" 2>/dev/null && (( wait_count < 10 )); do
            sleep 0.5
            ((wait_count++))
        done
        # Guarantee missing orphan-process
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        print_success "ngrok stopped."
    fi
}

tunnel_provider_check() {
    local provider="$1"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_check ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_check ;;
        *) print_error "Unknown provider: $provider"; return 1 ;;
    esac
}

tunnel_provider_start() {
    local provider="$1" target_url="$2" log_file="$3" host_header="$4"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_start "$target_url" "$log_file" "$host_header" ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_start "$target_url" "$log_file" "$host_header" ;;
        *) return 1 ;;
    esac
}

tunnel_provider_stop() {
    local provider="$1" pid="$2"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_stop "$pid" ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_stop "$pid" ;;
    esac
}

# =================================================================
# LEVEL 2: INFRASTRUCTURE — DDEV & WP
# =================================================================

tunnel_get_http_port() {
    local project_name="$1"

    local current_port
    current_port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.services.web.host_ports_mapping[]? | select(.exposed_port == "80" or .exposed_port == 80) | .host_port // empty' 2>/dev/null \
        | head -1)

    if [[ -n "$current_port" ]] && [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port > 0 )); then
        echo "$current_port"
        return 0
    fi

    current_port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.services.web.host_ports | .[] | select(contains("80")) | split(":")[-1] // empty' 2>/dev/null \
        | head -1)

    if [[ -n "$current_port" ]] && [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port > 0 )); then
        echo "$current_port"
        return 0
    fi

    current_port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.services.web.host_ports | split(",")[0] // empty' 2>/dev/null)

    if [[ -n "$current_port" ]] && [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port > 0 )); then
        echo "$current_port"
        return 0
    fi

    local port
    port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.httpURLs[0] // empty' 2>/dev/null \
        | grep -oE ':[0-9]+' | tr -d ':' | head -1)
    if [[ -n "$port" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.httpsURLs[0] // empty' 2>/dev/null \
        | grep -oE ':[0-9]+' | tr -d ':' | head -1)
    if [[ -n "$port" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    print_warning "Not remove determin host port. Fallback: 80"
    echo "80"
}

tunnel_get_local_domain() {
    local project_name="$1"
    local local_domain
    local_domain=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.primary_url // empty' 2>/dev/null \
        | sed 's|https://||;s|http://||')

    if [[ -z "$local_domain" ]]; then
        local project_tld
        project_tld=$(get_config "project_tld")
        local_domain="${project_name}.${project_tld}"
        print_warning "primary_url not received. Fallback: $local_domain"
    fi

    echo "$local_domain"
}

tunnel_get_target_url() {
    local project_name="$1"
    local project_url
    project_url=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.primary_endpoint // .raw.httpsURLs[0] // .raw.httpURLs[0] // empty' 2>/dev/null)
    if [[ -z "$project_url" ]]; then
        local project_tld
        project_tld=$(get_config "project_tld")
        project_url="https://${project_name}.${project_tld}"
        print_warning "URL from ddev describe not received. Fallback: $project_url"
    fi
    echo "$project_url"
}

# =================================================================
# LEVEL 2.1: PATCHING wp-config.php — DPX_SMART_TUNNEL
# =================================================================

# Generation DPX_SMART_TUNNEL block for wp-config.php.
#
# [FIX v1.5.7] HTTPS sets ONLY durings confirmed proxieds:
# Cloudflare/Traefik send X-Forwarded-Proto: https. Unconditional
# `$_SERVER['HTTPS'] = 'on'` caused redirect-loops on schemes, where
# header missing (direct HTTP-requests to container).
#
# STDOUT: PHP-block. Argument $1 — domain tunnel.
tunnel_smart_block_render() {
    local tunnel_domain="$1"
    cat <<BLOCK_EOF

/** DPX_SMART_TUNNEL */
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
    \$_SERVER['SERVER_PORT'] = 443;
}

// Force tunnel domain to bypass Traefik Host Header spoofing.
// This guarantees WP auth_redirect() uses the tunnel URL, not the .lo URL.
\$_SERVER['HTTP_HOST'] = '${tunnel_domain}';
\$_SERVER['SERVER_NAME'] = '${tunnel_domain}';

if (!defined('WP_HOME'))    define('WP_HOME', 'https://${tunnel_domain}');
if (!defined('WP_SITEURL')) define('WP_SITEURL', 'https://${tunnel_domain}');
/** END_DPX_SMART_TUNNEL */
BLOCK_EOF
}

tunnel_is_config_patched() {
    local config_file="$1"
    [[ -f "$config_file" ]] && grep -q "DPX_SMART_TUNNEL" "$config_file" 2>/dev/null
}

tunnel_has_old_markers() {
    local config_file="$1"
    [[ -f "$config_file" ]] && grep -qE "DPX_TUNNEL_FIX|DPX_TUNNEL_START|DPX_TUNNEL_END" "$config_file" 2>/dev/null
}

tunnel_config_tail_intact() {
    local config_file="$1"
    [[ -f "$config_file" ]] && tail -n "$WP_CONFIG_PROTECTED_TAIL" "$config_file" | grep -q "wp-settings.php" 2>/dev/null
}

tunnel_cleanup_old_patches() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then return 0; fi
    if ! tunnel_has_old_markers "$config_file" && ! tunnel_is_config_patched "$config_file"; then return 0; fi

    print_info "Detecteds old blocks DPX. Clean out..."
    local temp_file
    temp_file=$(create_temp_file)

    awk '
        /DPX_TUNNEL_FIX[^_]/ || /DPX_TUNNEL_START/ || /DPX_SMART_TUNNEL/ { skip=1; next }
        /END_DPX_TUNNEL_FIX/ || /DPX_TUNNEL_END/   || /END_DPX_SMART_TUNNEL/ { skip=0; next }
        !skip { print }
    ' "$config_file" > "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        print_error "Error cleanups: empty result. File not overwrit."
        rm -f "$temp_file"
        return 1
    fi

    mv "$temp_file" "$config_file"

    if ! tunnel_has_old_markers "$config_file" && ! tunnel_is_config_patched "$config_file"; then
        print_success "Old blocks DPX delets."
        return 0
    else
        print_warning "Not remove fully clean old blocks."
        return 1
    fi
}

tunnel_backup_wp_config() {
    local config_file="$1"
    dpx_wp_config_snapshot "$config_file"
}

tunnel_restore_wp_config() {
    local config_file="$1"
    dpx_wp_config_rollback "$config_file"
}

tunnel_verify_config_integrity() {
    local project_path="$1"
    local config_file="$2"
    print_info "Check integrities wp-config.php via WP-CLI..."
    local wp_version
    wp_version=$(tunnel_wp_exec "$project_path" core version --quiet 2>/dev/null)
    if [[ -n "$wp_version" ]]; then
        print_success "wp-config.php whole: WordPress $wp_version"
        return 0
    else
        print_error "wp-config.php corrupt! WP-CLI not may read back config."
        if tunnel_restore_wp_config "$config_file"; then
            wp_version=$(tunnel_wp_exec "$project_path" core version --quiet 2>/dev/null)
            if [[ -n "$wp_version" ]]; then
                print_success "Config restore. WordPress $wp_version"
                return 0
            else
                print_error "Restored config also broken!"
                return 1
            fi
        else
            print_error "Backup unavailable. Requires manual fix!"
            return 1
        fi
    fi
}

# =================================================================
# Patch wp-config.php: injected DPX_SMART_TUNNEL block (v1.5.6)
# HARDCODE: wes hard write in tunnel domain in $_SERVER,
# so that DDEV's Traefik Host Header Spoofing not broke WP with point.
# =================================================================
tunnel_patch_wp_config() {
    local config_file="$1"
    local tunnel_url="$2"

    local tunnel_domain
    tunnel_domain=$(echo "$tunnel_url" | sed 's|https\?://||;s|/$||')

    if [[ ! -f "$config_file" ]]; then
        print_warning "wp-config.php not found. Skip patching."
        return 0
    fi

    local backup_file
    backup_file=$(tunnel_backup_wp_config "$config_file") || {
        print_error "Sb create snapshot. Patch CANCEL. Original not chang."
        return 1
    }

    if [[ ! -f "$backup_file" ]]; then
        print_error "Snapshot not created! File missing: $backup_file"
        return 1
    fi

    if ! tunnel_config_tail_intact "$config_file"; then
        print_error "wp-config.php corrupt (missing wp-settings.php)."
        dpx_wp_config_cleanup "$config_file"
        return 1
    fi

    if ! tunnel_cleanup_old_patches "$config_file"; then
        print_error "Error cleanups old blocks. Rollback from snapshot..."
        tunnel_restore_wp_config "$config_file" || true
        return 1
    fi

    if tunnel_is_config_patched "$config_file"; then
        return 0
    fi

    local php_tag_line
    php_tag_line=$(grep -n '<?php' "$config_file" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$php_tag_line" ]]; then
        print_error "Tag <?php not found."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local total_lines
    total_lines=$(wc -l < "$config_file")
    total_lines="${total_lines// /}"

    local protected_start=$((total_lines - WP_CONFIG_PROTECTED_TAIL + 1))
    if (( php_tag_line >= protected_start )); then
        print_error "Tag <?php in protected zone tail."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local block_file
    block_file=$(create_temp_file)
    tunnel_smart_block_render "$tunnel_domain" > "$block_file"

    local temp_file
    temp_file=$(create_temp_file)
    head -n "$php_tag_line" "$config_file" > "$temp_file"
    cat "$block_file" >> "$temp_file"
    tail -n +$((php_tag_line + 1)) "$config_file" >> "$temp_file"
    rm -f "$block_file"

    sed -i \
        -e "/^[[:space:]]*define('WP_HOME',/ { /!defined('WP_HOME')/! s/^\([[:space:]]*\)define('WP_HOME',/\1if (!defined('WP_HOME')) define('WP_HOME',/ }" \
        -e "/^[[:space:]]*define('WP_SITEURL',/ { /!defined('WP_SITEURL')/! s/^\([[:space:]]*\)define('WP_SITEURL',/\1if (!defined('WP_SITEURL')) define('WP_SITEURL',/ }" \
        "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        print_error "Error patch: empty result."
        rm -f "$temp_file"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! mv "$temp_file" "$config_file"; then
        print_error "Not remove overwrite wp-config.php (error mv)!"
        rm -f "$temp_file" 2>/dev/null
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local project_path
    project_path=$(dirname "$config_file")
    if ! dpx_wp_config_syntax_check "$project_path" "$config_file"; then
        print_error "Syntax error! Rollback from snapshot..."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! tunnel_is_config_patched "$config_file"; then
        print_error "Smart-block not injected. Verification failed."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! tunnel_config_tail_intact "$config_file"; then
        print_error "Patch corrupted tail wp-config.php! Rollback..."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    print_success "wp-config.php: DPX_SMART_TUNNEL injected (Host: ${tunnel_domain})"
    print_info "Snapshot saved until completion tunnel: $backup_file"
    return 0
}

tunnel_unpatch_wp_config() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ -f "$backup_file" ]]; then
        print_info "Restore wp-config.php from snapshot (mv -f)..."
        if tunnel_restore_wp_config "$config_file"; then
            print_success "wp-config.php restore from snapshot (byte-for-byte)."
            return 0
        else
            print_error "CRITICAL ERROR: mv -f not remove!"
            return 1
        fi
    fi

    if [[ -f "$config_file" ]] && tunnel_is_config_patched "$config_file"; then
        print_warning "Snapshot missing, but founds DPX-blocks. awk-cleanup..."

        local temp_file
        temp_file=$(create_temp_file)

        awk '
            /DPX_SMART_TUNNEL/ || /DPX_TUNNEL_START/ || /DPX_TUNNEL_FIX[^_]/ { skip=1; next }
            /END_DPX_SMART_TUNNEL/ || /DPX_TUNNEL_END/ || /END_DPX_TUNNEL_FIX/ { skip=0; next }
            !skip { print }
        ' "$config_file" > "$temp_file"

        if [[ -s "$temp_file" ]]; then
            if mv "$temp_file" "$config_file"; then
                print_success "DPX-blocks delets (legacy-fallback)."
                return 0
            else
                print_error "Error mv durings fallback cleanup!"
                rm -f "$temp_file"
                return 1
            fi
        else
            print_error "awk-cleanup gave empty result! File not overwrit."
            rm -f "$temp_file"
            return 1
        fi
    fi

    return 0
}

# =================================================================
# LEVEL 2.2: NGINX HOT-PATCH
# =================================================================

# Generation script Nginx Hot-Patch (executes internals web-container
# via `ddev exec`). Allocated in function, so that unit-tests coulds
# verify content patch without start container.
#
# [FIX v1.5.7] Adds proxy-headers: for reverse-proxy (Cloudflare ->
# ddev-router -> nginx) Nginx built absolute 301 Location from internal
# scheme/port. `absolute_redirect off` + `port_in_redirect off` give
# relative Location, and proxy_set_header forward correct
# Host/Proto in we proxy location.
tunnel_nginx_patch_render() {
    cat << 'PATCH_EOF'
#!/bin/bash
# DPX Nginx Hot-Patch v1.5.7 — absolute_redirect + port_in_redirect + forwarded headers
# Ephemerality: disappears durings ddev restart (container recreates).

# --- Cleanup previous patch (idempotent) ---
for f in /etc/nginx/nginx.conf /etc/nginx/sites-enabled/*.conf /etc/nginx/conf.d/*.conf; do
    [ -f "$f" ] || continue
    sed -i '/# BEGIN_DPX_NGINX/,/# END_DPX_NGINX/d' "$f" 2>/dev/null
done
rm -f /etc/nginx/conf.d/dpx-tunnel.conf 2>/dev/null

# --- Injection: server-level directives + location-blocks for WP admin ---
for f in /etc/nginx/nginx.conf /etc/nginx/sites-enabled/*.conf /etc/nginx/conf.d/*.conf; do
    [ -f "$f" ] || continue
    grep -q "server[[:blank:]]*{" "$f" 2>/dev/null || continue
    grep -q "# BEGIN_DPX_NGINX" "$f" 2>/dev/null && continue
    awk '/^[[:blank:]]*server[[:blank:]]*\{/{
        print
        print "    # BEGIN_DPX_NGINX"
        print "    absolute_redirect off;"
        print "    server_name_in_redirect off;"
        print "    port_in_redirect off;"
        print "    proxy_set_header Host $http_host;"
        print "    proxy_set_header X-Forwarded-Proto https;"
        print "    location = /wp-admin { absolute_redirect off; return 301 /wp-admin/; }"
        print "    location = /wp-login { absolute_redirect off; return 301 /wp-login.php; }"
        print "    # END_DPX_NGINX"
        next
    }1' "$f" > /tmp/_dpx_nginx_$$ && mv /tmp/_dpx_nginx_$$ "$f"
done

# --- Reload nginx (cascade methods for any configurations DDEV) ---
nginx -t 2>&1 || exit 1
_reload_ok=false

# Method 1: standard nginx -s reload (PID file valid)
if [ -s /run/nginx.pid ]; then
    nginx -s reload 2>&1 && _reload_ok=true && echo "nginx: reloaded (PID file)"
fi

# Method 2: service/openrc (some containers use service wrapper)
if [ "$_reload_ok" = false ] && command -v service >/dev/null 2>&1; then
    service nginx reload 2>/dev/null && _reload_ok=true && echo "nginx: reloaded (service)"
fi

# Method 3: PID 1 — nginx/tini as init-process Docker
if [ "$_reload_ok" = false ]; then
    kill -HUP 1 2>/dev/null && sleep 0.3 && _reload_ok=true && echo "nginx: HUP sent to PID 1"
fi

# Method 4: pgrep exact match
if [ "$_reload_ok" = false ]; then
    _pid=$(pgrep -x nginx 2>/dev/null | head -1)
    [ -n "$_pid" ] && kill -HUP "$_pid" 2>/dev/null && _reload_ok=true && echo "nginx: HUP via pgrep (pid=$_pid)"
fi

# Method 5: /proc scanning (not requires ps/pgrep)
if [ "$_reload_ok" = false ]; then
    for _p in /proc/[0-9]*; do
        _comm=$(cat "$_p/comm" 2>/dev/null) || continue
        if [ "$_comm" = "nginx" ]; then
            _pid="${_p##*/}"
            kill -HUP "$_pid" 2>/dev/null && _reload_ok=true && echo "nginx: HUP via /proc (pid=$_pid)"
            break
        fi
    done
fi

# Method 6: pkill SIGHUP everyone nginx
if [ "$_reload_ok" = false ]; then
    pkill -HUP -x nginx 2>/dev/null && _reload_ok=true && echo "nginx: HUP via pkill"
fi

# Method 7: NUCLEAR — kill and restart nginx
if [ "$_reload_ok" = false ]; then
    for _p in /proc/[0-9]*; do
        _comm=$(cat "$_p/comm" 2>/dev/null) || continue
        [ "$_comm" = "nginx" ] && kill "$_p" 2>/dev/null
    done
    pkill -x nginx 2>/dev/null || true
    sleep 0.5
    nginx 2>/dev/null && _reload_ok=true && echo "nginx: nuclear restart"
fi

# Diagnostics ifs ALL fail
if [ "$_reload_ok" = false ]; then
    _diag=""
    for _p in /proc/[0-9]*; do
        [ -f "$_p/comm" ] && _diag="$_diag $(cat "$_p/comm" 2>/dev/null)"
    done
    echo "nginx: WARNING — reload failed. Processes:$_diag"
fi
PATCH_EOF
}

tunnel_patch_nginx() {
    local project_path="$1"
    print_info "Nginx Hot-Patch (absolute_redirect off + forwarded headers)..."

    local shared_dir="$project_path/.dpx"
    mkdir -p "$shared_dir"
    local patch_script="$shared_dir/_nginx_patch.sh"

    tunnel_nginx_patch_render > "$patch_script"

    (
        cd "$project_path" || exit 0
        ddev exec bash /var/www/html/.dpx/_nginx_patch.sh
    ) || true

    rm -f "$patch_script"
}

tunnel_unpatch_nginx() {
    local project_path="$1"
    print_info "Rollback Nginx Hot-Patch..." >&2

    local shared_dir="$project_path/.dpx"
    local patch_script="$shared_dir/_nginx_unpatch.sh"
    cat > "$patch_script" << 'UNPATCH_EOF'
#!/bin/bash
for f in /etc/nginx/nginx.conf /etc/nginx/sites-enabled/*.conf /etc/nginx/conf.d/*.conf; do
    [ -f "$f" ] || continue
    sed -i '/# BEGIN_DPX_NGINX/,/# END_DPX_NGINX/d' "$f" 2>/dev/null
done
rm -f /etc/nginx/conf.d/dpx-tunnel.conf 2>/dev/null
nginx -t 2>&1 || exit 0
if [ -s /run/nginx.pid ]; then
    nginx -s reload 2>&1
else
    _pid=$(pgrep -x nginx 2>/dev/null | head -1)
    [ -z "$_pid" ] && _pid=$(ps -eo pid,comm 2>/dev/null | awk '$2=="nginx"{print $1; exit}')
    [ -z "$_pid" ] && _pid=$(ps -eo pid,args 2>/dev/null | grep '[n]ginx: master' | awk '{print $1; exit}')
    [ -n "$_pid" ] && kill -HUP "$_pid" 2>/dev/null
    [ -z "$_pid" ] && pkill -HUP -x nginx 2>/dev/null
fi ; true
UNPATCH_EOF

    (
        cd "$project_path" || exit 0
        ddev exec bash /var/www/html/.dpx/_nginx_unpatch.sh
    ) >/dev/null 2>&1 || true

    rm -f "$patch_script"
}

# =================================================================
# LEVEL 3: database SYNC — Engine migrations (v1.4.18)
# =================================================================

_DPX_DB_MUTATING=0
_DPX_ACTUAL_HOME=""

# Gets REAL home URL PAGE via SQL (without WP-CLI).
tunnel_get_actual_home() {
    local project_path="$1"
    db_sql_get_option "$project_path" "home"
}

tunnel_wp_db_replace() {
    local project_path="$1" tunnel_url="$2"

    print_info "Received ACTUAL_HOME from database (SQL-request)..."
    local actual_home
    actual_home=$(tunnel_get_actual_home "$project_path")

    if [[ -z "$actual_home" ]]; then
        print_error "Not remove get home URL from database (SQL). Stop!"
        return 1
    fi

    _DPX_ACTUAL_HOME="$actual_home"
    print_info "ACTUAL_HOME from database: $actual_home"

    if [[ "$actual_home" == "$tunnel_url" ]]; then
        print_warning "URL match. Replace not need."
        return 0
    fi

    _DPX_DB_MUTATING=1

    local snapshot_name
    snapshot_name=$(db_smart_replace_tunnel "$actual_home" "$tunnel_url" "$project_path")
    local replace_rc=$?

    if [[ $replace_rc -ne 0 ]]; then
        _DPX_DB_MUTATING=0
        print_error "Mutation database fail. Wait automatic rollback..."
        return 1
    fi

    _DPX_DB_MUTATING=0

    # Save name snapshot for tunnel_cleanup rollback
    if [[ -n "$snapshot_name" ]]; then
        mkdir -p "${project_path}/.dpx" 2>/dev/null
        echo "$snapshot_name" > "${project_path}/.dpx/current_snapshot"
    fi

    # db_smart_replace_tunnel already did db_wp_clear_cache internals.
    # Additional reset rewrite rules
    tunnel_wp_exec "$project_path" rewrite flush --allow-root --quiet 2>/dev/null || true

    return 0
}

# Rollback database via ddev snapshot restore (v1.4.21)
tunnel_wp_db_rollback() {
    local project_path="$1"
    local tunnel_url="${2:-$_DPX_TUNNEL_URL}"
    local local_url="${3:-$_DPX_TUNNEL_LOCAL_URL}"

    local snap_file="${project_path}/.dpx/current_snapshot"
    local saved_snap_name=""
    local snapshot_available=false

    if [[ -f "$snap_file" ]]; then
        saved_snap_name=$(cat "$snap_file")
        saved_snap_name="${saved_snap_name// /}"
        if [[ -n "$saved_snap_name" ]]; then
            snapshot_available=true
        fi
    fi

    local rollback_ok=false

    if [[ "$snapshot_available" == "true" ]]; then
        echo "" >&2
        print_info "ROLLBACK database (Plan And): Restore from snapshot $saved_snap_name..." >&2

        if dpx_exec_and_log "$project_path" ddev snapshot restore "$saved_snap_name"; then
            rollback_ok=true
            print_success "Base data restore from snapshot." >&2
        else
            print_error "Snapshot restore FAILED: $saved_snap_name" >&2
            print_warning "Transition to Plan B (reverse search-replace)..." >&2
        fi
        rm -f "$snap_file"
    fi

    if [[ "$rollback_ok" == "false" ]]; then
        if [[ -z "$tunnel_url" || -z "$local_url" ]]; then
            print_error "Manual restore impossible: URL unknowns." >&2
            return 1
        fi

        echo "" >&2
        print_warning "ROLLBACK database (Plan B): Reverse search-replace (3 pass)..." >&2

        local tunnel_bare=$(echo "$tunnel_url" | sed 's|https\?://||;s|/$||')
        local local_bare=$(echo "$local_url" | sed 's|https\?://||;s|/$||')

        print_info "  [1/3] $tunnel_url -> $local_url" >&2
        (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
            /usr/local/bin/wp search-replace "$tunnel_url" "$local_url" \
            --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
        sleep 1; sync 2>/dev/null || true

        if [[ -n "$tunnel_bare" ]]; then
            print_info "  [2/3] http://$tunnel_bare -> $local_url" >&2
            (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
                /usr/local/bin/wp search-replace "http://${tunnel_bare}" "$local_url" \
                --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
            sleep 1; sync 2>/dev/null || true
        fi

        if [[ -n "$tunnel_bare" && "$tunnel_bare" != "$local_bare" ]]; then
            print_info "  [3/3] $tunnel_bare -> $local_bare" >&2
            (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
                /usr/local/bin/wp search-replace "$tunnel_bare" "$local_bare" \
                --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
            sleep 1; sync 2>/dev/null || true
        fi

        rollback_ok=true
        print_success "Reverse search-replace completion (3 pass)." >&2
    fi

    print_info "Post-rollback cleanup..." >&2

    # Universal cleanup
    db_wp_clear_cache "$project_path"

    tunnel_wp_exec "$project_path" rewrite flush --allow-root --quiet 2>/dev/null || true
    rm -f "$snap_file"

    print_success "database returned to local state. Cache flushed." >&2
    return 0
}

# =================================================================
# LEVEL 4: LIFECYCLE LOOP — Trap and cleanup
# =================================================================

_DPX_TUNNEL_PROJECT_PATH=""
_DPX_TUNNEL_URL=""
_DPX_TUNNEL_LOCAL_URL=""
_DPX_TUNNEL_CMS_TYPE=""
_DPX_TUNNEL_PID=""
_DPX_TUNNEL_LOG_FILE=""
_DPX_TUNNEL_CONFIG_FILE=""
_DPX_TUNNEL_PROVIDER=""
_DPX_TUNNEL_NGINX_CONF=""
_DPX_ROLLBACK_DONE=false
_DPX_ACTUAL_HOME=""

tunnel_cleanup() {
    local exit_code=$?

    # ==============================================================
    # ATOMIC LOCK: prevent double rollback
    # ==============================================================
    if [[ "$_DPX_ROLLBACK_DONE" == "true" ]]; then exit "$exit_code"; fi
    _DPX_ROLLBACK_DONE=true

    # Disarm trap BEFORE anies actions
    trap - INT TERM EXIT

    echo "" >&2
    print_header "Completion tunnel — rollback"

    # ==============================================================
    # 1. RESTOR wp-config.php (Hour 1)
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_CONFIG_FILE" ]] && [[ -f "$_DPX_TUNNEL_CONFIG_FILE" ]]; then
        tunnel_unpatch_wp_config "$_DPX_TUNNEL_CONFIG_FILE"
    fi

    # ==============================================================
    # 2. ROLLBACK database
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_PROJECT_PATH" && -n "$_DPX_TUNNEL_URL" && -n "$_DPX_TUNNEL_LOCAL_URL" ]]; then
        if [[ "$_DPX_TUNNEL_CMS_TYPE" == "wordpress" ]]; then
            tunnel_wp_db_rollback "$_DPX_TUNNEL_PROJECT_PATH"
        fi
    fi

    # ==============================================================
    # 3. FINAL CHORD (Suppressed interference DDEV)
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_CONFIG_FILE" ]]; then
        local backup_file
        backup_file=$(_dpx_wp_config_backup_path "$_DPX_TUNNEL_CONFIG_FILE")
        if [[ -f "$backup_file" ]]; then
            print_info "Final chord: hard restore wp-config.php..." >&2
            cp -f "$backup_file" "$_DPX_TUNNEL_CONFIG_FILE" 2>/dev/null
        fi

        # Check and delete markers
        if grep -q "DPX_SMART_TUNNEL" "$_DPX_TUNNEL_CONFIG_FILE" 2>/dev/null; then
            print_error "CRITICAL ERROR: DPX_SMART_TUNNEL all yet in file after rollback!" >&2
        else
            dpx_wp_config_cleanup "$_DPX_TUNNEL_CONFIG_FILE"
        fi
    fi

    # ==============================================================
    # 3.5. ROLLBACK NGINX HOT-PATCH
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_PROJECT_PATH" ]]; then
        tunnel_unpatch_nginx "$_DPX_TUNNEL_PROJECT_PATH"
    fi

    # ==============================================================
    # 4. Stop provider and logs
    # ==============================================================
    [[ -n "$_DPX_TUNNEL_PID" ]] && tunnel_provider_stop "$_DPX_TUNNEL_PROVIDER" "$_DPX_TUNNEL_PID"
    [[ -n "$_DPX_TUNNEL_LOG_FILE" && -f "$_DPX_TUNNEL_LOG_FILE" ]] && rm -f "$_DPX_TUNNEL_LOG_FILE"

    print_celebration "Rollback completion. Project returned to local state."
    exit "$exit_code"
}

# =================================================================
# SMART CONTEXT — Autodetection project
# =================================================================

tunnel_detect_project_from_cwd() {
    # Method 1: File system — .ddev/config.yaml (FAST)
    local search_dir
    search_dir=$(_dpx_realpath "$PWD")
    while [[ -n "$search_dir" && "$search_dir" != "/" ]]; do
        if [[ -f "${search_dir}/.ddev/config.yaml" ]]; then
            local detected_name
            detected_name=$(grep -E '^name:' "${search_dir}/.ddev/config.yaml" 2>/dev/null \
                | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
            if [[ -n "$detected_name" ]]; then
                if ddev describe "$detected_name" -j >/dev/null 2>&1; then
                    echo "$detected_name"
                    return 0
                fi
            fi
            return 1
        fi
        search_dir=$(dirname "$search_dir")
    done

    # Method 2: DDEV auto-detection (FALLBACK)
    local proj_name
    proj_name=$(ddev describe -j 2>/dev/null | jq -r '.raw.name // empty' 2>/dev/null)
    if [[ -n "$proj_name" ]]; then
        echo "$proj_name"
        return 0
    fi

    return 1
}

tunnel_detect_project_path_from_cwd() {
    local search_dir
    search_dir=$(_dpx_realpath "$PWD")
    while [[ -n "$search_dir" && "$search_dir" != "/" ]]; do
        if [[ -f "${search_dir}/.ddev/config.yaml" ]]; then
            echo "$search_dir"
            return 0
        fi
        search_dir=$(dirname "$search_dir")
    done

    local proj_path
    proj_path=$(ddev describe -j 2>/dev/null | jq -r '.raw.approot // empty' 2>/dev/null)
    if [[ -n "$proj_path" ]]; then
        echo "$proj_path"
        return 0
    fi

    return 1
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_tunnel() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_tunnel_help
        return 0
    fi

    print_header "Forwarding tunnel v${DPX_VERSION}"

    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq not found. Required for parsing DDEV JSON-output."
        print_info "Install: Ubuntu/Debian: sudo apt install jq | macOS: brew install jq"
        return 1
    fi

    local provider
    provider=$(get_arg "provider" "")
    if [[ -z "$provider" ]]; then
        provider=$(tunnel_select_provider)
        if [[ $? -ne 0 ]] || [[ -z "$provider" ]]; then
            print_error "Provider tunnel not found."
            return 1
        fi
    fi
    print_info "Provider: $provider"
    tunnel_provider_check "$provider" || return 1

    local project_name
    local project_path
    local auto_detected=false

    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        project_name=$(tunnel_detect_project_from_cwd)
        if [[ -n "$project_name" ]]; then
            auto_detected=true
            project_path=$(tunnel_detect_project_path_from_cwd)
            print_success "Autodetection: project '$project_name' (DDEV API)"
        fi
    fi

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Select project for tunnel")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    if [[ -z "$project_path" ]]; then
        project_path=$(projects_get_path "$project_name")
    fi
    validate_directory "$project_path" "Director project" || return 1

    print_info "Root project: $project_path"

    local cms_type
    cms_type=$(get_arg "cms_type" "")
    if [[ -z "$cms_type" ]]; then
        cms_type=$(detect_cms_type "$project_path")
        print_info "Autodetection CMS: $(get_cms_name "$cms_type")"
        if [[ "$cms_type" != "wordpress" ]]; then
            print_warning "Type: $(get_cms_name "$cms_type"). Database URL replacement will NOT be performed."
            if ! confirm "Continue without replaces URL?"; then
                cms_type=$(select_cms_type "Select type project") || return 1
            fi
        fi
    fi
    print_success "Type project: $(get_cms_name "$cms_type")"

    if [[ "$cms_type" == "wordpress" ]]; then
        dpx_wp_config_stale_check "${project_path}/wp-config.php" || return 1
    fi

    if ! ddev_is_project_running "$project_name"; then
        print_warning "Project '$project_name' not run."
        if has_arg "yes" || confirm "Start?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Project must was run."
            return 1
        fi
    fi
    print_success "Project run."

    local project_url
    project_url=$(tunnel_get_target_url "$project_name")
    print_info "Local URL: $project_url"

    local http_port
    http_port=$(tunnel_get_http_port "$project_name")
    print_info "Host port (DDEV → Docker): $http_port"

    local local_domain
    local_domain=$(tunnel_get_local_domain "$project_name")
    print_info "Local domain: $local_domain"

    local local_tld
    local_tld="${local_domain##*.}"

    local local_url="https://${local_domain}"

    local cloudflared_target_url="http://127.0.0.1:${http_port}"
    local cloudflared_host_header="$local_domain"
    print_info "cloudflared → $cloudflared_target_url (Host: $cloudflared_host_header)"

    local log_file
    log_file=$(create_temp_file)
    _DPX_TUNNEL_LOG_FILE="$log_file"

    print_header "Verify parameters"
    cat >&2 << PARAMS
Project:            ${COLOR_GREEN}${project_name} ($(get_cms_name "$cms_type"))${COLOR_RESET}
Root project:    ${COLOR_GREEN}${project_path}${COLOR_RESET}
Local URL:     ${COLOR_YELLOW}${local_url}${COLOR_RESET}
Host port:         ${COLOR_GREEN}${http_port}${COLOR_RESET}
Host-header:    ${COLOR_GREEN}${cloudflared_host_header}${COLOR_RESET}
Provider:         ${COLOR_GREEN}${provider}${COLOR_RESET}
Local TLD:     ${COLOR_GREEN}.${local_tld}${COLOR_RESET}
Replace URL:        ${COLOR_GREEN}$([ "$cms_type" = "wordpress" ] && echo "Yes (wp search-replace + smart wp-config)" || echo "No (only forwarding port)")${COLOR_RESET}
PARAMS

    print_separator
    print_info "Ctrl+C → full rollback: mv -f from snapshot + wp search-replace back"

    if ! has_arg "yes"; then
        confirm "Start forwarding tunnel?" || return 1
    fi

    _DPX_TUNNEL_PROJECT_PATH="$project_path"
    _DPX_TUNNEL_LOCAL_URL="$local_url"
    _DPX_TUNNEL_CMS_TYPE="$cms_type"
    _DPX_TUNNEL_PROVIDER="$provider"

    if [[ "$cms_type" == "wordpress" ]]; then
        _DPX_TUNNEL_CONFIG_FILE="${project_path}/wp-config.php"
    fi

    trap 'tunnel_cleanup' INT TERM EXIT

    # --- Step 1: Start tunnel ---
    print_step "1" "Start tunnel ($provider)"
    tunnel_provider_start "$provider" "$cloudflared_target_url" "$log_file" "$cloudflared_host_header" || {
        print_error "Not remove start tunnel."
        return 1
    }
    local tunnel_url="$_DPX_TUNNEL_URL"

    # --- Step 2: Database Sync ---
    if [[ "$cms_type" == "wordpress" ]]; then
        print_step "2" "Replace URL in base data"
        tunnel_wp_db_replace "$project_path" "$tunnel_url" || {
            print_error "Error replaces URL. Rollback..."
            return 1
        }
    fi

    # --- Step 3: Patch configurations (DPX_SMART_TUNNEL & Nginx) ---
    if [[ "$cms_type" == "wordpress" ]]; then
        print_step "3" "Patch configurations (DPX_SMART_TUNNEL & Nginx Hot-Patch)"
        if ! tunnel_patch_wp_config "${project_path}/wp-config.php" "$tunnel_url"; then
            print_error "Patch wp-config.php failed. Rollback..."
            return 1
        fi

        tunnel_patch_nginx "$project_path"
    fi

    # --- Ready ---
    cat >&2 << READY

${COLOR_GREEN}🎉 Tunnel active! 🎉${COLOR_RESET}

${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}
${COLOR_BOLD}  Public URL: ${tunnel_url}${COLOR_RESET}
${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}

Send this URL client.
Press Ctrl+C for completion tunnel and rollback.
READY

    local uptime=0
    while kill -0 "$_DPX_TUNNEL_PID" 2>/dev/null; do
        sleep 5
        ((uptime += 5))
        if (( uptime % 60 == 0 )); then
            print_info "Tunnel: $((uptime / 60)) min. | URL: $tunnel_url"
        fi
    done

    print_warning "Tunnel complete unexpected. Rollback..."
    return 1
}
