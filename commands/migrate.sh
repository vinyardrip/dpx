#!/usr/bin/env bash
# =================================================================
# DPX Command: migrate - миграция проекта с Devilbox на DDEV
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

show_migrate_help() {
    cat << EOF
 ${COLOR_BOLD}migrate${COLOR_RESET} - Миграция проекта с Devilbox на DDEV

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} migrate [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Переносит существующий проект из Devilbox в DDEV:
    - Копирует файлы проекта
    - Экспортирует БД из Devilbox
    - Настраивает конфигурацию CMS для DDEV
    - Импортирует БД с заменой URL

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME        Имя проекта для DDEV
    --devilbox-folder FOLDER   Имя папки проекта в Devilbox/data
    --cms-type TYPE            Тип CMS (wordpress, joomla, opencart, php)
    --php-version VERSION      Версия PHP для DDEV (по умолчанию: 7.4)
    --devilbox-php VERSION     Версия PHP Devilbox для экспорта (по умолчанию: 7)
    --db-name NAME             Имя БД в Devilbox
    --db-type TYPE             Тип БД для DDEV (mysql, mariadb)
    --db-version VERSION       Версия БД для DDEV (по умолчанию: 5.7)
    --no-db                    Проект без базы данных
    --keep-backup              Не удалять файл бэкапа БД
    -y, --yes                  Пропустить подтверждения
    -h, --help                 Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} migrate
    ${TOOL_NAME} migrate --project-name mysite --devilbox-folder mysite-old
    ${TOOL_NAME} migrate --project-name mysite --cms-type wordpress --php-version 8.1 -y
    ${TOOL_NAME} migrate --project-name mysite --no-db  # без базы данных
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_migrate() {
    # Парсинг аргументов в глобальный массив
    parse_args "$@" || return 1

    # Показать справку
    if has_arg "help"; then
        show_migrate_help
        return 0
    fi

    print_header "Миграция проекта с Devilbox на DDEV"

    # =================================================================
    #  Шаг 1: Выбор типа проекта
    # =================================================================
    local cms_type has_db=true

    if has_arg "no_db"; then
        has_db=false
        cms_type="php"
    else
        cms_type=$(get_arg "cms_type" "")
        if [[ -z "$cms_type" ]]; then
            print_header "Выбор типа проекта"
            echo "1. WordPress"
            echo "2. Joomla"
            echo "3. OpenCart"
            echo "4. Чистый PHP/HTML (без базы данных)"

            local choice
            read -r -p "Выберите [1]: " choice
            choice="${choice:-1}"

            case "$choice" in
                1) cms_type="wordpress"; has_db=true ;;
                2) cms_type="joomla"; has_db=true ;;
                3) cms_type="opencart"; has_db=true ;;
                4) cms_type="php"; has_db=false ;;
                *) print_error "Неверный выбор."; return 1 ;;
            esac
        fi
    fi

    local ddev_project_type
    ddev_project_type=$(get_ddev_project_type "$cms_type")
    print_success "Выбран тип CMS: $(get_cms_name "$cms_type") (для DDEV: $ddev_project_type)"

    # =================================================================
    #  Шаг 2: Ввод параметров проекта
    # =================================================================
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Имя проекта для DDEV (например, my-new-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    # [FIX] Пути уже раскрыты в core.sh при load_config
    local ddev_projects_path
    ddev_projects_path=$(get_config "ddev_projects_base_path")
    local ddev_path="${ddev_projects_path}/${project_name}"

    # Проверка существования директории
    if [[ -d "$ddev_path" ]]; then
        print_warning "Директория проекта '$ddev_path' уже существует."
        if has_arg "yes" || confirm "Удалить её и ВСЕ данные DDEV для этого проекта?"; then
            ddev delete "$project_name" -y 2>/dev/null || true
            rm -rf "$ddev_path"
            print_success "Проект и его данные удалены."
        else
            print_error "Миграция отменена."
            return 1
        fi
    fi

    # Папка проекта в Devilbox
    local devilbox_folder
    devilbox_folder=$(get_arg "devilbox_folder" "")

    if [[ -z "$devilbox_folder" ]]; then
        # Показать доступные проекты
        print_info "Доступные проекты в Devilbox/data:"
        devilbox_list_projects | head -20
        echo ""
        prompt_input "2. Имя папки проекта в Devilbox/data" "" devilbox_folder
    fi
    validate_non_empty "$devilbox_folder" "Имя папки Devilbox" || return 1

    local devilbox_project_path
    devilbox_project_path=$(get_devilbox_project_path "$devilbox_folder")

    if ! validate_directory "$devilbox_project_path" "Исходная директория Devilbox"; then
        return 1
    fi

    # Версия PHP
    local php_version
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")

    if ! has_arg "php_version"; then
        prompt_input "3. Версия PHP для DDEV" "$php_version" php_version
    fi

    # Параметры БД
    local db_type db_version devilbox_php_version db_name
    db_type=$(get_arg "db_type" "$(get_config 'default_db_type')")
    db_version=$(get_arg "db_version" "$(get_config 'default_db_version')")
    devilbox_php_version=$(get_arg "devilbox_php" "7")
    db_name=$(get_arg "db_name" "")

    if [[ "$has_db" == true ]]; then
        if ! has_arg "devilbox_php"; then
            prompt_input "4. Версия PHP Devilbox для экспорта БД" "$devilbox_php_version" devilbox_php_version
        fi
        if ! has_arg "db_type"; then
            prompt_input "5. Тип БД для DDEV (mysql, mariadb)" "$db_type" db_type
        fi
        if ! has_arg "db_version"; then
            prompt_input "6. Версия БД для DDEV" "$db_version" db_version
        fi

        print_header "Учетные данные БД в Devilbox"
        if [[ -z "$db_name" ]]; then
            prompt_input "Имя БД в Devilbox" "" db_name
        fi
        validate_non_empty "$db_name" "Имя БД" || return 1

        print_success "Используются стандартные учетные данные: user: root, password: (пустой)"
    fi

    # =================================================================
    #  Формирование URL
    # =================================================================
    local local_url="https://${project_name}.$(get_config "project_tld")"
    local old_url="https://${devilbox_folder}.loc"

    # [FIX] Пути уже раскрыты в core.sh при load_config
    local db_backup_path
    db_backup_path=$(get_config "db_local_path")
    local backup_file="${db_backup_path}/db_${project_name}.sql"

    # =================================================================
    #  Подтверждение параметров
    # =================================================================
    print_header "Проверьте параметры"
    echo "Имя проекта DDEV:    ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Папка Devilbox:      ${COLOR_GREEN}${devilbox_folder}${COLOR_RESET}"
    echo "Тип CMS:             ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "Версия PHP (DDEV):   ${COLOR_GREEN}${php_version}${COLOR_RESET}"

    if [[ "$has_db" == true ]]; then
        echo "БД в Devilbox:       ${COLOR_GREEN}${db_name}${COLOR_RESET}"
        echo "БД для DDEV:         ${COLOR_GREEN}${db_type}:${db_version}${COLOR_RESET}"
        echo "Старый URL:          ${COLOR_YELLOW}${old_url}${COLOR_RESET}"
        echo "Новый URL:           ${COLOR_GREEN}${local_url}${COLOR_RESET}"
        echo "Файл бэкапа:         ${COLOR_GREEN}${backup_file}${COLOR_RESET}"
    fi

    print_separator

    if ! has_arg "yes"; then
        confirm "Продолжить миграцию?" || return 1
    fi

    # =================================================================
    #  Выполнение миграции
    # =================================================================

    # Шаг 1: Подготовка окружения
    print_header "Подготовка окружения"
    print_info "Останавливаем DDEV, чтобы освободить ресурсы для Devilbox..."
    ddev poweroff 2>&1 || true
    print_success "DDEV остановлен."

    # Шаг 2: Экспорт БД из Devilbox (если нужна)
    local devilbox_path
    devilbox_path=$(get_devilbox_path)

    if [[ "$has_db" == true ]]; then
        print_step "1" "Экспорт базы данных из Devilbox"

        # Работа с Devilbox в subshell
        (
            cd "$devilbox_path" || exit 1

            # Переключение на нужную версию PHP
            if [[ -f ".env" ]]; then
                mv .env env.bak 2>/dev/null || true
            fi

            if [[ -f ".env-${devilbox_php_version}" ]]; then
                mv ".env-${devilbox_php_version}" .env
            else
                print_warning "Файл .env-${devilbox_php_version} не найден"
            fi

            # Запуск сервисов
            dpx_docker_compose up -d httpd php mysql 2>&1
            print_info "Ожидание запуска сервисов..."
            sleep 15

            # Экспорт БД
            ensure_directory "$db_backup_path"
            dpx_docker_compose exec -T mysql mysqldump -u root "$db_name" > "$backup_file" 2>&1
            print_success "База данных успешно экспортирована."

            # Замена URL для не-WordPress (WordPress заменит через WP-CLI)
            if [[ "$cms_type" != "wordpress" ]]; then
                print_step "2" "Замена URL в SQL-файле"
                safe_sed_inplace "s|${old_url}|${local_url}|g" "$backup_file"
                # Удаляем backup файл от BSD sed
                rm -f "${backup_file}${DPX_SED_INPLACE_EXT}" 2>/dev/null || true
                print_success "URL заменены."
            fi
        ) || return 1
    fi

    # Шаг 3: Копирование файлов
    local step_num=3
    if [[ "$has_db" != true ]]; then
        step_num=1
    elif [[ "$cms_type" == "wordpress" ]]; then
        step_num=3
    else
        step_num=3
    fi

    print_step "$step_num" "Копирование файлов проекта"
    mkdir -p "$ddev_path"
    cp -R "$devilbox_project_path/." "$ddev_path"
    print_success "Файлы скопированы."

    # Шаг 4: Конфигурация DDEV (в subshell)
    ((step_num++))
    print_step "$step_num" "Конфигурация DDEV"

    (
        cd "$ddev_path" || exit 1

        if [[ "$has_db" == true ]]; then
            ddev config --project-name "$project_name" --project-type "$ddev_project_type" \
                --php-version "$php_version" --database "${db_type}:${db_version}" \
                --docroot "" --webserver-type apache-fpm --project-tld "$(get_config "project_tld")" 2>&1
        else
            ddev config --project-name "$project_name" --project-type "$ddev_project_type" \
                --php-version "$php_version" --disable-settings-management \
                --docroot "" --webserver-type apache-fpm --project-tld "$(get_config "project_tld")" 2>&1
        fi
    ) || return 1

    print_success "Конфигурация DDEV создана."

    # Шаг 5: Настройка конфигурационных файлов CMS
    if [[ "$has_db" == true ]]; then
        ((step_num++))
        configure_cms_for_ddev "$ddev_path" "$cms_type" "$local_url"
    fi

    # Шаг 6: Освобождение портов и запуск DDEV
    if [[ "$has_db" == true ]]; then
        print_header "Освобождение портов"
        print_info "Останавливаем Devilbox перед запуском DDEV..."
        (cd "$devilbox_path" && dpx_docker_compose down >/dev/null 2>&1)
        print_success "Devilbox успешно остановлен."
    fi

    ((step_num++))
    print_step "$step_num" "Запуск DDEV"

    (
        cd "$ddev_path" || exit 1
        ddev start -y 2>&1
    ) || return 1

    print_success "Проект запущен."

    # Шаг 7: Импорт БД
    if [[ "$has_db" == true ]]; then
        print_info "Импорт базы данных..."

        (
            cd "$ddev_path" || exit 1
            ddev import-db --file="$backup_file" 2>&1
        ) || return 1

        print_success "База данных импортирована."

        # Шаг 8: Замена URL для WordPress
        if [[ "$cms_type" == "wordpress" ]]; then
            ((step_num++))
            print_step "$step_num" "Автоматическая замена URL (WP-CLI)"

            (
                cd "$ddev_path" || exit 1
                ddev exec "wp search-replace '$old_url' '$local_url' --all-tables --allow-root" 2>&1
            ) || return 1

            print_success "URL успешно заменены."
        fi
    fi

    # Финальный шаг: удаление бэкапа
    if [[ "$has_db" == true ]] && ! has_arg "keep_backup"; then
        print_header "Финальный шаг"
        if has_arg "yes" || confirm "Удалить файл бэкапа ($backup_file)?" "n"; then
            rm -f "$backup_file"
            print_success "Файл удалён."
        else
            print_info "Файл сохранён: $backup_file"
        fi
    fi

    # Восстановление конфигурации Devilbox (в subshell)
    if [[ "$has_db" == true ]] && [[ -f "${devilbox_path}/env.bak" ]]; then
        (
            cd "$devilbox_path" || exit 1
            mv .env ".env-${devilbox_php_version}" 2>/dev/null || true
            mv env.bak .env
        )
    fi

    # --- Завершение ---
    print_celebration "Миграция успешно завершена!"
    print_highlight "Сайт доступен: ${local_url}"

    ddev_launch "$project_name"

    return 0
}

# Экспорт функции команды