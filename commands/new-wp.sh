#!/usr/bin/env bash
# =================================================================
# DPX Command: new-wp - создание нового WordPress проекта с нуля
# =================================================================

# Подключаем модули
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/devilbox.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_new_wp_help() {
    cat << EOF
 ${COLOR_BOLD}new-wp${COLOR_RESET} - Создание нового WordPress проекта на DDEV

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} new-wp [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Создаёт новый WordPress проект с нуля:
    - Настраивает DDEV
    - Устанавливает WordPress через WP-CLI
    - Копирует и активирует стартовую тему (опционально)
    - Удаляет стандартные темы и плагины

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя нового проекта
    --php-version VERSION  Версия PHP (по умолчанию: 7.4)
    --locale LOCALE        Локаль WordPress (по умолчанию: ru_RU)
    --admin-user USER      Логин администратора (по умолчанию: admin)
    --admin-pass PASS      Пароль администратора (по умолчанию: admin)
    --admin-email EMAIL    Email администратора
    --no-theme             Не копировать стартовую тему
    -y, --yes              Пропустить подтверждения
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} new-wp
    ${TOOL_NAME} new-wp --project-name newsite --php-version 8.1
    ${TOOL_NAME} new-wp --project-name newsite --admin-user developer --admin-pass secret123 -y
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_new_wp() {
    # Парсинг аргументов в глобальный массив
    parse_args "$@" || return 1

    # Показать справку
    if has_arg "help"; then
        show_new_wp_help
        return 0
    fi

    print_header "Создание нового проекта WordPress"

    # --- Шаг 1: Имя проекта ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Введите имя нового проекта (например, my-cool-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    # [FIX] Пути уже раскрыты в core.sh при load_config
    local ddev_projects_path
    ddev_projects_path=$(get_config "ddev_projects_base_path")

    local project_path="${ddev_projects_path}/${project_name}"
    local site_url="https://${project_name}.$(get_config "project_tld")"

    # Проверка существования директории
    if [[ -d "$project_path" ]]; then
        print_warning "Директория '$project_path' уже существует."
        print_error "Операция отменена."
        return 1
    fi

    # --- Шаг 2: Дополнительные параметры ---
    local php_version locale admin_user admin_pass admin_email use_theme
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")
    locale=$(get_arg "locale" "ru_RU")
    admin_user=$(get_arg "admin_user" "$(get_config 'admin_user')")
    admin_pass=$(get_arg "admin_pass" "$(get_config 'admin_pass')")
    admin_email=$(get_arg "admin_email" "$(get_config 'admin_email')")
    use_theme="yes"

    if has_arg "no_theme"; then
        use_theme="no"
    fi

    if ! has_arg "project_name"; then
        prompt_input "2. Версия PHP для DDEV" "$php_version" php_version
    fi

    # --- Шаг 3: Подтверждение ---
    print_header "Проверьте параметры"
    echo "Имя проекта:      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "URL сайта:        ${COLOR_GREEN}${site_url}${COLOR_RESET}"
    echo "Версия PHP:       ${COLOR_GREEN}${php_version}${COLOR_RESET}"
    echo "Локаль WP:        ${COLOR_GREEN}${locale}${COLOR_RESET}"
    echo "Админ логин:      ${COLOR_GREEN}${admin_user}${COLOR_RESET}"
    echo "Путь к файлам:    ${COLOR_GREEN}${project_path}${COLOR_RESET}"
    print_separator

    if ! has_arg "yes"; then
        confirm "Создать проект?" || return 1
    fi

    # [FIX] Останавливаем Devilbox ТОЛЬКО после подтверждения
    devilbox_stop

    # =================================================================
    #  Создание проекта
    # =================================================================

    print_success "Начинаем создание проекта '${project_name}'..."

    # Шаг 1: Создание директории
    print_step "1" "Создание директории проекта"
    mkdir -p "$project_path"
    cd "$project_path" || return 1

    # Шаг 2: Конфигурация DDEV
    print_step "2" "Конфигурация и запуск DDEV"
    if ! ddev config --project-type wordpress --docroot "" --project-tld "$(get_config "project_tld")" --php-version "$php_version" 2>&1; then
        print_error "Ошибка конфигурации DDEV"
        rm -rf "$project_path"
        return 1
    fi

    # Запуск с проверкой конфликтов портов
    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Ошибка запуска DDEV"
        rm -rf "$project_path"
        return 1
    fi

    # Шаг 3: Установка WordPress
    if ! ddev_wp_install "$project_path" "$site_url" "Новый сайт ${project_name}" "$admin_user" "$admin_pass" "$admin_email" "$locale"; then
        print_error "Ошибка установки WordPress"
        return 1
    fi

    # Шаг 4: Копирование стартовой темы
    # [FIX] Пути уже раскрыты в core.sh при load_config
    local starter_theme_path
    starter_theme_path=$(get_config "starter_theme_path")

    if [[ "$use_theme" == "yes" ]] && [[ -d "$starter_theme_path" ]]; then
        print_step "4" "Копирование и активация стартовой темы '${project_name}'"

        local theme_dir="wp-content/themes/${project_name}"
        cp -r "${starter_theme_path}/." "$theme_dir"

        # Создание style.css если не существует
        if [[ ! -f "${theme_dir}/style.css" ]]; then
            cat > "${theme_dir}/style.css" << EOF
/*
Theme Name: ${project_name}
Author: Auto-generated by ${TOOL_NAME}
Version: 1.0
*/
EOF
            print_success "Файл style.css создан автоматически."
        fi

        ddev wp theme activate "$project_name" 2>&1 || {
            print_warning "Не удалось активировать тему."
        }

        # Удаление стандартных тем
        print_success "Удаление стандартных тем для чистоты проекта..."
        ddev_wp_theme_delete "twentytwentytwo twentytwentythree twentytwentyfour" "$project_path"
    else
        if [[ "$use_theme" == "yes" ]]; then
            print_warning "Путь к стартовой теме не указан или не существует. Шаг пропущен."
        fi
    fi

    # Шаг 5: Очистка стандартных плагинов
    print_step "5" "Очистка стандартных плагинов"
    ddev_wp_plugin_delete "akismet hello" "$project_path"

    # --- Завершение ---
    print_celebration "Проект '${project_name}' успешно создан!"
    print_separator
    print_highlight "Сайт доступен:     ${site_url}"
    print_highlight "Админ-панель:      ${site_url}/wp-admin/"
    print_highlight "Логин:             ${admin_user}"
    print_highlight "Пароль:            ${admin_pass}"
    print_highlight "Путь к файлам:     ${project_path}"
    print_separator

    ddev_launch "$project_name"

    return 0
}