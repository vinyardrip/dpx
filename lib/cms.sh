#!/usr/bin/env bash
# =================================================================
# DPX CMS Module - интеграция с CMS (WordPress, Joomla, OpenCart)
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_CMS_LOADED:-}" ]] && return 0
readonly _DPX_CMS_LOADED=1

# =================================================================
# КОНСТАНТЫ
# =================================================================

# Типы CMS
readonly CMS_TYPE_WORDPRESS="wordpress"
readonly CMS_TYPE_JOOMLA="joomla"
readonly CMS_TYPE_OPENCART="opencart"
readonly CMS_TYPE_PHP="php"

# Маппинг типов CMS -> тип проекта DDEV
declare -gA CMS_DDEV_TYPE=(
    ["wordpress"]="wordpress"
    ["joomla"]="php"
    ["opencart"]="php"
    ["php"]="php"
)

# Человеческие имена для вывода
declare -gA CMS_NAMES=(
    ["wordpress"]="WordPress"
    ["joomla"]="Joomla"
    ["opencart"]="OpenCart"
    ["php"]="Чистый PHP"
)

# =================================================================
# ОПРЕДЕЛЕНИЕ ТИПА CMS
# =================================================================

# Автоопределение CMS по структуре файлов
detect_cms_type() {
    local project_path="$1"

    # WordPress: wp-config.php или wp-config-sample.php
    if [[ -f "$project_path/wp-config.php" || -f "$project_path/wp-config-sample.php" ]]; then
        echo "$CMS_TYPE_WORDPRESS"
        return 0
    fi

    # Joomla: configuration.php
    if [[ -f "$project_path/configuration.php" ]]; then
        # Проверяем что это именно Joomla (а не другой framework)
        if grep -q "class JConfig" "$project_path/configuration.php" 2>/dev/null; then
            echo "$CMS_TYPE_JOOMLA"
            return 0
        fi
    fi

    # OpenCart: config.php + system/config.php
    if [[ -f "$project_path/config.php" && -f "$project_path/system/config.php" ]]; then
        if grep -q "DB_DATABASE" "$project_path/config.php" 2>/dev/null; then
            echo "$CMS_TYPE_OPENCART"
            return 0
        fi
    fi

    # Fallback: чистый PHP
    echo "$CMS_TYPE_PHP"
}

# Интерактивный выбор типа CMS
select_cms_type() {
    local prompt="${1:-Выберите тип CMS}"

    print_header "$prompt"
    echo "1. WordPress"
    echo "2. Joomla"
    echo "3. OpenCart"
    echo "4. Чистый PHP"
    echo ""

    local choice
    read -r -p "Выберите [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) echo "$CMS_TYPE_WORDPRESS" ;;
        2) echo "$CMS_TYPE_JOOMLA" ;;
        3) echo "$CMS_TYPE_OPENCART" ;;
        4) echo "$CMS_TYPE_PHP" ;;
        *)
            print_error "Неверный выбор"
            return 1
            ;;
    esac
}

# Получить человекочитаемое имя CMS
get_cms_name() {
    local cms_type="$1"
    echo "${CMS_NAMES[$cms_type]:-$cms_type}"
}

# Получить тип проекта для DDEV
get_ddev_project_type() {
    local cms_type="$1"
    echo "${CMS_DDEV_TYPE[$cms_type]:-php}"
}

# =================================================================
# КОНФИГУРАЦИЯ WP-CLI (для WordPress)
# =================================================================

# Проверяет, нужно ли использовать WP-CLI для замены URL
uses_wp_cli_for_url_replace() {
    local cms_type="$1"
    [[ "$cms_type" == "$CMS_TYPE_WORDPRESS" ]]
}

# =================================================================
# КОНФИГУРАЦИЯ CMS ДЛЯ DDEV
# =================================================================

# Главная функция конфигурации CMS
configure_cms_for_ddev() {
    local project_path="$1"
    local cms_type="$2"
    local new_url="$3"

    print_step "auto" "Настройка конфигурации для ${CMS_NAMES[$cms_type]}"

    case "$cms_type" in
        "$CMS_TYPE_WORDPRESS")
            configure_wordpress_config "$project_path" "$new_url"
            ;;
        "$CMS_TYPE_JOOMLA")
            configure_joomla_config "$project_path" "$new_url"
            ;;
        "$CMS_TYPE_OPENCART")
            configure_opencart_config "$project_path" "$new_url"
            ;;
        *)
            print_info "Конфигурация не требуется для типа: $cms_type"
            ;;
    esac
}

