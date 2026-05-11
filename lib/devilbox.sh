#!/usr/bin/env bash
# =================================================================
# DPX Devilbox Module - управление Devilbox, экспорт БД, миграция
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_DEVILBOX_LOADED:-}" ]] && return 0
readonly _DPX_DEVILBOX_LOADED=1

# Подключаем зависимости
source "${DPX_ROOT}/lib/core.sh"

# =================================================================
# DOCKER COMPOSE — кроссплатформенная обёртка (v1 / v2)
# =================================================================

# Определяет доступную команду docker-compose
# v2: docker compose (плагин)
# v1: docker-compose (бинарник)
_dpx_docker_compose_cmd=""  # кэш

dpx_docker_compose() {
    if [[ -z "$_dpx_docker_compose_cmd" ]]; then
        if docker compose version >/dev/null 2>&1; then
            _dpx_docker_compose_cmd="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            _dpx_docker_compose_cmd="docker-compose"
        else
            print_error "docker compose не найден (ни v2 плагин, ни v1 бинарник)."
            return 1
        fi
    fi

    $_dpx_docker_compose_cmd "$@"
}

# =================================================================
# ПУТИ К DEVILBOX
# =================================================================

get_devilbox_path() {
    echo "${DEFAULT_CONFIG[devilbox_path_root]}"
}

get_devilbox_data_path() {
    echo "${DEFAULT_CONFIG[devilbox_data_base_path]}"
}

# =================================================================
# ПРОВЕРКА СОСТОЯНИЯ DEVILBOX
# =================================================================

# Проверка, установлен ли Devilbox
devilbox_is_installed() {
    local devilbox_path=$(get_devilbox_path)
    [[ -d "$devilbox_path" ]]
}

# Проверка, запущен ли Devilbox
devilbox_is_running() {
    local devilbox_path=$(get_devilbox_path)

    if [[ ! -d "$devilbox_path" ]]; then
        return 1
    fi

    # Проверяем через docker compose (в subshell для изоляции)
    if (cd "$devilbox_path" && dpx_docker_compose ps 2>/dev/null | grep -q "Up"); then
        return 0
    fi

    # Альтернативная проверка через docker ps
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "devilbox"; then
        return 0
    fi

    return 1
}

# =================================================================
# УПРАВЛЕНИЕ DEVILBOX
# =================================================================

# Остановка Devilbox
devilbox_stop() {
    local devilbox_path=$(get_devilbox_path)

    if [[ ! -d "$devilbox_path" ]]; then
        print_info "Devilbox не найден, пропускаем остановку."
        return 0
    fi

    if ! devilbox_is_running; then
        print_info "Devilbox уже остановлен."
        return 0
    fi

    print_header "Проверка состояния Devilbox"
    print_info "Чтобы избежать конфликта портов, Devilbox будет остановлен..."

    if (cd "$devilbox_path" && dpx_docker_compose down >/dev/null 2>&1); then
        print_success "Devilbox успешно остановлен."
        return 0
    else
        print_warning "Не удалось остановить Devilbox (возможно, он не запущен)."
        return 0  # Не критическая ошибка
    fi
}

# Запуск Devilbox
devilbox_start() {
    local devilbox_path=$(get_devilbox_path)

    if [[ ! -d "$devilbox_path" ]]; then
        print_error "Devilbox не найден: $devilbox_path"
        return 1
    fi

    if devilbox_is_running; then
        print_info "Devilbox уже запущен."
        return 0
    fi

    print_step "auto" "Запуск Devilbox"

    if (cd "$devilbox_path" && dpx_docker_compose up -d >/dev/null 2>&1); then
        print_success "Devilbox успешно запущен."
        return 0
    else
        print_error "Не удалось запустить Devilbox."
        return 1
    fi
}

# Запуск конкретных сервисов Devilbox
# Важно: cd в subshell, чтобы не "утечь" в другую директорию
devilbox_start_services() {
    local devilbox_path=$(get_devilbox_path)
    local php_version="$1"
    local services="${2:-httpd php mysql}"

    if [[ ! -d "$devilbox_path" ]]; then
        print_error "Devilbox не найден: $devilbox_path"
        return 1
    fi

    print_step "auto" "Запуск Devilbox с PHP $php_version"

    (
        cd "$devilbox_path" || exit 1

        # Переключение на нужную версию PHP
        if [[ -f ".env" ]]; then
            mv .env env.bak 2>/dev/null || true
        fi

        if [[ -f ".env-${php_version}" ]]; then
            cp ".env-${php_version}" .env
            print_success "Конфигурация PHP $php_version активирована."
        else
            print_warning "Файл .env-${php_version} не найден"
        fi

        # Запуск сервисов
        if dpx_docker_compose up -d $services 2>&1; then
            print_success "Сервисы Devilbox запущены: $services"
            exit 0
        else
            print_error "Не удалось запустить сервисы Devilbox"
            exit 1
        fi
    ) || return 1
}

