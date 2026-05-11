#!/usr/bin/env bash
# =================================================================
# DPX Command: edit - редактирование метаданных проекта
# Хранилище: ~/.config/dpx/projects.json
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_edit_help() {
    cat << EOF
 ${COLOR_BOLD}edit${COLOR_RESET} - Редактирование метаданных проекта

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} edit <проект> [опции]
    ${TOOL_NAME} edit [опции]  (интерактивный выбор проекта)

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Редактирует метаданные проекта: максимальную рабочую версию PHP,
    заметки и другие параметры.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --php-max VERSION   Установить максимальную рабочую версию PHP
    --notes "текст"     Добавить заметку к проекту
    --show              Показать текущие метаданные
    --delete            Удалить все метаданные проекта
    -h, --help          Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} edit mysite --php-max 8.2
    ${TOOL_NAME} edit --php-max 8.3
    ${TOOL_NAME} edit mysite --show
    ${TOOL_NAME} edit mysite --notes "На PHP 8.3 фатальная ошибка"
    ${TOOL_NAME} edit mysite --delete

 ${COLOR_BOLD}Workflow:${COLOR_RESET}
    1. ${TOOL_NAME} set-php mysite     # Тестируем разные версии PHP
    2. Сайт работает на PHP 8.2, на 8.3 падает
    3. ${TOOL_NAME} edit mysite --php-max 8.2  # Фиксируем результат
    4. ${TOOL_NAME} list              # Видим php_max в списке

 ${COLOR_BOLD}Хранилище:${COLOR_RESET}
    ~/.config/dpx/projects.json
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_edit() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_edit_help
        return 0
    fi

    # Получаем имя проекта
    local project_name
    project_name=$(get_positional_arg 1)

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Выберите проект для редактирования")
        [[ -z "$project_name" ]] && return 1
    fi

    # Проверяем существование проекта
    if ! projects_exists "$project_name"; then
        print_error "Проект '$project_name' не найден"
        return 1
    fi

    local project_path
    project_path=$(projects_get_path "$project_name")

    # --- ФЛАГ --show ---
    if has_arg "show"; then
        print_header "Метаданные: $project_name"

        local meta
        meta=$(dpx_meta_get_all "$project_name")

        if [[ -n "$meta" ]] && [[ "$meta" != "null" ]] && [[ "$meta" != "" ]]; then
            echo ""
            echo "$meta" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
            echo ""
            print_info "Файл: $(dpx_meta_file)"
        else
            print_warning "Метаданные не заданы"
        fi
        return 0
    fi

    # --- ФЛАГ --delete ---
    if has_arg "delete"; then
        print_header "Удаление метаданных: $project_name"

        if dpx_meta_exists "$project_name"; then
            if confirm "Удалить все метаданные проекта '$project_name'?"; then
                dpx_meta_delete "$project_name"
                print_success "Метаданные удалены"
            fi
        else
            print_warning "Метаданные не найдены"
        fi
        return 0
    fi

    # --- ФЛАГ --php-max ---
    local php_max
    php_max=$(get_arg "php_max" "")

    if [[ -n "$php_max" ]]; then
        if [[ ! "$php_max" =~ ^[0-9]+\.[0-9]+$ ]]; then
            print_error "Неверный формат версии PHP: $php_max"
            print_info "Ожидается формат: 8.2, 7.4, 8.3 и т.д."
            return 1
        fi

        local current_php
        current_php=$(projects_get_php_version "$project_name")

        # Получаем тип проекта из DDEV конфига
        local project_type
        project_type=$(grep -E "^type:" "${project_path}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

        print_header "Обновление метаданных: $project_name"
        echo ""
        printf "Тип проекта:           %s\n" "$project_type"
        printf "Текущая версия PHP:    %s\n" "$current_php"
        printf "Максимальная рабочая:  %s\n" "$php_max"
        echo ""

        if confirm "Записать php_max = $php_max?"; then
            dpx_meta_set "$project_name" "type" "$project_type"
            dpx_meta_set "$project_name" "php_max" "$php_max"
            dpx_meta_set "$project_name" "tested" "$(date +%Y-%m-%d)"
            print_success "Метаданные обновлены"
            echo ""
            print_info "Хранилище: $(dpx_meta_file)"
        fi
        return 0
    fi

    # --- ФЛАГ --notes ---
    local notes
    notes=$(get_arg "notes" "")

    if [[ -n "$notes" ]]; then
        dpx_meta_set "$project_name" "notes" "$notes"
        print_success "Заметка сохранена"
        return 0
    fi

    # --- ИНТЕРАКТИВНЫЙ РЕЖИМ ---
    print_header "Редактирование: $project_name"

    local current_php
    current_php=$(projects_get_php_version "$project_name")

    local saved_php_max
    saved_php_max=$(dpx_get_php_max "$project_name")

    local saved_notes
    saved_notes=$(dpx_get_notes "$project_name")

    local saved_tested
    saved_tested=$(dpx_get_tested "$project_name")

    echo ""
    printf "Текущая версия PHP:    %s\n" "$current_php"
    printf "Максимальная рабочая:  %s\n" "$saved_php_max"
    printf "Дата тестирования:     %s\n" "$saved_tested"
    printf "Заметки:               %s\n" "$saved_notes"
    echo ""

    echo "Выберите действие:"
    echo "  1. Установить php_max"
    echo "  2. Добавить заметку"
    echo "  3. Показать все метаданные"
    echo "  4. Удалить метаданные"
    echo "  0. Выход"
    echo ""

    local choice
    read -r -p "Ваш выбор: " choice

    case "$choice" in
        1)
            local new_php_max
            read -r -p "Введите максимальную рабочую версию PHP (например, 8.2): " new_php_max

            if [[ -n "$new_php_max" ]]; then
                if [[ ! "$new_php_max" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    print_error "Неверный формат версии"
                    return 1
                fi

                # Получаем тип проекта
                local project_type
                project_type=$(grep -E "^type:" "${project_path}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

                dpx_meta_set "$project_name" "type" "$project_type"
                dpx_meta_set "$project_name" "php_max" "$new_php_max"
                dpx_meta_set "$project_name" "tested" "$(date +%Y-%m-%d)"
                print_success "php_max = $new_php_max сохранено"
            fi
            ;;
        2)
            local new_notes
            read -r -p "Введите заметку: " new_notes

            if [[ -n "$new_notes" ]]; then
                dpx_meta_set "$project_name" "notes" "$new_notes"
                print_success "Заметка сохранена"
            fi
            ;;
        3)
            echo ""
            dpx_meta_get_all "$project_name" | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || print_warning "Метаданные не заданы"
            echo ""
            print_info "Файл: $(dpx_meta_file)"
            ;;
        4)
            if confirm "Удалить все метаданные проекта?"; then
                dpx_meta_delete "$project_name"
                print_success "Метаданные удалены"
            fi
            ;;
        0|*)
            print_info "Выход"
            ;;
    esac
}