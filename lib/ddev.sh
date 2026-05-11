#!/usr/bin/env bash
# =================================================================
# DPX Library: ddev - Инструментарий управления DDEV
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_DDEV_LOADED:-}" ]] && return 0
readonly _DPX_DDEV_LOADED=1

# =================================================================
# ПРОВЕРКА СТАТУСА ПРОЕКТОВ
# =================================================================

# Проверка, запущен ли конкретный проект
# [FIX] DDEV 1.25+ выводит таблицы с рамками (│), что ломает awk '{print $1}'
# Используем grep с регулярным выражением для поиска имени проекта
ddev_is_project_running() {
    local name="$1"
    # Ищем имя проекта, игнорируя рамки таблиц DDEV 1.25+ (│) и звездочки (*)
    ddev list --active-only 2>/dev/null | grep -qE "(^|[^a-zA-Z0-9_-])${name}([^a-zA-Z0-9_-]|$)"
}

# Проверка существования проекта в DDEV
ddev_project_exists() {
    local project_name="$1"
    ddev describe "$project_name" >/dev/null 2>&1
}

# =================================================================
# УПРАВЛЕНИЕ ПРОЕКТАМИ
# =================================================================

# Безопасный запуск проекта (с проверкой пути)
# Важно: cd в subshell, чтобы не "утечь" в другую директорию
safe_start_ddev_project() {
    local name="$1"
    local path="$2"

    print_info "Запускаем проект $name..."
    (
        cd "$path" >/dev/null 2>&1 || exit 1
        ddev start
    ) || return 1
}

# Запуск проекта DDEV
ddev_start_project() {
    local project_name="$1"
    local project_path="$2"

    print_info "Запуск DDEV проекта: $project_name"
    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        ddev start
    ) || return 1
}

# Остановка проекта DDEV
ddev_stop_project() {
    local project_name="$1"

    print_info "Остановка DDEV проекта: $project_name"
    ddev stop "$project_name" 2>&1
}

# Удаление проекта DDEV
ddev_delete_project() {
    local project_name="$1"

    print_warning "Удаление DDEV проекта: $project_name"
    ddev delete "$project_name" -y 2>&1
}

# Открытие проекта в браузере
ddev_launch() {
    local project_name="$1"
    print_info "Открытие в браузере..."
    ddev launch "$project_name" 2>/dev/null &
}

# =================================================================
# КОНФИГУРАЦИЯ
# =================================================================

# Получить текущую версию PHP из конфига проекта
ddev_get_php_version() {
    local project_path="$1"
    local config_file="${project_path}/.ddev/config.yaml"

    if [[ -f "$config_file" ]]; then
        grep -E "^php_version:" "$config_file" | awk '{print $2}' | tr -d '"' | tr -d "'"
    else
        echo "unknown"
    fi
}

# Настройка DDEV проекта
ddev_configure_project() {
    local project_name="$1"
    local project_type="$2"
    local php_version="$3"
    local db_type="$4"
    local db_version="$5"
    local docroot="${6:-}"
    local project_tld="${7:-lo}"

    print_step "auto" "Конфигурация DDEV..."

    ddev config --project-name "$project_name" \
        --project-type "$project_type" \
        --php-version "$php_version" \
        --database "${db_type}:${db_version}" \
        --docroot "$docroot" \
        --webserver-type apache-fpm \
        --project-tld "$project_tld" 2>&1
}

# =================================================================
# WP-CLI КОМАНДЫ
# =================================================================

# WP-CLI установка WordPress
ddev_wp_install() {
    local project_path="$1"
    local site_url="$2"
    local site_title="$3"
    local admin_user="$4"
    local admin_pass="$5"
    local admin_email="$6"
    local locale="${7:-ru_RU}"

    print_step "3" "Установка WordPress через WP-CLI"

    # Весь код в subshell для изоляции cd
    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1

        # Скачивание WordPress
        print_info "Загрузка WordPress ($locale)..."
        ddev wp core download --locale="$locale" 2>&1 || {
            print_error "Ошибка загрузки WordPress"
            exit 1
        }

        # Создание wp-config.php
        print_info "Создание wp-config.php..."
        ddev wp config create --dbname=db --dbuser=db --dbpass=db --dbhost=db 2>&1 || {
            print_error "Ошибка создания wp-config.php"
            exit 1
        }

        # Установка WordPress
        print_info "Установка WordPress..."
        ddev wp core install \
            --url="$site_url" \
            --title="$site_title" \
            --admin_user="$admin_user" \
            --admin_password="$admin_pass" \
            --admin_email="$admin_email" 2>&1 || {
            print_error "Ошибка установки WordPress"
            exit 1
        }

        print_success "WordPress успешно установлен."
    ) || return 1
}

# WP-CLI search-replace
ddev_wp_search_replace() {
    local old_url="$1"
    local new_url="$2"
    local project_path="$3"

    print_info "Замена URL: $old_url -> $new_url"
    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        ddev exec wp search-replace "$old_url" "$new_url" --all-tables --allow-root 2>&1
    ) || return 1
}

# WP-CLI удаление тем
ddev_wp_theme_delete() {
    local themes="$1"
    local project_path="$2"

    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        for theme in $themes; do
            ddev wp theme delete "$theme" 2>/dev/null || true
        done
    )
}

# WP-CLI удаление плагинов
ddev_wp_plugin_delete() {
    local plugins="$1"
    local project_path="$2"

    (
        [[ -n "$project_path" ]] && cd "$project_path" || exit 1
        for plugin in $plugins; do
            ddev wp plugin delete "$plugin" 2>/dev/null || true
        done
    )
}