# Восстановление .env Devilbox
# Важно: cd в subshell, чтобы не "утечь" в другую директорию
devilbox_restore_env() {
    local devilbox_path=$(get_devilbox_path)
    local php_version="$1"

    (
        cd "$devilbox_path" || exit 1

        if [[ -f "env.bak" ]]; then
            # Сохраняем текущий .env обратно
            if [[ -n "$php_version" ]] && [[ -f ".env" ]]; then
                cp .env ".env-${php_version}" 2>/dev/null || true
            fi
            mv env.bak .env
            print_success "Конфигурация Devilbox восстановлена."
        fi
    )
}

# Перезапуск Devilbox
devilbox_restart() {
    devilbox_stop
    sleep 2
    devilbox_start
}

# =================================================================
# ЭКСПОРТ БД ИЗ DEVILBOX
# =================================================================

# Экспорт базы данных из Devilbox
# Важно: cd в subshell, и НЕ перенаправлять stderr в файл дампа!
devilbox_export_db() {
    local devilbox_path="$1"
    local db_name="$2"
    local output_file="$3"
    local db_user="${4:-root}"
    local db_pass="${5:-}"

    print_step "auto" "Экспорт базы данных из Devilbox"

    # Убеждаемся, что директория для вывода существует
    ensure_directory "$(dirname "$output_file")"

    # Весь код в subshell для изоляции cd
    (
        cd "$devilbox_path" || exit 1

        # Экспорт через docker-compose
        # ВАЖНО: stderr НЕ должен попадать в файл дампа!
        if ! dpx_docker_compose exec -T mysql mysqldump -u "$db_user" ${db_pass:+-p"$db_pass"} "$db_name" > "$output_file"; then
            print_error "Ошибка экспорта базы данных '$db_name'"
            rm -f "$output_file"  # Удаляем битый файл
            exit 1
        fi

        print_success "База данных '$db_name' экспортирована в: $output_file"
        exit 0
    ) || return 1
}

# =================================================================
# РАБОТА С ПРОЕКТАМИ
# =================================================================

# Проверка существования проекта в Devilbox data
devilbox_project_exists() {
    local project_folder="$1"
    local data_path=$(get_devilbox_data_path)
    local project_path="${data_path}/${project_folder}"

    [[ -d "$project_path" ]]
}

# Получить путь к проекту Devilbox
get_devilbox_project_path() {
    local project_folder="$1"
    local data_path=$(get_devilbox_data_path)
    echo "${data_path}/${project_folder}"
}

# Список проектов в Devilbox data
devilbox_list_projects() {
    local data_path=$(get_devilbox_data_path)

    if [[ ! -d "$data_path" ]]; then
        return 1
    fi

    for dir in "$data_path"/*/; do
        if [[ -d "$dir" ]]; then
            basename "$dir"
        fi
    done
}

# =================================================================
# ПРОВЕРКА КОНФЛИКТОВ ПОРТОВ
# =================================================================

# Проверка, заняты ли порты (кроссплатформенно: lsof или ss)
check_port_conflicts() {
    local ports=(80 443 8025 8036)
    local conflicts=()

    for port in "${ports[@]}"; do
        if command -v lsof >/dev/null 2>&1 && lsof -i ":$port" >/dev/null 2>&1; then
            conflicts+=("$port")
        elif command -v ss >/dev/null 2>&1 && ss -tuln | grep -q ":$port "; then
            conflicts+=("$port")
        fi
    done

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        print_warning "Обнаружены занятые порты: ${conflicts[*]}"
        return 1
    fi

    return 0
}

# Автоматическое разрешение конфликтов портов (остановка Devilbox)
# Важно: сначала проверяем РЕАЛЬНЫЙ конфликт портов через check_port_conflicts
resolve_port_conflicts() {
    # Сначала проверяем, запущен ли вообще Devilbox
    if devilbox_is_running; then
        # Затем проверяем реальный конфликт портов
        if ! check_port_conflicts; then
            print_header "Обнаружен конфликт портов"
            print_info "Devilbox использует те же порты, что и DDEV."

            if confirm "Остановить Devilbox для освобождения портов?"; then
                devilbox_stop
                sleep 2  # Ждем освобождения портов
                return 0
            else
                print_error "Невозможно продолжить без освобождения портов."
                return 1
            fi
        fi
    fi

    return 0
}

# =================================================================
# ОСТАНОВКА DDEV ДЛЯ РАБОТЫ DEVILBOX
# =================================================================

# Остановка DDEV для освобождения ресурсов
ddev_poweroff_for_devilbox() {
    print_header "Подготовка окружения"
    print_info "Останавливаем DDEV, чтобы освободить ресурсы для Devilbox..."

    if ddev poweroff 2>&1; then
        print_success "DDEV остановлен."
        return 0
    else
        print_warning "Не удалось остановить DDEV."
        return 1
    fi
}