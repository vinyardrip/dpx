#!/usr/bin/env bash
# =================================================================
# DPX Command: new-wp - создание нового WordPress проекта
#
# [v1.7.0] ОБРАТНАЯ СОВМЕСТИМОСТЬ: тонкая обертка над
#   dpx new --cms=wordpress
# Вся логика каркаса живет в commands/new.sh (_new_scaffold_wordpress).
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
# Универсальный движок: определяет cmd_new и show_new_help
source "${DPX_ROOT}/commands/new.sh"

show_new_wp_help() {
    show_new_help
    cat << EOF

 ${COLOR_BOLD}Примечание:${COLOR_RESET} команда 'new-wp' сохранена для совместимости и
 эквивалентна '${TOOL_NAME} new --cms=wordpress'. Специфичные опции WP
 (--locale, --admin-user/pass/email, --no-theme) передаются сквозь.
EOF
}

cmd_new_wp() {
    # Делегируем в универсальный движок, добавив тип только если
    # пользователь не указал свой (--cms/--type в любой форме).
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
