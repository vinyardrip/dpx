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
 ${COLOR_BOLD}tunnel${COLOR_RESET} - $(t tunnel.help.title)

 ${COLOR_BOLD}$(t tunnel.help.usage)${COLOR_RESET}
    ${TOOL_NAME} tunnel [options]

 ${COLOR_BOLD}$(t tunnel.help.description_label)${COLOR_RESET}
    $(t tunnel.help.description)
    $(t tunnel.help.wordpress)

 ${COLOR_BOLD}$(t tunnel.help.options)${COLOR_RESET}
    --project-name NAME    $(t tunnel.help.project_option)
    --cms-type TYPE        $(t tunnel.help.cms_option)
    --provider=ngrok|cloudflare
                           $(t tunnel.help.provider_option)
    -y, --yes              $(t tunnel.help.yes_option)
    -h, --help             $(t tunnel.help.help_option)
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
        print_header "$(t tunnel.provider.select)"
        local i=1
        while IFS= read -r prov; do
            echo "  $i. $prov" >&2
            ((i++))
        done <<< "$providers"
        local choice
        read -r -p "$(t tunnel.provider.prompt)" choice
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
        print_error "$(t tunnel.binary.not_found cloudflared)"
        print_info "$(t tunnel.install 'https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/')"
        return 1
    fi
    print_success "$(t tunnel.binary.found cloudflared "$(cloudflared --version 2>&1 | head -1)")"
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

    "${cf_cmd[@]}" > "$log_file" 2>&1 </dev/null &
    local pid=$!

    print_info "$(t tunnel.cloudflare.running "$pid")"
    print_info "$(t tunnel.waiting_url)"

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
        print_error "$(t tunnel.url.timeout "$max_wait")"
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
        return 1
    fi

    _DPX_TUNNEL_PID="$pid"
    _DPX_TUNNEL_URL="$tunnel_url"
    print_success "$(t tunnel.created "$tunnel_url")"
    return 0
}

tunnel_cloudflare_stop() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_info "$(t tunnel.provider.stopping cloudflared "$pid")"
        kill "$pid" 2>/dev/null
        local wait_count=0
        while kill -0 "$pid" 2>/dev/null && (( wait_count < 10 )); do
            sleep 0.5
            ((wait_count++))
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        print_success "$(t tunnel.provider.stopped cloudflared)"
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
        print_error "$(t tunnel.binary.not_found ngrok)"
        print_info "$(t tunnel.ngrok.install_header)"
        print_info "$(t tunnel.ngrok.install_macos)"
        print_info "$(t tunnel.ngrok.install_debian)"
        print_info "$(t tunnel.ngrok.install_arch)"
        print_info "$(t tunnel.ngrok.authorize)"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        print_error "$(t tunnel.ngrok.curl_required)"
        return 1
    fi
    print_success "$(t tunnel.binary.found ngrok "$(ngrok --version 2>&1 | head -1)")"
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

    "${cmd[@]}" > "$log_file" 2>&1 </dev/null &
    local pid=$!
    _DPX_TUNNEL_PID="$pid"

    print_info "$(t tunnel.ngrok.running "$pid" "$TUNNEL_NGROK_MAX_WAIT")"

    local tunnel_url=""
    tunnel_url=$(tunnel_ngrok_wait_public_url) || tunnel_url=""
    echo "" >&2

    if [[ -z "$tunnel_url" ]]; then
        if ! kill -0 "$pid" 2>/dev/null; then
            print_error "$(t tunnel.ngrok.exited)"
            tail -5 "$log_file" 2>/dev/null | sed 's/^/    /' >&2
            if grep -qiE 'ERR_NGROK_4018|authtoken' "$log_file" 2>/dev/null; then
                print_info "$(t tunnel.ngrok.authtoken)"
            fi
        else
            print_error "$(t tunnel.ngrok.timeout "$TUNNEL_NGROK_MAX_WAIT")"
            kill "$pid" 2>/dev/null || true
        fi
        return 1
    fi

    _DPX_TUNNEL_URL="$tunnel_url"
    print_success "$(t tunnel.created "$tunnel_url")"
    return 0
}

tunnel_ngrok_stop() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_info "$(t tunnel.provider.stopping ngrok "$pid")"
        kill "$pid" 2>/dev/null
        local wait_count=0
        while kill -0 "$pid" 2>/dev/null && (( wait_count < 10 )); do
            sleep 0.5
            ((wait_count++))
        done
        # Guarantee missing orphan-process
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        print_success "$(t tunnel.provider.stopped ngrok)"
    fi
}

