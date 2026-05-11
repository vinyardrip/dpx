#!/usr/bin/env bash
# =================================================================
# DPX Command: db-snap - Быстрый локальный снимок БД
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"

cmd_db_snap() {
    parse_args "$@" || return 1
    print_header "Создание снимка локальной БД v1.1.1"

    # 1. Выбор проекта
    local project_name
    project_name=$(projects_select_interactive "Выберите проект для снимка БД")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # 2. Проверка статуса DDEV
    if ! ddev_is_project_running "$project_name"; then
        confirm "Проект '$project_name' не запущен. Запустить для экспорта?" && \
            safe_start_ddev_project "$project_name" "$project_path" || return 1
    fi

    # 3. Генерация имени и экспорт
    # [OPTIMIZATION] Сохраняем путь в переменную (избегаем повторных вызовов)
    local db_dir
    db_dir=$(get_db_local_path)
    ensure_directory "$db_dir"

    # db_generate_export_filename уже генерирует .sql (без .gz)
    local out_file="${db_dir}/$(db_generate_export_filename "$project_name" "SNAP")"

    print_info "Экспорт базы [$project_name] (без сжатия для быстрого доступа)..."

    # Выполняем в subshell для изоляции cd
    (
        cd "$project_path" || exit 1

        # [FIX] Убрано 2>&1 - оставляем stderr видимым для диагностики ошибок
        # Бэкапы критичны, ошибки должны быть видны!
        if ddev export-db --gzip=false --file="$out_file" >/dev/null; then
            print_success "Снимок создан: $(basename "$out_file")"
            print_info "Размер: $(du -h "$out_file" | awk '{print $1}')"
        else
            print_error "Не удалось создать снимок."
            exit 1
        fi
    ) || return 1

    # 4. Ротация старых снимков (оставляем 3 последних)
    # Важно: вызываем ВНЕ subshell, только после успешного экспорта
    core_rotate_backups "$project_name" "$db_dir" "SNAP" 3
}

# [FIX] Убран export -f - функция вызывается через source в роутере,
# экспорт не нужен и загрязняет окружение