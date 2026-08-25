#!/usr/bin/env bash
# =================================================================
# DPX Command: backup - полный бэкап проекта (файлы + база данных)
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/backup.sh"

show_backup_help() {
    cat << EOF
 ${COLOR_BOLD}backup${COLOR_RESET} - Полный бэкап проекта (файлы + база данных)

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} backup [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Создает tar.gz архив: файлы проекта + дамп БД (ddev export-db).
    Исключения: .ddev/.importdb, node_modules, vendor, .git,
    папки вывода бэкапов (.ddev-backups, backups).
    Автоматическая ротация: хранятся последние N архивов.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя проекта DDEV
    --output DIR           Директория для архива (по умолчанию: full_backup_path)
    --keep N               Сколько последних архивов хранить (по умолчанию: full_backup_keep)
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} backup
    ${TOOL_NAME} backup --project-name mysite --keep 5
EOF
}

cmd_backup() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_backup_help
        return 0
    fi

    print_header "Полный бэкап проекта (файлы + БД)"

    # --- Выбор проекта ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Выберите проект для бэкапа")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    local project_path
    project_path=$(projects_get_path "$project_name")
    validate_directory "$project_path" "Директория проекта" || return 1

    # --- Проект должен быть запущен (нужен export-db) ---
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

    # --- Параметры бэкапа ---
    local backup_dir keep_count
    backup_dir=$(get_arg "output" "$(get_config "full_backup_path")")
    keep_count=$(get_arg "keep" "$(get_config "full_backup_keep" "3")")

    # --- Подтверждение ---
    echo "Проект:            ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Директория архива: ${COLOR_GREEN}${backup_dir}${COLOR_RESET}"
    echo "Хранить копий:     ${COLOR_GREEN}${keep_count}${COLOR_RESET}"

    if ! has_arg "yes"; then
        confirm "Создать полный бэкап?" || { print_info "Отменено."; return 0; }
    fi

    # --- Создание бэкапа ---
    local archive_file
    archive_file=$(project_full_backup "$project_name" "$project_path" "$backup_dir" "$keep_count") || return 1

    [[ -n "$archive_file" ]] && print_highlight "Готово: $(basename "$archive_file")"
    return 0
}
