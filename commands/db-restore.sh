#!/usr/bin/env bash
# =================================================================
# DPX Command: db-restore - Восстановление БД из локального бэкапа
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"

cmd_db_restore() {
    parse_args "$@" || return 1
    print_header "Восстановление базы данных v1.2.1"

    # 1. Выбор проекта
    local project_name
    project_name=$(projects_select_interactive "Выберите проект для восстановления БД")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # 2. Поиск доступных бэкапов в db_local
    local backup_dir=$(get_db_local_path)
    if [[ ! -d "$backup_dir" ]]; then
        print_error "Директория бэкапов не найдена: $backup_dir"
        return 1
    fi

    # [FIX] Безопасное чтение файлов в массив (работает с путями с пробелами)
    # mapfile читает построчно, не разбивая по пробелам как $(...)
    local files=()
    mapfile -t files < <(ls -1t "${backup_dir}/${project_name}"* 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warning "Бэкапы для проекта '$project_name' не найдены в $backup_dir"
        return 1
    fi

    # 3. Интерактивный выбор файла
    print_info "Доступные бэкапы (сначала новые):"
    local i=1
    local display_files=()
    for f in "${files[@]}"; do
        local filename=$(basename "$f")
        # [FIX] awk вместо cut - кроссплатформенная совместимость (BSD/GNU du)
        local fsize=$(du -h "$f" | awk '{print $1}')
        echo "$i. $filename ($fsize)"
        display_files+=("$f")
        ((i++))
    done

    local choice
    # [FIX] Убрано избыточное >&2 (read -p уже выводит в stderr)
    read -r -p "Выберите номер файла для импорта [1]: " choice
    choice="${choice:-1}"

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#display_files[@]} )); then
        print_error "Неверный выбор"
        return 1
    fi

    local selected_file="${display_files[$((choice-1))]}"

    # 4. Проверка статуса DDEV
    if ! ddev_is_project_running "$project_name"; then
        confirm "Проект '$project_name' не запущен. Запустить?" && safe_start_ddev_project "$project_name" "$project_path" || return 1
    fi

    # 5. Выполнение импорта
    if confirm "Вы уверены, что хотите ЗАМЕНИТЬ базу данных проекта '$project_name' файлом $(basename "$selected_file")?"; then
        # Создаем защитный бэкап текущего состояния перед импортом
        print_info "Создание защитного дампа текущей БД..."
        local backup_file
        backup_file=$(db_backup_local "$project_name" "$project_path") || { print_error "Не удалось создать защитный бэкап. Отмена."; return 1; }
        print_success "Защитный дамп сохранен: $(basename "$backup_file")"

        print_info "Начинаю импорт..."

        # Выполняем в subshell для изоляции cd
        (
            cd "$project_path" || exit 1

            if db_import "$selected_file" "$project_path"; then
                print_success "База данных успешно восстановлена!"

                # [FIX] Проверка WordPress через wp-cli (надежнее поиска wp-config.php)
                # Работает с DDEV docroot (web/, public/) и нестандартными структурами (Bedrock)
                print_info "Проверка наличия WordPress..."
                if ddev exec wp core is-installed >/dev/null 2>&1; then
                    print_info "Очистка объектного кэша WordPress..."
                    if ddev exec wp cache flush >/dev/null 2>&1; then
                        print_success "Кэш WordPress очищен."
                    fi
                fi
            else
                print_error "Ошибка при восстановлении базы."
                exit 1
            fi
        ) || return 1
    fi
}