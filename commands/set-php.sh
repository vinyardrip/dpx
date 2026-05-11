#!/usr/bin/env bash
# =================================================================
# DPX Command: set-php - Динамическая смена PHP + Auto-Cleanup + Backup
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_set_php_help() {
    cat << EOF
 ${COLOR_BOLD}set-php${COLOR_RESET} - Смена версии PHP проекта

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} set-php [имя_проекта]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Интерактивная смена версии PHP для DDEV проекта.
    После смены предлагается проверить работу сайта
    и сохранить максимальную рабочую версию.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    -h, --help     Показать эту справку
    -y, --yes      Автоматическое подтверждение

 ${COLOR_BOLD}Workflow:${COLOR_RESET}
    1. Выбор проекта и версии PHP
    2. Автоматический бэкап базы данных
    3. Смена версии PHP + restart контейнера
    4. Проверка работы сайта пользователем
    5. Сохранение php_max если всё работает

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} set-php
    ${TOOL_NAME} set-php mysite
EOF
}

# =================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =================================================================

# Получить URL проекта из DDEV
_get_project_url() {
    local project_path="$1"
    local project_name
    project_name=$(basename "$project_path")

    # Пробуем получить URL через ddev describe (если проект запущен)
    local url
    url=$(cd "$project_path" 2>/dev/null && ddev describe 2>/dev/null | grep -oE 'https://[a-zA-Z0-9._-]+\.ddev\.site' | head -1)

    # Если не получилось — конструируем из имени проекта + TLD из конфига
    if [[ -z "$url" ]]; then
        local tld
        tld=$(get_config "project_tld" "ddev.site")
        url="https://${project_name}.${tld}"
    fi

    echo "$url"
}

