#!/usr/bin/env bash
# =================================================================
# DPX IO Module - output, color, formatting
#
# ARCHITECTURAL RULE (v1.4.3):
#   ALL functions print_* write in STDERR (>&2).
#   STDOUT reserved for data (echo/printf in function,
#   returning value via $(...)).
#   This prevents polluted variable ANSI-codes.
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_IO_LOADED:-}" ]] && return 0
readonly _DPX_IO_LOADED=1

# Locale-aware labels require the i18n module
source "${DPX_ROOT}/lib/i18n.sh"

# =================================================================
# INITIALIZATION COLORS
# =================================================================

_dpx_init_colors() {
    if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
        if command -v tput >/dev/null 2>&1; then
            COLOR_GREEN=$(tput setaf 2 2>/dev/null) || COLOR_GREEN=$'\033[0;32m'
            COLOR_YELLOW=$(tput setaf 3 2>/dev/null) || COLOR_YELLOW=$'\033[1;33m'
            COLOR_BLUE=$(tput setaf 4 2>/dev/null) || COLOR_BLUE=$'\033[0;34m'
            COLOR_RED=$(tput setaf 1 2>/dev/null) || COLOR_RED=$'\033[0;31m'
            COLOR_CYAN=$(tput setaf 6 2>/dev/null) || COLOR_CYAN=$'\033[0;36m'
            COLOR_MAGENTA=$(tput setaf 5 2>/dev/null) || COLOR_MAGENTA=$'\033[0;35m'
            COLOR_BOLD=$(tput bold 2>/dev/null) || COLOR_BOLD=$'\033[1m'
            COLOR_RESET=$(tput sgr0 2>/dev/null) || COLOR_RESET=$'\033[0m'
        else
            COLOR_GREEN=$'\033[0;32m'
            COLOR_YELLOW=$'\033[1;33m'
            COLOR_BLUE=$'\033[0;34m'
            COLOR_RED=$'\033[0;31m'
            COLOR_CYAN=$'\033[0;36m'
            COLOR_MAGENTA=$'\033[0;35m'
            COLOR_BOLD=$'\033[1m'
            COLOR_RESET=$'\033[0m'
        fi
    else
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_BLUE=""
        COLOR_RED=""
        COLOR_CYAN=""
        COLOR_MAGENTA=""
        COLOR_BOLD=""
        COLOR_RESET=""
    fi

    export COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_RED COLOR_CYAN COLOR_MAGENTA COLOR_BOLD COLOR_RESET
}
_dpx_init_colors

# =================================================================
# FUNCTIONS OUTPUT — all write in STDERR (>&2)
# =================================================================

print_header() {
    printf '\n%s--- %s ---%s\n' "$COLOR_BLUE" "$1" "$COLOR_RESET" >&2
}

print_success() {
    printf '%s✔ %s%s\n' "$COLOR_GREEN" "$1" "$COLOR_RESET" >&2
}

print_warning() {
    printf '%s%s: %s%s\n' "$COLOR_YELLOW" "$(t lbl.warning)" "$1" "$COLOR_RESET" >&2
}

print_error() {
    printf '%s%s: %s%s\n' "$COLOR_RED" "$(t lbl.error)" "$1" "$COLOR_RESET" >&2
}

print_info() {
    printf '%s%s%s\n' "$COLOR_CYAN" "$1" "$COLOR_RESET" >&2
}

print_highlight() {
    printf '%s%s%s\n' "$COLOR_YELLOW" "$1" "$COLOR_RESET" >&2
}

print_step() {
    printf '\n%s%s %s: %s...%s\n' "$COLOR_BLUE" "$(t lbl.step)" "$1" "$2" "$COLOR_RESET" >&2
}

print_separator() {
    echo "------------------------------------------------" >&2
}

print_celebration() {
    printf '\n%s🎉 %s 🎉%s\n' "$COLOR_GREEN" "$1" "$COLOR_RESET" >&2
}

print_fatal() {
    printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$COLOR_RED" "$COLOR_RESET" >&2
    printf '%sFATAL: %s%s\n' "$COLOR_BOLD$COLOR_RED" "$1" "$COLOR_RESET" >&2
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$COLOR_RED" "$COLOR_RESET" >&2
}
