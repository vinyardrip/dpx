#!/usr/bin/env bash
# =================================================================
# DPX Command: ddev - Интерактивная обертка для команд DDEV
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/projects.sh"

show_ddev_help() {
    cat << EOF
 ${COLOR_BOLD}ddev${COLOR_RESET} - Интерактивная обертка для команд DDEV

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} ddev <команда_ddev> [аргументы...]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Бесшовная обертка над DDEV. 
    - Если вы находитесь внутри папки проекта, команда выполнится как обычно.
    - Если вы находитесь вне проекта, DPX покажет интерактивное меню выбора 
      проекта, перейдет в его папку и выполнит команду за вас.

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} ddev stop                   # Откроет меню (если вне папки), затем остановит проект
    ${TOOL_NAME} ddev exec wp cache flush    # Выполнит команду WP-CLI для выбранного проекта
    ${TOOL_NAME} ddev logs -f                # Покажет логи (с поддержкой любых флагов DDEV)
EOF
}

cmd_ddev() {
    # Если команда не передана или запрошена справка
    if [[ -z "$1" || "$1" == "--help" || "$1" == "-h" ]]; then
        show_ddev_help
        return 0
    fi

    # Сценарий 1: Мы УЖЕ находимся внутри папки проекта DDEV
    if [[ -f ".ddev/config.yaml" ]]; then
        # Просто прозрачно передаем все аргументы в оригинальный DDEV
        ddev "$@"
        return $?
    fi

    # Сценарий 2: Мы находимся ВНЕ папки проекта (нужно показать меню)
    local project_name
    project_name=$(projects_select_interactive "Вы вне директории проекта. Выберите проект для 'ddev $*'")
    
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    if [[ ! -d "$project_path" ]]; then
        print_error "Директория проекта не найдена: $project_path"
        return 1
    fi

    print_info "Переход в проект [$project_name] и выполнение: ddev $*"
    echo ""
    
    # Выполняем в изолированном subshell
    (
        cd "$project_path" || exit 1
        ddev "$@"
    )
}
