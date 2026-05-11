#!/usr/bin/env bash
# =================================================================
# DPX Command: to-prod - Подготовка БД к продакшену
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/devilbox.sh"
source "${DPX_ROOT}/lib/projects.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_to_prod_help() {
    cat << EOF
 ${COLOR_BOLD}to-prod${COLOR_RESET} - Подготовка локальной БД для продакшена

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} to-prod [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Экспортирует локальную БД с заменой URL на продакшен.
    Автоматически создаёт резервную копию в папке дампов.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя проекта DDEV
    --cms-type TYPE        Тип CMS (wordpress, joomla, opencart, php)
    --prod-url URL         Полный URL продакшена
    --prod-tld TLD         Доменная зона продакшена (по умолчанию: by)
    -y, --yes              Пропустить подтверждения
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} to-prod
    ${TOOL_NAME} to-prod --project-name mysite --prod-tld com -y
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_to_prod() {
    parse_args "$@" || return 1
    
    # Показать справку
    if has_arg "help"; then
        show_to_prod_help
        return 0
    fi
    
    print_header "Подготовка БД для продакшена v1.5.1"

    # --- Шаг 1: Выбор проекта ---
    local project_name
    project_name=$(projects_select_interactive "Выберите проект для экспорта на прод")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # --- Шаг 2: Тип CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")
    
    if [[ -z "$cms_type" ]]; then
        print_header "Тип CMS для [$project_name]"
        echo "1. WordPress | 2. Joomla | 3. OpenCart | 4. PHP"
        local choice
        read -r -p "Выберите [1]: " choice
        case "${choice:-1}" in
            1) cms_type="wordpress" ;;
            2) cms_type="joomla" ;;
            3) cms_type="opencart" ;;
            *) cms_type="php" ;;
        esac
    fi
    print_success "Выбран тип: $(get_cms_name "$cms_type")"

    # --- Шаг 3: Настройка URL ---
    local prod_tld prod_url
    prod_tld=$(get_arg "prod_tld" "$(get_config 'default_prod_tld')")
    prod_url=$(get_arg "prod_url" "")
    
    if [[ -z "$prod_url" ]]; then
        if ! has_arg "prod_tld"; then
            prompt_input "    Доменная зона продакшена (.by, .com, etc)" "$prod_tld" prod_tld
        fi
        
        local raw_domain="${project_name}.${prod_tld}"
        
        # [FIX] Очистка от протоколов если пользователь вставил полный URL
        raw_domain="${raw_domain#*//}"     # Удаляет всё до // включительно
        raw_domain="${raw_domain%%/*}"     # Удаляет всё после первого слэша
        raw_domain="${raw_domain%/}"       # Удаляет trailing slash
        
        local protocol_choice
        protocol_choice=$(prompt_choice "    Протокол продакшена" "https" "http")
        
        case "$protocol_choice" in
            https) prod_url="https://${raw_domain}" ;;
            http)  prod_url="http://${raw_domain}" ;;
        esac
    fi
    
    # [FIX] Очистка prod_url от двойных протоколов
    prod_url="${prod_url#*//}"
    prod_url="${prod_url%%/*}"
    prod_url="${prod_url%/}"
    case "$protocol_choice" in
        https) prod_url="https://${prod_url}" ;;
        http)  prod_url="http://${prod_url}" ;;
    esac

    local local_url="https://${project_name}.$(get_config 'project_tld')"

    # --- Шаг 4: Проверка статуса DDEV ---
    if ! ddev_is_project_running "$project_name"; then
        if confirm "Проект '$project_name' не запущен. Запустить?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Проект должен быть запущен для экспорта БД."
            return 1
        fi
    fi

    # --- Шаг 5: Подготовка имени файла ---
    local out_file
    out_file="$(get_db_prod_path)/$(db_generate_export_filename "$project_name" "TO_PROD")"

    # --- Подтверждение ---
    print_header "Проверьте параметры"
    echo "Проект:          ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Тип CMS:         ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "Локальный URL:   ${COLOR_YELLOW}${local_url}${COLOR_RESET}"
    echo "Продакшен URL:   ${COLOR_GREEN}${prod_url}${COLOR_RESET}"
    echo "Файл экспорта:   ${COLOR_GREEN}$(basename "$out_file")${COLOR_RESET}"
    print_separator
    
    if ! has_arg "yes"; then
        confirm "Начать экспорт?" || return 1
    fi

    devilbox_stop

    ensure_directory "$(get_db_prod_path)"

    # Изолируем смену директории в subshell
    (
        cd "$project_path" || exit 1

        if [[ "$cms_type" == "wordpress" ]]; then
            db_wp_export_safe "$out_file" "$local_url" "$prod_url" "$project_path"
        else
            # [FIX] stderr остаётся видимым для диагностики (только >/dev/null)
            if ddev export-db --file="$out_file" >/dev/null; then
                print_success "База экспортирована: $(basename "$out_file")"
            else
                print_error "Ошибка экспорта базы."
                exit 1
            fi
        fi
    ) || return 1

    # Ротация бэкапов
    core_rotate_backups "$project_name" "$(get_db_prod_path)" "TO_PROD"

    print_celebration "Готово! Файл в папке дампов."
}