tunnel_provider_check() {
    local provider="$1"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_check ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_check ;;
        *) print_error "$(t tunnel.provider.unknown "$provider")"; return 1 ;;
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

    print_warning "$(t tunnel.port.fallback)"
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
        print_warning "$(t tunnel.domain.fallback "$local_domain")"
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
        print_warning "$(t tunnel.url.fallback "$project_url")"
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

    print_info "$(t tunnel.wp.old.cleaning)"
    local temp_file
    temp_file=$(create_temp_file)

    awk '
        /DPX_TUNNEL_FIX[^_]/ || /DPX_TUNNEL_START/ || /DPX_SMART_TUNNEL/ { skip=1; next }
        /END_DPX_TUNNEL_FIX/ || /DPX_TUNNEL_END/   || /END_DPX_SMART_TUNNEL/ { skip=0; next }
        !skip { print }
    ' "$config_file" > "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        print_error "$(t tunnel.wp.cleanup_empty)"
        rm -f "$temp_file"
        return 1
    fi

    mv "$temp_file" "$config_file"

    if ! tunnel_has_old_markers "$config_file" && ! tunnel_is_config_patched "$config_file"; then
        print_success "$(t tunnel.wp.old.removed)"
        return 0
    else
        print_warning "$(t tunnel.wp.cleanup_incomplete)"
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
    print_info "$(t tunnel.wp.checking)"
    local wp_version
    wp_version=$(tunnel_wp_exec "$project_path" core version --quiet 2>/dev/null)
    if [[ -n "$wp_version" ]]; then
        print_success "$(t tunnel.wp.valid "$wp_version")"
        return 0
    else
        print_error "$(t tunnel.wp.invalid)"
        if tunnel_restore_wp_config "$config_file"; then
            wp_version=$(tunnel_wp_exec "$project_path" core version --quiet 2>/dev/null)
            if [[ -n "$wp_version" ]]; then
                print_success "$(t tunnel.wp.restore_valid "$wp_version")"
                return 0
            else
                print_error "$(t tunnel.wp.restore_invalid)"
                return 1
            fi
        else
            print_error "$(t tunnel.wp.backup_missing)"
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
        print_warning "$(t tunnel.wp.not_found)"
        return 0
    fi

    local backup_file
    backup_file=$(tunnel_backup_wp_config "$config_file") || {
        print_error "$(t tunnel.wp.snapshot_failed)"
        return 1
    }

    if [[ ! -f "$backup_file" ]]; then
        print_error "$(t tunnel.wp.snapshot_missing "$backup_file")"
        return 1
    fi

    if ! tunnel_config_tail_intact "$config_file"; then
        print_error "$(t tunnel.wp.settings_missing)"
        dpx_wp_config_cleanup "$config_file"
        return 1
    fi

    if ! tunnel_cleanup_old_patches "$config_file"; then
        print_error "$(t tunnel.wp.cleanup_rollback)"
        tunnel_restore_wp_config "$config_file" || true
        return 1
    fi

    if tunnel_is_config_patched "$config_file"; then
        return 0
    fi

    local php_tag_line
    php_tag_line=$(grep -n '<?php' "$config_file" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$php_tag_line" ]]; then
        print_error "$(t tunnel.wp.php_tag_missing)"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local total_lines
    total_lines=$(wc -l < "$config_file")
    total_lines="${total_lines// /}"

    local protected_start=$((total_lines - WP_CONFIG_PROTECTED_TAIL + 1))
    if (( php_tag_line >= protected_start )); then
        print_error "$(t tunnel.wp.php_tag_protected)"
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
        print_error "$(t tunnel.wp.patch_empty)"
        rm -f "$temp_file"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! mv "$temp_file" "$config_file"; then
        print_error "$(t tunnel.wp.overwrite_failed)"
        rm -f "$temp_file" 2>/dev/null
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local project_path
    project_path=$(dirname "$config_file")
    if ! dpx_wp_config_syntax_check "$project_path" "$config_file"; then
        print_error "$(t tunnel.wp.syntax_rollback)"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! tunnel_is_config_patched "$config_file"; then
        print_error "$(t tunnel.wp.inject_failed)"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! tunnel_config_tail_intact "$config_file"; then
        print_error "$(t tunnel.wp.tail_corrupt)"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    print_success "$(t tunnel.wp.injected "$tunnel_domain")"
    print_info "$(t tunnel.wp.snapshot_saved "$backup_file")"
    return 0
}