# Открыть URL в браузере
_open_in_browser() {
    local url="$1"
    if [[ -n "$url" ]]; then
        print_info "Открытие в браузере: $url"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            open "$url" 2>/dev/null &
        else
            xdg-open "$url" 2>/dev/null &
        fi
    fi
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_set_php() {
    print_header "DDEV PHP Manager v2.9.1"

    parse_args "$@" || return 1

    if has_arg "help"; then
        show_set_php_help
        return 0
    fi

    # --- 1. ВЫБОР ПРОЕКТА ---
    local project_name
    project_name=$(get_positional_arg 1)

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Выберите проект для смены PHP")
    fi
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")
    local config_file="${project_path}/.ddev/config.yaml"

    # --- 2. ДИНАМИЧЕСКАЯ ЛОГИКА ВЕРСИЙ ---
    local current_php="unknown"
    [[ -f "$config_file" ]] && current_php=$(grep -E "^php_version:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")

    local saved_php_max
    saved_php_max=$(dpx_get_php_max "$project_name")

    local versions=($(ddev debug capabilities 2>/dev/null | grep "Supported PHP versions" | cut -d: -f2 | tr ',' ' ' | tr -d '[]'))

    if [[ ${#versions[@]} -eq 0 ]]; then
        versions=("5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
    fi

    printf '\nПроект: %s%s%s\n' "$COLOR_GREEN" "$project_name" "$COLOR_RESET"
    printf 'Текущая версия: %s%s%s' "$COLOR_CYAN" "$current_php" "$COLOR_RESET"

    if [[ "$saved_php_max" != "-" ]]; then
        printf ' (макс. протестированная: %s%s%s)' "$COLOR_GREEN" "$saved_php_max" "$COLOR_RESET"
    fi
    printf '\n\n'

    local i=1
    for v in "${versions[@]}"; do
        local marker=""
        [[ "$v" == "$current_php" ]] && marker=" ${COLOR_CYAN}(текущая)${COLOR_RESET}"
        [[ "$v" == "$saved_php_max" ]] && marker="${marker:-(протестирована)}"
        printf "%2d. %s%b\n" "$i" "$v" "$marker"
        ((i++))
    done
    echo ""

    read -r -p "Выберите номер или версию: " v_choice
    local new_php=""
    if [[ "$v_choice" =~ ^[0-9]+$ ]] && (( v_choice > 0 && v_choice <= ${#versions[@]} )); then
        new_php="${versions[$((v_choice-1))]}"
    else
        new_php="$v_choice"
    fi

    [[ -z "$new_php" ]] && return 1

    if [[ "$new_php" == "$current_php" ]]; then
        print_warning "Проект уже использует PHP $new_php"
        return 0
    fi

    if [[ "$saved_php_max" != "-" ]] && [[ $(echo "$new_php $saved_php_max" | awk '{if ($1 > $2) print 1; else print 0}') -eq 1 ]]; then
        print_warning "Внимание! Выбирается версия выше протестированной ($saved_php_max)"
        if ! confirm "Продолжить?"; then
            return 0
        fi
    fi

    # --- 3. ВЫПОЛНЕНИЕ ---
    local backup_dir=""
    local snap_name=""

    if confirm "Переключить ${project_name} на PHP ${new_php}?"; then
        (
            cd "$project_path" 2>/dev/null || exit 1

            # --- [BACKUP] ---
            backup_dir=$(get_config "db_local_path")
            mkdir -p "$backup_dir"

            local ts=$(date +"%y%m%d_%H%M")
            local type_tag="BEFORE_PHP"
            snap_name="${project_name}_${type_tag}_${ts}.sql"
            local snap_path="${backup_dir}/${snap_name}"

            print_info "Создание бэкапа: ${snap_name}"

            if ddev export-db --gzip=false --file="$snap_path" >/dev/null 2>&1; then
                print_success "Бэкап создан: $(du -h "$snap_path" | awk '{print $1}')"
            else
                print_warning "Не удалось создать бэкап (возможно база пустая)"
            fi

            core_rotate_backups "$project_name" "$backup_dir" "$type_tag"

            # --- [ACTION] ---
            print_info "Установка PHP $new_php..."
            ddev config --php-version="$new_php" 2>&1 | grep -v "^Project config" || true

            # --- [RESTART] ---
            print_info "Перезапуск контейнера..."
            ddev restart 2>&1 | tail -5

            # --- [CACHE] ---
            if ddev exec wp core is-installed >/dev/null 2>&1; then
                print_info "Сброс кэша WordPress..."
                ddev exec wp cache flush >/dev/null 2>&1
            fi

            print_success "PHP $new_php применён"

        ) || print_error "Ошибка: $project_path"
    else
        return 0
    fi

    # --- 4. ПРОВЕРКА РАБОТОСПОСОБНОСТИ ---
    echo ""
    print_header "Проверка работоспособности"

    local project_url
    project_url=$(_get_project_url "$project_path")

    if [[ -n "$project_url" ]]; then
        printf '\n%sПроект:%s %s%s%s\n' "$COLOR_BOLD" "$COLOR_RESET" "$COLOR_GREEN" "$project_name" "$COLOR_RESET"
        printf '%sURL:%s %s%s%s\n\n' "$COLOR_BOLD" "$COLOR_RESET" "$COLOR_CYAN" "$project_url" "$COLOR_RESET"

        if confirm "Открыть сайт в браузере?"; then
            _open_in_browser "$project_url"
        fi
    else
        print_warning "Не удалось определить URL проекта"
    fi

    echo ""
    print_info "Проверьте работу сайта в браузере"
    echo ""
    read -r -p "Сайт работает корректно? (y/n): " works

    case "$works" in
        y|Y|yes|да)
            echo ""
            local current_saved
            current_saved=$(dpx_get_php_max "$project_name")

            if [[ "$current_saved" == "-" ]] || [[ "$new_php" != "$current_saved" ]]; then
                if [[ "$current_saved" == "-" ]]; then
                    printf "%sСохранить PHP %s как максимальную рабочую версию?%s (y/n): " "$COLOR_GREEN" "$new_php" "$COLOR_RESET"
                else
                    printf "%sОбновить php_max: %s → %s?%s (y/n): " "$COLOR_GREEN" "$current_saved" "$new_php" "$COLOR_RESET"
                fi
                read -r -p "" save_it

                if [[ "$save_it" =~ ^[yY] ]]; then
                    local project_type
                    project_type=$(grep -E "^type:" "${project_path}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

                    dpx_meta_set "$project_name" "type" "$project_type"
                    dpx_meta_set "$project_name" "php_max" "$new_php"
                    dpx_meta_set "$project_name" "tested" "$(date +%Y-%m-%d)"

                    print_success "php_max = $new_php сохранён"
                    echo ""
                    print_info "Хранилище: $(dpx_meta_file)"
                fi
            else
                print_success "Эта версия уже записана как php_max"
            fi
            ;;

        n|N|no|нет)
            echo ""
            print_warning "Сайт не работает на PHP $new_php"
            echo ""
            echo "Действия:"
            echo "  1. Откатиться на предыдущую версию ($current_php)"
            echo "  2. Попробовать другую версию"
            echo "  0. Оставить как есть"
            echo ""
            read -r -p "Выбор: " rollback_choice

            case "$rollback_choice" in
                1)
                    print_info "Откат на PHP $current_php..."
                    (
                        cd "$project_path" 2>/dev/null || exit 1
                        ddev config --php-version="$current_php" 2>&1 | grep -v "^Project config" || true
                        ddev restart 2>&1 | tail -3
                    )
                    print_success "Откат выполнен на PHP $current_php"
                    ;;
                2)
                    print_info "Запустите dpx set-php снова для выбора другой версии"
                    ;;
                0|*)
                    print_info "Версия PHP $new_php оставлена без изменений"
                    if [[ -n "$snap_name" ]] && [[ -n "$backup_dir" ]]; then
                        print_info "Бэкап доступен: ${backup_dir}/${snap_name}"
                    fi
                    ;;
            esac
            ;;

        *)
            print_info "Пропуск сохранения результата"
            ;;
    esac

    echo ""
    print_info "Готово!"
}