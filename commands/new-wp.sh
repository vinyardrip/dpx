#!/usr/bin/env bash
# =================================================================
# DPX Command: new-wp - create new WordPress project
#
# [v1.7.0] REVERSE COMPATIBILITY: subtle wrapper over
#   dpx new --cms=wordpress
# All logic scaffold lives in command/new.sh (_new_scaffold_wordpress).
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
# Universal engine: detects cmd_new and show_new_help
source "${DPX_ROOT}/commands/new.sh"

show_new_wp_help() {
    show_new_help
    cat << EOF

 ${COLOR_BOLD}Note:${COLOR_RESET} command 'new-wp' saved for compatibilities and
 equivalent '${TOOL_NAME} new --cms=wordpress'. Specific options WP
 (--locale, --admin-user/pass/email, --no-theme) pass through.
EOF
}

cmd_new_wp() {
    # Delegate in universal engine, adding type only ifs
    # user not specified with (--cms/--type in any form).
    local arg has_cms=false
    for arg in "$@"; do
        case "$arg" in
            --cms|--cms=*|--type|--type=*) has_cms=true ;;
        esac
    done

    if [[ "$has_cms" == "false" ]]; then
        set -- "$@" "--cms=wordpress"
    fi

    cmd_new "$@"
}
