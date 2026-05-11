#!/usr/bin/env bash
# =================================================================
# DPX Command: refresh - обновление локальной БД данными с продакшена
# =================================================================

# Подключаем модули
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/devilbox.sh"
source "${DPX_ROOT}/lib/projects.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_refresh_help() {
    cat << EOF
 ${COLOR_BOLD}refresh${COLOR_RESET} - Обновление локальной БД данными с продакшена

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} refresh [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Обновляет локальную БД свежим дампом с продакшена.
    Автоматически создаёт резервную копию текущей локальной БД.
    Заменяет URL с продакшена на локальные.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя проекта DDEV
    --cms-type TYPE        Тип CMS (wordpress, joomla, opencart, php)
    --db-file FILE         Имя файла БД (без .sql)
    --prod-url URL         URL продакшен-сайта
    --prod-tld TLD         Доменная зона продакшена (по умолчанию: by)
    --no-backup            Не создавать резервную копию
    -y, --yes              Пропустить подтверждения
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} refresh
    ${TOOL_NAME} refresh --project-name mysite --db-file mysite_prod
    ${TOOL_NAME} refresh --project-name mysite --prod-url https://mysite.com -y
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_refresh() {
    # Парсинг аргументов в глобальный массив
    parse_args "$@" || return 1

    # Показать справку
    if has_arg "help"; then
        show_refresh_help
        return 0
    fi

    print_header "Обновление локальной БД с продакшена"

    # --- Шаг 1: Выбор типа CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")

    if [[ -z "$cms_type" ]]; then
        cms_type=$(select_cms_type "Выберите тип проекта для обновления") || return 1
    fi
    print_success "Выбран тип: $(get_cms_name "$cms_type")"

    # --- Шаг 2: Имя проекта ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Выберите проект для обновления")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    # [FIX] Пути уже раскрыты в core.sh при load_config
    local project_path
    project_path=$(projects_get_path "$project_name")

    validate_directory "$project_path" "Директория проекта" || return 1

    # --- Шаг 3: Доменная зона продакшена ---
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
        protocol_choice=$(prompt_choice "3. Выберите протокол продакшена" "https" "http")

        case "$protocol_choice" in
            https) prod_url="https://${raw_domain}" ;;
            http)  prod_url="http://${raw_domain}" ;;
        esac
    fi

    local local_url="https://${project_name}.$(get_config "project_tld")"

    # --- Шаг 4: Проверка статуса проекта ---
    print_info "Проверяем статус проекта '$project_name'..."
    if ! ddev_is_project_running "$project_name"; then
        print_warning "Проект '$project_name' не запущен."
        if has_arg "yes" || confirm "Запустить его сейчас?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Операция отменена."
            return 1
        fi
    fi
    print_success "Проект запущен и готов к работе."

    # --- Шаг 5: Имя файла БД ---
    local db_filename
    db_filename=$(get_arg "db_file" "")

    if [[ -z "$db_filename" ]]; then
        prompt_input "2. Имя файла БД из '$(get_db_prod_path)' (без .sql)" "$project_name" db_filename
    fi

    local source_db_file
    source_db_file=$(db_get_prod_filepath "$db_filename")
    validate_file "$source_db_file" "Файл базы данных с продакшена" || return 1

    # =================================================================
    #  ОБЯЗАТЕЛЬНОЕ РЕЗЕРВНОЕ КОПИРОВАНИЕ
    # =================================================================

    local backup_file=""
    if ! has_arg "no_backup"; then
        backup_file=$(db_backup_local "$project_name" "$project_path")

        if [[ -z "$backup_file" ]]; then
            print_warning "Не удалось создать резервную копию."
            if ! confirm "Продолжить без резервной копии?"; then
                return 1
            fi
        fi
    fi

    # --- Подтверждение ---
    print_header "Проверьте параметры"
    echo "Проект для обновления:      ${COLOR_GREEN}${project_name} ($(get_cms_name "$cms_type"))${COLOR_RESET}"
    echo "Источник данных (прод):     ${COLOR_GREEN}${source_db_file}${COLOR_RESET}"
    if [[ -n "$backup_file" ]]; then
        echo "Резервная копия:            ${COLOR_GREEN}${backup_file}${COLOR_RESET}"
    fi
    print_separator
    print_warning "Текущая локальная база данных проекта '$project_name' будет ПОЛНОСТЬЮ ПЕРЕЗАПИСАНА!"

    if ! has_arg "yes"; then
        confirm "Продолжить обновление?" || return 1
    fi

    # [FIX] Останавливаем Devilbox ТОЛЬКО после подтверждения
    devilbox_stop

    # =================================================================
    #  Процесс обновления (в subshell для изоляции cd)
    # =================================================================

    (
        cd "$project_path" || exit 1

        if uses_wp_cli_for_url_replace "$cms_type"; then
            # --- WordPress ---
            print_step "2" "Импорт продакшен-дампа в DDEV"
            db_import "$source_db_file" "$project_path" || exit 1

            print_step "3" "Замена URL на локальные значения (WP-CLI)"
            ddev_wp_search_replace "$prod_url" "$local_url" "$project_path" || exit 1
        else
            # --- Joomla, OpenCart, другие PHP проекты ---
            print_step "2-3" "Подготовка и импорт базы данных с заменой URL"
            db_import_with_replace "$source_db_file" "$prod_url" "$local_url" "$project_path" || exit 1
        fi

        # --- Завершение ---
        print_celebration "Готово!"
        print_highlight "Локальный сайт '$project_name' успешно обновлен данными с продакшена."
        print_highlight "Он доступен по адресу: ${local_url}"

        ddev_launch "$project_name"
    ) || return 1

    return 0
}