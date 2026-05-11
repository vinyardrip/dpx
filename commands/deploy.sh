#!/usr/bin/env bash
# =================================================================
# DPX Command: deploy - развертывание существующего проекта на DDEV
# =================================================================

# Подключаем модули
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/devilbox.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_deploy_help() {
    cat << EOF
 ${COLOR_BOLD}deploy${COLOR_RESET} - Развертывание существующего проекта на DDEV

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} deploy [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Развертывает существующий проект на DDEV с импортом БД с продакшена.
    Автоматически настраивает конфигурацию CMS и заменяет URL.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя проекта (папки)
    --cms-type TYPE        Тип CMS (wordpress, joomla, opencart, php)
    --db-file FILE         Имя файла БД (без .sql)
    --prod-url URL         URL продакшен-сайта
    --php-version VERSION  Версия PHP (по умолчанию: 7.4)
    --db-type TYPE         Тип БД (mysql, mariadb)
    --db-version VERSION   Версия БД (по умолчанию: 5.7)
    -y, --yes              Пропустить подтверждения
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} deploy
    ${TOOL_NAME} deploy --project-name mysite --cms-type wordpress
    ${TOOL_NAME} deploy --project-name mysite --php-version 8.1 -y
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_deploy() {
    # Парсинг аргументов в глобальный массив
    parse_args "$@" || return 1

    # Показать справку
    if has_arg "help"; then
        show_deploy_help
        return 0
    fi

    print_header "Развертывание существующего проекта на DDEV"

    # --- Шаг 1: Выбор типа проекта ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")

    if [[ -z "$cms_type" ]]; then
        cms_type=$(select_cms_type "Выберите тип проекта") || return 1
    fi
    print_success "Выбран тип CMS: $(get_cms_name "$cms_type")"

    # --- Шаг 2: Ввод имени проекта ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Введите имя папки проекта (например, my-joomla-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    # Пути уже раскрыты в core.sh при load_config
    local ddev_projects_path
    ddev_projects_path=$(get_config "ddev_projects_base_path")
    local project_path="${ddev_projects_path}/${project_name}"

    validate_directory "$project_path" "Директория проекта" || return 1

    # --- Шаг 3: Проверка существующего проекта DDEV ---
    if ddev_project_exists "$project_name"; then
        print_warning "DDEV уже содержит данные для проекта '$project_name'."
        if has_arg "yes" || confirm "Удалить все существующие данные DDEV и начать заново?"; then
            ddev delete "$project_name" -y 2>&1
            print_success "Старые данные DDEV успешно удалены."
        else
            print_error "Развертывание отменено."
            return 1
        fi
    fi

    # --- Шаг 4: Ввод имени файла БД ---
    local db_filename
    db_filename=$(get_arg "db_file" "")

    if [[ -z "$db_filename" ]]; then
        prompt_input "2. Имя файла БД из '$(get_db_prod_path)' (без .sql)" "" db_filename
    fi
    validate_non_empty "$db_filename" "Имя файла БД" || return 1

    local source_db_file
    source_db_file=$(db_get_prod_filepath "$db_filename")
    validate_file "$source_db_file" "Файл базы данных" || return 1

    # --- Шаг 5: Ввод URL продакшена ---
    local prod_url
    prod_url=$(get_arg "prod_url" "")

    if [[ -z "$prod_url" ]]; then
        local raw_domain
        prompt_input "3. Домен продакшен-сайта (например, my-joomla-site.by)" "" raw_domain
        validate_non_empty "$raw_domain" "Домен" || return 1

        # [FIX] Очистка от протоколов и trailing slash
        # Пользователь может вставить https://mysite.com/ из браузера
        raw_domain="${raw_domain#*//}"     # Удаляет всё до // включительно (http://, https://)
        raw_domain="${raw_domain%%/*}"     # Удаляет всё после первого слэша (пути)
        raw_domain="${raw_domain%/}"       # Удаляет trailing slash если остался

        local protocol_choice
        protocol_choice=$(prompt_choice "   Выберите протокол" "https" "http")

        case "$protocol_choice" in
            https) prod_url="https://${raw_domain}" ;;
            http)  prod_url="http://${raw_domain}" ;;
        esac
    fi

    # --- Шаг 6: Дополнительные параметры ---
    local php_version db_type db_version
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")
    db_type=$(get_arg "db_type" "$(get_config 'default_db_type')")
    db_version=$(get_arg "db_version" "$(get_config 'default_db_version')")

    if ! has_arg "php_version"; then
        prompt_input "4. Версия PHP для DDEV" "$php_version" php_version
        prompt_input "5. Тип БД (mysql, mariadb)" "$db_type" db_type
        prompt_input "6. Версия БД (например, 5.7)" "$db_version" db_version
    fi

    local local_url="https://${project_name}.$(get_config "project_tld")"
    local ddev_project_type
    ddev_project_type=$(get_ddev_project_type "$cms_type")

    # --- Шаг 7: Подтверждение параметров ---
    print_header "Проверьте параметры"
    echo "Имя проекта:      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Тип CMS:          ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "Старый URL:       ${COLOR_YELLOW}${prod_url}${COLOR_RESET}"
    echo "Новый URL:        ${COLOR_GREEN}${local_url}${COLOR_RESET}"
    echo "Версия PHP:       ${COLOR_GREEN}${php_version}${COLOR_RESET}"
    echo "База данных:      ${COLOR_GREEN}${db_type}:${db_version}${COLOR_RESET}"
    print_separator

    if ! has_arg "yes"; then
        confirm "Все верно? Начинаем?" || return 1
    fi

    # [FIX] Останавливаем Devilbox ТОЛЬКО после подтверждения всех параметров
    # Это предотвращает остановку рабочей среды при ошибке ввода
    devilbox_stop

    # =================================================================
    #  Выполнение развертывания (в subshell для изоляции cd)
    # =================================================================

    (
        cd "$project_path" || exit 1

        # Шаг 1: Конфигурация DDEV
        ddev_configure_project "$project_name" "$ddev_project_type" "$php_version" "$db_type" "$db_version" "" "$(get_config "project_tld")" || exit 1

        # Шаг 2: Запуск проекта
        safe_start_ddev_project "$project_name" "$project_path" || exit 1

        # Шаг 3: Настройка конфигурационных файлов CMS
        configure_cms_for_ddev "$project_path" "$cms_type" "$local_url"

        # Шаги 4-5: Импорт и замена URL
        if uses_wp_cli_for_url_replace "$cms_type"; then
            # WordPress: импорт + WP-CLI замена
            print_step "4" "Импорт базы данных"
            db_import "$source_db_file" "$project_path" || exit 1

            print_step "5" "Замена URL в базе данных (WP-CLI)"
            ddev_wp_search_replace "$prod_url" "$local_url" "$project_path" || exit 1
        else
            # Joomla, OpenCart, etc: импорт с заменой URL в файле
            print_step "4-5" "Подготовка и импорт базы данных с заменой URL"
            db_import_with_replace "$source_db_file" "$prod_url" "$local_url" "$project_path" || exit 1
        fi

        # --- Завершение ---
        print_celebration "Проект успешно развернут!"
        print_highlight "Сайт доступен по адресу: ${local_url}"

        ddev_launch "$project_name"
    ) || return 1

    return 0
}