tunnel_unpatch_wp_config() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ -f "$backup_file" ]]; then
        print_info "$(t tunnel.wp.restoring)"
        if tunnel_restore_wp_config "$config_file"; then
            print_success "$(t tunnel.wp.restored)"
            return 0
        else
            print_error "$(t tunnel.wp.restore_failed)"
            return 1
        fi
    fi

    if [[ -f "$config_file" ]] && tunnel_is_config_patched "$config_file"; then
        print_warning "$(t tunnel.wp.fallback)"

        local temp_file
        temp_file=$(create_temp_file)

        awk '
            /DPX_SMART_TUNNEL/ || /DPX_TUNNEL_START/ || /DPX_TUNNEL_FIX[^_]/ { skip=1; next }
            /END_DPX_SMART_TUNNEL/ || /DPX_TUNNEL_END/ || /END_DPX_TUNNEL_FIX/ { skip=0; next }
            !skip { print }
        ' "$config_file" > "$temp_file"

        if [[ -s "$temp_file" ]]; then
            if mv "$temp_file" "$config_file"; then
                print_success "$(t tunnel.wp.fallback_removed)"
                return 0
            else
                print_error "$(t tunnel.wp.fallback_move_failed)"
                rm -f "$temp_file"
                return 1
            fi
        else
            print_error "$(t tunnel.wp.fallback_empty)"
            rm -f "$temp_file"
            return 1
        fi
    fi

    return 0
}

# =================================================================
# LEVEL 2.2: NGINX HOT-PATCH
# =================================================================

# Content of the NATIVE DDEV nginx extension (v1.5.2).
#
# [REFACTOR v1.5.2] Dynamic awk/sed rewriting of the container's main
# Nginx configuration REMOVED. DDEV natively bind-mounts
# .ddev/nginx_full/ into the web container, so the override lives on
# the HOST as a plain file and dies with the tunnel cleanup — no
# in-container mutation, nothing to repair after a crash beyond
# deleting the file.
#
# Directives: reverse-proxy (Cloudflare -> ddev-router -> nginx) made
# absolute 301 Location from internal scheme/port. `absolute_redirect
# off` + `port_in_redirect off` give relative Location; proxy_set_header
# forwards correct Host/Proto into the proxy location.
#
# Rendered in function so unit-tests verify content without container.
tunnel_nginx_config_render() {
    cat << 'NGINX_EOF'
# BEGIN_DPX_NGINX
# DPX tunnel override — GENERATED by `dpx tunnel`, removed on cleanup.
# Managed file: manual edits are lost on the next tunnel run.
absolute_redirect off;
server_name_in_redirect off;
port_in_redirect off;
proxy_set_header Host $http_host;
proxy_set_header X-Forwarded-Proto https;
location = /wp-admin { absolute_redirect off; return 301 /wp-admin/; }
location = /wp-login { absolute_redirect off; return 301 /wp-login.php; }
# END_DPX_NGINX
NGINX_EOF
}

tunnel_nginx_config_path() {
    printf '%s/.ddev/nginx_full/dpx-tunnel.conf\n' "$1"
}

tunnel_patch_nginx() {
    local project_path="$1"
    print_info "$(t tunnel.nginx.installing)"

    local conf_path
    conf_path="$(tunnel_nginx_config_path "$project_path")"

    if ! mkdir -p "$(dirname "$conf_path")" 2>/dev/null; then
        print_warning "$(t tunnel.nginx.directory_failed "$(dirname "$conf_path")")"
        return 0
    fi

    if ! tunnel_nginx_config_render > "$conf_path"; then
        print_warning "$(t tunnel.nginx.write_failed)"
        return 0
    fi

    if ! (
        cd "$project_path" || exit 1
        ddev exec nginx -s reload >/dev/null 2>&1
    ); then
        dpx_debug_trace "tunnel.nginx.reload_failed" "project=$project_path"
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] nginx -s reload failed; falling back to ddev restart" \
            >> "${project_path}/.dpx/debug.log" 2>/dev/null
        print_warning "$(t tunnel.nginx.reload_failed)"
        print_info "$(t tunnel.nginx.reload_fallback)"
        if (
            cd "$project_path" || exit 1
            ddev restart >/dev/null 2>&1
        ); then
            dpx_debug_trace "tunnel.nginx.restart_done" "project=$project_path"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ddev restart fallback completed" \
                >> "${project_path}/.dpx/debug.log" 2>/dev/null
            print_success "$(t tunnel.nginx.restart_done)"
        fi
    fi

    # Drop legacy artifacts from pre-v1.5.2 in-container hot-patch
    rm -f "${project_path}/.dpx/_nginx_patch.sh" "${project_path}/.dpx/_nginx_unpatch.sh" 2>/dev/null
    return 0
}