# =================================================================
# WORDPRESS
# =================================================================

configure_wordpress_config() {
    local project_path="$1"
    local new_url="$2"
    local config_file="$project_path/wp-config.php"

    # [FIX] КРИТИЧЕСКАЯ УЯЗВИМОСТЬ ЗАКРЫТА!
    # СТАРАЯ ВЕРСИЯ ПОЛНОСТЬЮ ПЕРЕЗАПИСЫВАЛА wp-config.php, УДАЛЯЯ:
    # - Настройки кэширования (Redis, Memcached)
    # - Лимиты памяти (WP_MEMORY_LIMIT)
    # - Конфигурацию мультисайта
    # - Кастомные пути (Bedrock)
    # - Настройки плагинов
    #
    # НОВАЯ ВЕРСИЯ: DDEV САМ управляет доступами к БД!
    # При ddev start для типа проекта wordpress, DDEV:
    # 1. Создаёт wp-config-ddev.php с доступами ('db', 'db')
    # 2. Безопасно инжектит include в начало wp-config.php
    # 3. Замена URL делается через wp search-replace

    print_info "WordPress: DDEV автоматически настроит доступы к БД."

    if [[ -f "$config_file" ]]; then
        print_success "wp-config.php найден - DDEV добавит свои настройки."
    else
        print_warning "wp-config.php не найден."
        print_info "После ddev start создайте его через WP-CLI:"
        print_info "  ddev wp config create --dbname=db --dbuser=db --dbpass=db --dbhost=db"
    fi

    return 0
}

# =================================================================
# JOOMLA
# =================================================================

configure_joomla_config() {
    local project_path="$1"
    local new_url="$2"
    local config_file="$project_path/configuration.php"

    if [[ ! -f "$config_file" ]]; then
        print_warning "configuration.php не найден. Пропускаем."
        return 0
    fi

    print_info "Настройка configuration.php для DDEV..."

    # [FIX] Пуленепробиваемые регулярки с [[:space:]]*
    # Работает с любым количеством пробелов:
    #   public $host = 'localhost';
    #   public $host='localhost';
    #   public $host  =  'localhost';

    safe_sed_inplace "s|public[[:space:]]*\\\$host[[:space:]]*=.*|public \\\$host = 'db';|g" "$config_file"
    safe_sed_inplace "s|public[[:space:]]*\\\$user[[:space:]]*=.*|public \\\$user = 'db';|g" "$config_file"
    safe_sed_inplace "s|public[[:space:]]*\\\$password[[:space:]]*=.*|public \\\$password = 'db';|g" "$config_file"
    safe_sed_inplace "s|public[[:space:]]*\\\$db[[:space:]]*=.*|public \\\$db = 'db';|g" "$config_file"

    # Замена URL (live_site) - тоже гибкая
    if [[ -n "$new_url" ]]; then
        safe_sed_inplace "s|public[[:space:]]*\\\$live_site[[:space:]]*=.*|public \\\$live_site = '${new_url}';|g" "$config_file"
    fi

    print_success "configuration.php настроен для DDEV."
}

# =================================================================
# OPENCART
# =================================================================

