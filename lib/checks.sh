#!/usr/bin/env bash
# =================================================================
# DPX Checks Module - checks dependency and environment
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_CHECKS_LOADED:-}" ]] && return 0
readonly _DPX_CHECKS_LOADED=1

# =================================================================
# CONSTANTS MINIMUM VERSION
# =================================================================

readonly MIN_BASH_VERSION="4.0"
readonly MIN_DDEV_VERSION="1.21.0"
readonly MIN_DOCKER_VERSION="20.10"
readonly MIN_JQ_VERSION="1.5"

# =================================================================
# COMPARISON VERSION (semver)
# =================================================================

# Returns: 0 = equals, 1 = $1 > $2, 2 = $1 < $2
version_compare() {
    [[ "$1" == "$2" ]] && return 0

    local IFS='.'
    local i ver1 ver2

    read -ra ver1 <<< "$1"
    read -ra ver2 <<< "$2"

    # Alignment length arraies
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do ver2[i]=0; done

    for ((i=0; i<${#ver1[@]}; i++)); do
        if ((10#${ver1[i]:-0} > 10#${ver2[i]:-0})); then return 1; fi
        if ((10#${ver1[i]:-0} < 10#${ver2[i]:-0})); then return 2; fi
    done

    return 0
}

# Returns 0 (success), ifs $1 >= $2 (cross-platform via awk)
version_ge() {
    awk -v v1="$1" -v v2="$2" 'BEGIN {
        split(v1, a, "."); split(v2, b, ".");
        for (i=1; i<=3; i++) {
            if (a[i]+0 < b[i]+0) exit 1;
            if (a[i]+0 > b[i]+0) exit 0;
        }
        exit 0;
    }'
}

# Extract versions from lines
# Supports formats: "v1.23.4", "ddev v1.23.4", "1.23.4", "1.23"
# Can read and argument $1, and STDIN (for pipelines)
extract_version() {
    local input="${1:-$(cat)}"
    echo "$input" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# =================================================================
# CHECKS
# =================================================================

check_bash_version() {
    if (( BASH_VERSINFO[0] < 4 )); then
        print_error "Requires Bash >= ${MIN_BASH_VERSION}, current: ${BASH_VERSION:-unknown}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            print_info "macOS: install brew install bash and update PATH"
        fi
        return 1
    fi
    return 0
}

check_dependency() {
    local cmd="$1"
    local package="${2:-$1}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "Command '$cmd' not found. Install $package."
        return 1
    fi
    return 0
}

check_ddev() {
    if ! check_dependency "ddev" "DDEV"; then
        return 1
    fi

    local ddev_version_raw
    ddev_version_raw=$(ddev --version 2>/dev/null)
    if [[ -z "$ddev_version_raw" ]]; then
        print_error "DDEV is installed but did not return a version. Check the DDEV installation."
        return 1
    fi

    local ddev_version
    ddev_version=$(extract_version "$ddev_version_raw")

    if [[ -z "$ddev_version" ]]; then
        print_error "Unable to parse the installed DDEV version: $ddev_version_raw"
        return 1
    fi

    if version_ge "$ddev_version" "$MIN_DDEV_VERSION"; then
        print_info "DDEV version: $ddev_version ✓"
    else
        print_error "DDEV outdated: $ddev_version. Requires >= ${MIN_DDEV_VERSION}"
        return 1
    fi

    return 0
}

check_docker() {
    if ! check_dependency "docker" "Docker"; then
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running or is not responsive."
        case "$DPX_OS_TYPE" in
            macos) print_info "Start Docker Desktop for macOS, then retry." ;;
            linux) print_info "Start Docker with: sudo systemctl start docker" ;;
            *) print_info "Start Docker and retry." ;;
        esac
        return 1
    fi

    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null)

    if [[ -z "$docker_version" ]]; then
        print_error "Docker daemon not run ors unavailable!"
        case "$DPX_OS_TYPE" in
            macos) print_error "Start Docker Desktop for macOS" ;;
            linux) print_error "Try: sudo systemctl start docker" ;;
        esac
        return 1
    fi

    docker_version=$(extract_version "$docker_version")

    if version_ge "$docker_version" "$MIN_DOCKER_VERSION"; then
        print_info "Docker version: ${docker_version} ✓ (daemon running)"
    else
        print_error "Docker outdated: $docker_version. Requires >= ${MIN_DOCKER_VERSION}"
        return 1
    fi

    return 0
}

check_jq() {
    if ! check_dependency "jq" "jq (https://stedolan.github.io/jq/)"; then
        print_error "jq required for parsing JSON-output DDEV (ddev describe --format=json)."
        print_info "Install:"
        print_info "  Ubuntu/Debian: sudo apt install jq"
        print_info "  macOS:         brew install jq"
        return 1
    fi

    local jq_version
    jq_version=$(jq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

    if [[ -n "$jq_version" ]]; then
        if version_ge "$jq_version" "$MIN_JQ_VERSION"; then
            print_info "jq version: $jq_version ✓"
        else
            print_error "jq outdated: $jq_version. Requires >= ${MIN_JQ_VERSION}"
            return 1
        fi
    fi

    return 0
}

# =================================================================
# COMPLEX CHECK
# =================================================================

check_dependencies() {
    local has_errors=0
    local start_time
    start_time=$(date +%s)

    print_header "Pre-flight Checks"
    print_info "OS: ${DPX_OS_TYPE} (${OSTYPE:-unknown})"
    print_info "Bash: ${BASH_VERSION%% *}"

    check_bash_version || return 1
    print_info "Bash >= ${MIN_BASH_VERSION} ✓"

    # Basic utilities (jq for JSON, tar for SRDB/Devilbox)
    # Note: docker-compose checks separate (v1 binary vs v2 plugin)
    for cmd in sed grep awk curl tar jq; do
        check_dependency "$cmd" || has_errors=1
    done

    # docker compose: v2 (plugin docker compose) ors v1 (binary docker-compose)
    if docker compose version >/dev/null 2>&1; then
        print_info "docker compose (v2) ✓"
    elif command -v docker-compose >/dev/null 2>&1; then
        print_info "docker-compose (v1) ✓"
    else
        print_error "docker compose not found (neithers v2 plugin, neithers v1 binary)."
        has_errors=1
    fi

    echo ""
    check_docker || has_errors=1

    echo ""
    check_ddev || has_errors=1

    echo ""
    check_jq || has_errors=1

    local duration=$(( $(date +%s) - start_time ))
    echo ""

    if [[ $has_errors -eq 0 ]]; then
        print_success "All checks passed (${duration}s)"
    else
        print_error "Some checks failed"
    fi

    return $has_errors
}

command_requires_ddev() {
    case "$1" in
        ""|help|-h|--help|version|-v|--version|commands|config|update|info|clean)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# =================================================================
# EXPORT
# =================================================================

export MIN_BASH_VERSION MIN_DDEV_VERSION MIN_DOCKER_VERSION MIN_JQ_VERSION
# =================================================================
# NON-BLOCKING 24H UPDATE CHECK (v1.5.0)
#
#   * fetch runs in BACKGROUND (never blocks the command);
#   * comparison uses locally cached origin/main ref (cheap);
#   * cache file throttles the whole check to once per 24h;
#   * auto_update_check=false disables everything.
# =================================================================

UPDATE_CHECK_TTL=86400

update_cache_file() {
    printf '%s/.config/%s/.update_cache\n' "${HOME}" "$TOOL_NAME"
}

# True when cache is missing or older than TTL.
update_cache_expired() {
    local cache="$1" now="${2:-$(date +%s)}"
    [[ -f "$cache" ]] || return 0
    local ts
    ts="$(head -1 "$cache" 2>/dev/null | tr -d '[:space:]')"
    [[ "$ts" =~ ^[0-9]+$ ]] || return 0
    (( now - ts >= UPDATE_CHECK_TTL ))
}

update_touch_cache() {
    local cache="$1" behind="${2:-0}" now="${3:-$(date +%s)}"
    # [FIX P-11] Read-only home / sandboxed CI: creating the cache dir or
    # writing the cache file must never spray stderr noise across every
    # command. Skip silently when the parent is not writable.
    local cache_dir
    cache_dir="$(dirname "$cache")"
    if [[ ! -d "$cache_dir" && ! -w "$(dirname "$cache_dir")" ]]; then
        return 0
    fi
    if [[ -d "$cache_dir" && ! -w "$cache_dir" ]]; then
        return 0
    fi
    ensure_directory "$cache_dir" 2>/dev/null || return 0
    printf '%s\n%s\n' "$now" "$behind" > "$cache" 2>/dev/null || return 0
    return 0
}

update_read_behind() {
    local cache="$1"
    sed -n '2p' "$cache" 2>/dev/null | tr -d '[:space:]'
}

# Kick off a background fetch toward origin/main (fire-and-forget).
# [v1.5.2] `git fetch` WRITES .git/FETCH_HEAD + refs: a global install
# (/usr/local/bin/dpx owned by root) makes the dir read-only for the
# running user. Fetching anyway spawns a doomed child that prints
# nothing and stalls on credential prompts — skip it silently when
# .git (or FETCH_HEAD, when present) is not writable.
_update_bg_fetch() {
    local git_dir="${DPX_ROOT}/.git"

    [[ -d "$git_dir" ]] || return 0
    [[ -w "$git_dir" ]] || return 0
    [[ -e "${git_dir}/FETCH_HEAD" && ! -w "${git_dir}/FETCH_HEAD" ]] && return 0

    git -C "$DPX_ROOT" fetch origin main >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    return 0
}

# Count commits on origin/main that are absent locally.
_update_count_behind() {
    git -C "$DPX_ROOT" rev-list --count "HEAD..origin/main" 2>/dev/null || echo 0
}

# Main entry: call near the end of command execution.
# Maintenance (bg fetch + cache) runs even headless so CI keeps the
# cache warm; the visible banner requires a TTY unless
# DPX_FORCE_BANNER=1 (used by tests).
# Optional $1: explicit cache file path (tests / multi-env).
update_check_daily() {
    local cache="${1:-$(update_cache_file)}"

    [[ "$(get_config 'auto_update_check' 'true')" == "true" ]] || return 0
    [[ -d "${DPX_ROOT}/.git" ]] || return 0

    if update_cache_expired "$cache"; then
        _update_bg_fetch
        update_touch_cache "$cache" "$(update_read_behind "$cache")"
    fi

    local behind=0 live=""
    live="$(_update_count_behind)"
    [[ "$live" =~ ^[0-9]+$ ]] && behind="$live"
    update_touch_cache "$cache" "$behind"

    (( behind > 0 )) || return 0
    if [[ -t 1 || "${DPX_FORCE_BANNER:-}" == "1" ]]; then
        print_info "💡 $(t banner.update) (${DPX_VERSION})."
        return 10
    fi
    return 0
}

# =================================================================
# ORPHANED SNAPSHOT RECOVERY (v1.5.2)
#
# `dpx tunnel` records the pre-mutation ddev snapshot name in
# .dpx/current_snapshot and clears it in tunnel_cleanup. A kill -9 /
# system reboot skips the cleanup, leaving the database pointed at a
# dead tunnel URL. On boot we walk up from $PWD, detect the stale
# marker and offer to restore the snapshot (same mechanism as the
# tunnel rollback Plan A: `ddev snapshot restore`).
# =================================================================

# Walk up from $PWD looking for .dpx/current_snapshot.
# STDOUT: project root when found.
dpx_find_orphaned_snapshot() {
    local search_dir="${PWD}"
    while [[ -n "$search_dir" && "$search_dir" != "/" ]]; do
        if [[ -f "${search_dir}/.dpx/current_snapshot" ]]; then
            printf '%s\n' "$search_dir"
            return 0
        fi
        search_dir="${search_dir%/*}"
    done
    return 1
}

# True when a tunnel session for this project is STILL alive
# (.dpx/tunnel.pid written by cmd_tunnel, removed by tunnel_cleanup).
dpx_tunnel_session_alive() {
    local project_path="$1"
    local pid_file="${project_path}/.dpx/tunnel.pid"
    local pid

    [[ -f "$pid_file" ]] || return 1
    pid="$(head -1 "$pid_file" 2>/dev/null | tr -d '[:space:]')"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

dpx_restore_orphaned_snapshot() {
    local project_path="$1"
    local snap_name="$2"
    local snap_file="${project_path}/.dpx/current_snapshot"

    print_info "$(t orphan.restoring)"
    if (cd "$project_path" && ddev snapshot restore "$snap_name" 2>&1); then
        rm -f "$snap_file" "${project_path}/.dpx/tunnel.pid" 2>/dev/null
        print_success "$(t orphan.restored)"
        return 0
    fi

    # Restore failed: KEEP the marker so the state is not silently lost.
    print_error "$(t orphan.restore.failed)"
    print_info "dpx db restore"
    return 1
}

# Boot hook: interactive prompt / non-interactive log; never hangs.
check_orphaned_snapshot() {
    local project_path
    project_path="$(dpx_find_orphaned_snapshot)" || return 0

    dpx_tunnel_session_alive "$project_path" && return 0

    local snap_file="${project_path}/.dpx/current_snapshot"
    local snap_name
    snap_name="$(head -1 "$snap_file" 2>/dev/null | tr -d '[:space:]')"

    # Empty/corrupted marker carries nothing to restore — drop it.
    if [[ -z "$snap_name" ]]; then
        rm -f "$snap_file" 2>/dev/null
        return 0
    fi

    print_warning "$(t orphan.detected)"
    print_info "$(t orphan.snapshot) ${snap_name} ($(basename "$project_path"))"

    if [[ ! -t 0 ]]; then
        print_info "$(t orphan.noninteractive)"
        return 0
    fi

    confirm "$(t orphan.detected)" "n" || return 0

    dpx_restore_orphaned_snapshot "$project_path" "$snap_name"
}
