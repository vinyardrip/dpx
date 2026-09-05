#!/usr/bin/env bash
# =================================================================
# DPX Domain Map - two-level command namespace (site/db) with
# backward-compatible top-level aliases.
#
# Contract:
#   domain_resolve DOMAIN SUB -> prints the canonical top-level
#   command name (e.g. "refresh"); returns 1 for unknown pairs.
#   domain_command_file NAME  -> optional override path for commands
#   living outside the flat commands/ layout (empty = default).
#
# Legacy top-level commands stay registered in the router and point
# to identical implementations, so `dpx refresh` and `dpx db pull`
# are interchangeable.
# =================================================================

[[ -n "${_DPX_DOMAIN_MAP_LOADED:-}" ]] && return 0
readonly _DPX_DOMAIN_MAP_LOADED=1

# Используются через nameref в domain_resolve(); shellcheck их не видит.
# shellcheck disable=SC2034
declare -Ar DOMAIN_DB=(
    ["pull"]="refresh"
    ["push"]="to-prod"
    ["snap"]="db-snap"
    ["restore"]="db-restore"
)

# shellcheck disable=SC2034
declare -Ar DOMAIN_SITE=(
    ["new"]="new"
    ["backup"]="backup"
    ["restore"]="restore"
    ["migrate"]="migrate"
    ["deploy"]="deploy"
)

domain_resolve() {
    local domain="$1" sub="$2"
    local -n ref
    case "$domain" in
        db)   ref="DOMAIN_DB" ;;
        site) ref="DOMAIN_SITE" ;;
        *) return 1 ;;
    esac
    [[ -n "${ref[$sub]:-}" ]] || return 1
    printf '%s\n' "${ref[$sub]}"
}

# File-path override for commands living outside the flat layout.
# Empty output = default commands/<name>.sh applies.
domain_command_file() {
    case "$1" in
        restore) printf '%s\n' "${DPX_ROOT}/commands/site/restore.sh" ;;
    esac
}

domain_usage() {
    local domain="$1"
    case "$domain" in
        db)   print_info "$(t dom.db.usage)" ;;
        site) print_info "$(t dom.site.usage)" ;;
        *)    print_info "$(t dom.db.usage)" ;;
    esac
}