configure_opencart_config() {
    local project_path="$1"
    local new_url="$2"
    local config_file="$project_path/config.php"
    local admin_config="$project_path/admin/config.php"

    if [[ ! -f "$config_file" ]]; then
        print_warning "config.php не найден. Пропускаем."
        return 0
    fi

    print_info "Настройка config.php для DDEV..."

    # [FIX] Пуленепробиваемые регулярки с [[:space:]]*
    # Работает с любым количеством пробелов:
    #   define('DB_HOSTNAME', 'localhost');
    #   define('DB_HOSTNAME','localhost');
    #   define('DB_HOSTNAME',  'localhost');

    safe_sed_inplace "s/'DB_HOSTNAME'[[:space:]]*,[[:space:]]*'.*'/'DB_HOSTNAME', 'db'/g" "$config_file"
    safe_sed_inplace "s/'DB_USERNAME'[[:space:]]*,[[:space:]]*'.*'/'DB_USERNAME', 'db'/g" "$config_file"
    safe_sed_inplace "s/'DB_PASSWORD'[[:space:]]*,[[:space:]]*'.*'/'DB_PASSWORD', 'db'/g" "$config_file"
    safe_sed_inplace "s/'DB_DATABASE'[[:space:]]*,[[:space:]]*'.*'/'DB_DATABASE', 'db'/g" "$config_file"

    print_success "config.php настроен для DDEV."

    # Admin config
    if [[ -f "$admin_config" ]]; then
        print_info "Настройка admin/config.php для DDEV..."

        safe_sed_inplace "s/'DB_HOSTNAME'[[:space:]]*,[[:space:]]*'.*'/'DB_HOSTNAME', 'db'/g" "$admin_config"
        safe_sed_inplace "s/'DB_USERNAME'[[:space:]]*,[[:space:]]*'.*'/'DB_USERNAME', 'db'/g" "$admin_config"
        safe_sed_inplace "s/'DB_PASSWORD'[[:space:]]*,[[:space:]]*'.*'/'DB_PASSWORD', 'db'/g" "$admin_config"
        safe_sed_inplace "s/'DB_DATABASE'[[:space:]]*,[[:space:]]*'.*'/'DB_DATABASE', 'db'/g" "$admin_config"

        print_success "admin/config.php настроен для DDEV."
    fi
}

# =================================================================
# СБРОС СПЕЦИФИЧНЫХ КЭШЕЙ — ДИСПЕТЧЕР ОБРАБОТЧИКОВ
# Вызывается после смены URL (tunnel, refresh, deploy, to-prod).
#
# Архитектура: Plugin Engine
#   Каждый обработчик — отдельный файл в lib/cms/wp-handlers/*.sh
#   Обработчик сам проверяет наличие плагина/темы и решает, что делать.
#   Для добавления нового плагина достаточно закинуть .sh файл — ядро не трогается.
#
# Соглашение для обработчиков:
#   - Переменная: $_CMS_HANDLER_PROJECT_PATH — путь к проекту
#   - Вывод: >&2 для логов, ошибки маскируются через || true
#   - Детектор: каждая handler-файл СНАЧАЛА проверяет наличие плагина, затем действует
# =================================================================

cms_flush_advanced_caches() {
    local project_path="$1"
    local cms_type="${2:-wordpress}"
    local handlers_dir="${DPX_ROOT}/lib/cms/wp-handlers"

    # Не WordPress — расширенная очистка не требуется
    [[ "$cms_type" != "wordpress" ]] && return 0

    # Нет папки с обработчиками — ничего не делаем
    [[ ! -d "$handlers_dir" ]] && return 0

    print_info "Выполняется глубокая очистка и адаптация CMS..." >&2

    # Экспортируем путь для обработчиков (соглашение: $_CMS_HANDLER_PROJECT_PATH)
    local _CMS_HANDLER_PROJECT_PATH="$project_path"

    # Запускаем все плагины-обработчики
    local handler
    for handler in "${handlers_dir}"/*.sh; do
        [[ -f "$handler" ]] || continue
        # source внутри subshell — изоляция: ошибка в обработчике не убьёт диспетчер
        (
            _CMS_HANDLER_PROJECT_PATH="$_CMS_HANDLER_PROJECT_PATH"
            source "$handler"
        ) 2>/dev/null || true
    done

    # Общий сброс объектного кэша WordPress (Redis/Memcached/file-based)
    (
        cd "$project_path" 2>/dev/null && \
        ddev exec php -d display_errors=0 -d error_reporting=0 \
            /usr/local/bin/wp cache flush --allow-root --quiet 2>/dev/null
    ) 2>/dev/null || true

    return 0
}

# =================================================================
# ЭКСПОРТ КОНСТАНТ
# =================================================================

# Экспортируем только константы (строковые переменные)
export CMS_TYPE_WORDPRESS CMS_TYPE_JOOMLA CMS_TYPE_OPENCART CMS_TYPE_PHP

# [FIX] export -f УДАЛЁН - функции наследуются subshell автоматически после source