tunnel_unpatch_nginx() {
    local project_path="$1"
    print_info "$(t tunnel.nginx.removing)" >&2

    rm -f "$(tunnel_nginx_config_path "$project_path")" 2>/dev/null
    rm -f "${project_path}/.dpx/_nginx_patch.sh" "${project_path}/.dpx/_nginx_unpatch.sh" 2>/dev/null

    (
        cd "$project_path" || exit 0
        ddev exec nginx -s reload >/dev/null 2>&1
    ) || true

    return 0
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

    print_info "$(t tunnel.db.reading_home)"
    local actual_home
    actual_home=$(tunnel_get_actual_home "$project_path")

    if [[ -z "$actual_home" ]]; then
        print_error "$(t tunnel.db.home_missing)"
        return 1
    fi

    _DPX_ACTUAL_HOME="$actual_home"
    print_info "$(t tunnel.db.actual_home "$actual_home")"

    if [[ "$actual_home" == "$tunnel_url" ]]; then
        print_warning "$(t tunnel.db.same_url)"
        return 0
    fi

    _DPX_DB_MUTATING=1

    local snapshot_name
    snapshot_name=$(db_smart_replace_tunnel "$actual_home" "$tunnel_url" "$project_path")
    local replace_rc=$?

    if [[ $replace_rc -ne 0 ]]; then
        _DPX_DB_MUTATING=0
        print_error "$(t tunnel.db.replace_failed)"
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
        print_info "$(t tunnel.db.rollback_snapshot "$saved_snap_name")" >&2

        if dpx_exec_and_log "$project_path" ddev snapshot restore "$saved_snap_name"; then
            rollback_ok=true
            print_success "$(t tunnel.db.snapshot_restored)" >&2
        else
            print_error "$(t tunnel.db.snapshot_failed "$saved_snap_name")" >&2
            print_warning "$(t tunnel.db.plan_b)" >&2
        fi
        rm -f "$snap_file"
    fi

    if [[ "$rollback_ok" == "false" ]]; then
        if [[ -z "$tunnel_url" || -z "$local_url" ]]; then
            print_error "$(t tunnel.db.urls_unknown)" >&2
            return 1
        fi

        echo "" >&2
        print_warning "$(t tunnel.db.rollback_reverse)" >&2

        local tunnel_bare=$(echo "$tunnel_url" | sed 's|https\?://||;s|/$||')
        local local_bare=$(echo "$local_url" | sed 's|https\?://||;s|/$||')

        print_info "$(t tunnel.db.reverse_pass 1 "$tunnel_url" "$local_url")" >&2
        (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
            /usr/local/bin/wp search-replace "$tunnel_url" "$local_url" \
            --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
        sleep 1; sync 2>/dev/null || true

        if [[ -n "$tunnel_bare" ]]; then
            print_info "$(t tunnel.db.reverse_pass 2 "http://$tunnel_bare" "$local_url")" >&2
            (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
                /usr/local/bin/wp search-replace "http://${tunnel_bare}" "$local_url" \
                --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
            sleep 1; sync 2>/dev/null || true
        fi

        if [[ -n "$tunnel_bare" && "$tunnel_bare" != "$local_bare" ]]; then
            print_info "$(t tunnel.db.reverse_pass 3 "$tunnel_bare" "$local_bare")" >&2
            (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
                /usr/local/bin/wp search-replace "$tunnel_bare" "$local_bare" \
                --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
            sleep 1; sync 2>/dev/null || true
        fi

        rollback_ok=true
        print_success "$(t tunnel.db.reverse_done)" >&2
    fi

    print_info "$(t tunnel.db.cleanup)" >&2

    # Universal cleanup
    db_wp_clear_cache "$project_path"

    tunnel_wp_exec "$project_path" rewrite flush --allow-root --quiet 2>/dev/null || true
    rm -f "$snap_file"

    print_success "$(t tunnel.db.rollback_done)" >&2
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

    dpx_debug_trace "trap.cleanup" "handler=tunnel_cleanup" "exit_code=$exit_code"

    # ==============================================================
    # ATOMIC LOCK: prevent double rollback
    # ==============================================================
    if [[ "$_DPX_ROLLBACK_DONE" == "true" ]]; then exit "$exit_code"; fi
    _DPX_ROLLBACK_DONE=true

    # Disarm trap BEFORE anies actions
    trap - INT TERM EXIT

    if [[ -n "$_DPX_TUNNEL_PROJECT_PATH" ]]; then
        rm -f "${_DPX_TUNNEL_PROJECT_PATH}/.dpx/tunnel.pid" 2>/dev/null
    fi

    echo "" >&2
    print_header "$(t tunnel.cleanup.header)"

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
            print_info "$(t tunnel.cleanup.hard_restore)" >&2
            cp -f "$backup_file" "$_DPX_TUNNEL_CONFIG_FILE" 2>/dev/null
        fi

        # Check and delete markers
        if grep -q "DPX_SMART_TUNNEL" "$_DPX_TUNNEL_CONFIG_FILE" 2>/dev/null; then
            print_error "$(t tunnel.cleanup.marker_remaining)" >&2
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

    print_celebration "$(t tunnel.cleanup.done)"
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

    print_header "$(t tunnel.header "$DPX_VERSION")"

    if ! command -v jq >/dev/null 2>&1; then
        print_error "$(t tunnel.jq.missing)"
        print_info "$(t tunnel.jq.install)"
        return 1
    fi

    local provider
    provider="$(config_normalize_provider "$(get_arg "provider" "")")"
    if [[ -z "$provider" ]]; then
        # Prefer the provider configured via `dpx config` when its
        # binary is actually available; fall back to interactive menu.
        local preferred
        preferred="$(config_normalize_provider "$(get_config 'default_tunnel_provider' '')")"
        case "$preferred" in
            ngrok)      command -v ngrok      >/dev/null 2>&1 && provider="ngrok" ;;
            cloudflare) command -v cloudflared >/dev/null 2>&1 && provider="cloudflare" ;;
        esac
        [[ -n "$provider" ]] && print_info "$(t tunnel.provider.configured "$provider")"
    fi
    if [[ -z "$provider" ]]; then
        provider=$(tunnel_select_provider)
        if [[ $? -ne 0 ]] || [[ -z "$provider" ]]; then
            print_error "$(t tunnel.provider.not_found)"
            return 1
        fi
    fi
    print_info "$(t tunnel.provider.label) $provider"
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
            print_success "$(t tunnel.project.detected "$project_name")"
        fi
    fi

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "$(t tunnel.project.select)")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    if [[ -z "$project_path" ]]; then
        project_path=$(projects_get_path "$project_name")
    fi
    validate_directory "$project_path" "$(t tunnel.project.directory)" || return 1

    print_info "$(t tunnel.project.root) $project_path"

    local cms_type
    cms_type=$(get_arg "cms_type" "")
    if [[ -z "$cms_type" ]]; then
        cms_type=$(detect_cms_type "$project_path")
        print_info "$(t tunnel.cms.detected) $(get_cms_name "$cms_type")"
        if [[ "$cms_type" != "wordpress" ]]; then
            print_warning "$(t tunnel.cms.warning "$(get_cms_name "$cms_type")")"
            if ! confirm "$(t tunnel.cms.continue)"; then
                cms_type=$(select_cms_type "$(t tunnel.cms.select)") || return 1
            fi
        fi
    fi
    print_success "$(t tunnel.cms.type) $(get_cms_name "$cms_type")"

    if [[ "$cms_type" == "wordpress" ]]; then
        dpx_wp_config_stale_check "${project_path}/wp-config.php" || return 1
    fi

    if ! ddev_is_project_running "$project_name"; then
        print_warning "$(t tunnel.project.not_running "$project_name")"
        if has_arg "yes" || confirm "$(t tunnel.project.start)"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "$(t tunnel.project.must_run)"
            return 1
        fi
    fi
    print_success "$(t tunnel.project.running)"

    local project_url
    project_url=$(tunnel_get_target_url "$project_name")
    print_info "$(t tunnel.local_url) $project_url"

    local http_port
    http_port=$(tunnel_get_http_port "$project_name")
    print_info "$(t tunnel.host_port_ddev) $http_port"

    local local_domain
    local_domain=$(tunnel_get_local_domain "$project_name")
    print_info "$(t tunnel.local_domain) $local_domain"

    local local_tld
    local_tld="${local_domain##*.}"

    local local_url="https://${local_domain}"

    local cloudflared_target_url="http://127.0.0.1:${http_port}"
    local cloudflared_host_header="$local_domain"
    print_info "$(t tunnel.cloudflare.route "$cloudflared_target_url" "$cloudflared_host_header")"

    local log_file
    log_file=$(create_temp_file)
    _DPX_TUNNEL_LOG_FILE="$log_file"

    print_header "$(t tunnel.params.header)"
    local replace_label
    if [[ "$cms_type" == "wordpress" ]]; then
        replace_label="$(t tunnel.replace.yes)"
    else
        replace_label="$(t tunnel.replace.no)"
    fi
    printf '%-18s %b\n' "$(t tunnel.field.project)" "${COLOR_GREEN}${project_name} ($(get_cms_name "$cms_type"))${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.root)" "${COLOR_GREEN}${project_path}${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.local_url)" "${COLOR_YELLOW}${local_url}${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.host_port)" "${COLOR_GREEN}${http_port}${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.host_header)" "${COLOR_GREEN}${cloudflared_host_header}${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.provider)" "${COLOR_GREEN}${provider}${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.local_tld)" "${COLOR_GREEN}.${local_tld}${COLOR_RESET}" >&2
    printf '%-18s %b\n' "$(t tunnel.field.replace_url)" "${COLOR_GREEN}${replace_label}${COLOR_RESET}" >&2

    print_separator
    print_info "$(t tunnel.rollback.hint)"

    if ! has_arg "yes"; then
        confirm "$(t tunnel.start.prompt)" || return 1
    fi

    _DPX_TUNNEL_PROJECT_PATH="$project_path"
    _DPX_TUNNEL_LOCAL_URL="$local_url"
    _DPX_TUNNEL_CMS_TYPE="$cms_type"
    _DPX_TUNNEL_PROVIDER="$provider"

    if [[ "$cms_type" == "wordpress" ]]; then
        _DPX_TUNNEL_CONFIG_FILE="${project_path}/wp-config.php"
    fi

    trap 'tunnel_cleanup' INT TERM EXIT

    # Liveness marker: boot-time orphan check must NOT flag a session
    # that is currently running (kill -9 leaves a stale PID behind).
    mkdir -p "${project_path}/.dpx" 2>/dev/null
    echo "$$" > "${project_path}/.dpx/tunnel.pid" 2>/dev/null || true

    # --- Step 1: Start tunnel ---
    print_step "1" "$(t tunnel.step.start "$provider")"
    tunnel_provider_start "$provider" "$cloudflared_target_url" "$log_file" "$cloudflared_host_header" || {
        print_error "$(t tunnel.start.failed)"
        return 1
    }
    local tunnel_url="$_DPX_TUNNEL_URL"

    # --- Step 2: Database Sync ---
    if [[ "$cms_type" == "wordpress" ]]; then
        print_step "2" "$(t tunnel.step.replace)"
        tunnel_wp_db_replace "$project_path" "$tunnel_url" || {
            print_error "$(t tunnel.step.replace_failed)"
            return 1
        }
    fi

    # --- Step 3: Patch configurations (DPX_SMART_TUNNEL & Nginx) ---
    if [[ "$cms_type" == "wordpress" ]]; then
        print_step "3" "$(t tunnel.step.patch)"
        if ! tunnel_patch_wp_config "${project_path}/wp-config.php" "$tunnel_url"; then
            print_error "$(t tunnel.step.patch_failed)"
            return 1
        fi

        tunnel_patch_nginx "$project_path"
    fi

    # --- Ready ---
    cat >&2 << READY

${COLOR_GREEN}$(t tunnel.active)${COLOR_RESET}

${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}
${COLOR_BOLD}  $(t tunnel.public_url) ${tunnel_url}${COLOR_RESET}
${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}

$(t msg.tunnel.url_client)
$(t tunnel.stop_hint)
READY

    local uptime=0
    while kill -0 "$_DPX_TUNNEL_PID" 2>/dev/null; do
        sleep 5
        ((uptime += 5))
        if (( uptime % 60 == 0 )); then
            print_info "$(t tunnel.uptime "$((uptime / 60))" "$tunnel_url")"
        fi
    done

    print_warning "$(t tunnel.unexpected_exit)"
    return 1
}
