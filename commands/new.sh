#!/usr/bin/env bash
# =================================================================
# DPX Command: new - универсальное создание проектов
#
# Типы: wordpress | joomla | opencart | laravel | php
#
# Архитектура:
#   new_resolve_type / new_select_type - нормализация и выбор типа;
#   _new_scaffold_*                    - каркас каждого типа;
#   cmd_new                            - единая точка входа.
#   dpx new-wp - тонкая обертка над cmd_new --cms=wordpress.
# Версия: v1.7.0
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/devilbox.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_new_help() {
    cat << EOF
 ${COLOR_BOLD}new${COLOR_RESET} - Универсальное создание проекта (WordPress/Joomla/OpenCart/Laravel/PHP)

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} new [project-name] [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Единая точка создания проектов на DDEV. Без флагов запускает
    интерактивный выбор типа проекта.

 ${COLOR_BOLD}Типы проектов:${COLOR_RESET}
    1) WordPress        WP-CLI установка + стартовая тема (см. также: dpx new-wp)
    2) Joomla           Последний стабильный релиз с downloads/GitHub
    3) OpenCart         Официальный релиз с GitHub Releases
    4) ocStore          Локализованный форк OpenCart (SEO Pro встроен)
    5) Laravel          composer create-project + .env под DDEV (docroot: public)
    6) Plain PHP        Чистый PHP-каркас (index.php)

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя нового проекта (или первый позиционный аргумент)
    --cms TYPE             Тип: wordpress|joomla|opencart|ocstore|laravel|php
                           (алиасы: --type TYPE, --cms=TYPE, wp/ocs/lara/html)
    --php VERSION          Версия PHP (по умолчанию из конфига)
    --db                   Создать базу данных сразу после старта контейнера
    -y, --yes              Пропустить подтверждения
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} new                                   # полностью интерактивно
    ${TOOL_NAME} new myshop --cms=laravel --php=8.3 -y
    ${TOOL_NAME} new blog --type wordpress
    ${TOOL_NAME} new russhop --type=ocstore            # ocStore с SEO Pro
    ${TOOL_NAME} new-wp mysite                         # совместимость (= new --cms=wordpress)
EOF
}

# =================================================================
# РАЗРЕШЕНИЕ ТИПА ПРОЕКТА
# =================================================================

# Нормализация пользовательского ввода в канонический тип.
# STDOUT: тип или пустая строка. Чистая функция (тестируемая).
new_resolve_type() {
    local input="${1:-}"

    # Нормализация: пробелы по краям -> нижний регистр
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    input="${input,,}"

    case "$input" in
        "" ) return 0 ;;
        1|wp|wordpress)          echo "wordpress" ;;
        2|joomla|jml)            echo "joomla" ;;
        3|oc|opencart)           echo "opencart" ;;
        4|ocs|ocstore)           echo "ocstore" ;;
        5|lara|laravel)          echo "laravel" ;;
        6|php|plain|html|static) echo "php" ;;
        * ) return 0 ;;
    esac
}

# Интерактивный выбор типа. Меню -> STDERR, значение -> STDOUT.
new_select_type() {
    cat >&2 << MENU

--- Выберите тип проекта ---
  1) WordPress
  2) Joomla
  3) OpenCart (Official)
  4) ocStore (OpenCart Russia/SEO Pro)
  5) Laravel
  6) Plain PHP / HTML

MENU

    local input resolved=""
    while [[ -z "$resolved" ]]; do
        input=""
        if ! read -r -p "Выберите [1-6]: " input; then
            print_error "Ввод прерван (EOF)."
            return 1
        fi
        resolved=$(new_resolve_type "$input")
        if [[ -z "$resolved" ]]; then
            print_warning "Неизвестный вариант '$input'. Введите номер или название."
        fi
    done

    printf '%s\n' "$resolved"
}

# =================================================================
# ПРИМИТИВЫ КАРКАСА (чистые файловые операции — тестируемые)
# =================================================================

# Нормализация docroot: если контент лежит в единственном подкаталоге
# (layout вида upload/... у OpenCart), переносим содержимое на уровень выше.
_new_normalize_docroot() {
    local dir="$1"
    [[ -f "$dir/index.php" ]] && return 0

    local top_dirs top_files sub
    top_dirs=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    top_files=$(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$top_dirs" == "1" && "$top_files" == "0" ]]; then
        sub=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        # dotfiles + файлы: shopt dotglob локально для перемещения
        (
            shopt -s dotglob nullglob
            mv -- "$sub"/* "$dir"/ 2>/dev/null
        )
        rmdir "$sub" 2>/dev/null || true
        print_info "Docroot нормализован: содержимое '$(basename "$sub")' поднято в корень."
    fi
    return 0
}

# Портативный upsert KEY=value в .env-подобном файле (BSD/GNU sed).
_new_env_set_kv() {
    local env_file="$1" key="$2" value="$3"

    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
        safe_sed_inplace "s|^${key}=.*|${key}=${value}|g" "$env_file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

# Загрузка архива: curl с ретраями, fallback wget.
_new_archive_fetch() {
    local url="$1" dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 15 -o "$dest" "$url" >/dev/null 2>&1 && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -t 2 -O "$dest" "$url" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# Резолвер URL последнего релиза CMS-архива.
#
# Стратегии:
#   1) env-override: DPX_JOOMLA_ARCHIVE_URL / DPX_OPENCART_ARCHIVE_URL;
#   2) GitHub API releases/latest -> подходящий asset;
#   3) codeload source-архив (с предупреждением).
# STDOUT: URL либо пусто (caller решает).
_new_resolve_archive_url() {
    local cms_type="$1"
    local repo="" asset_pattern="" source_fallback="" env_var=""

    case "$cms_type" in
        joomla)
            repo="Joomla/Joomla-CMS"
            asset_pattern='Full_Package.*\.tar\.gz'
            source_fallback="https://github.com/Joomla/Joomla-CMS/archive/refs/heads/latest.tar.gz"
            env_var="DPX_JOOMLA_ARCHIVE_URL"
            ;;
        opencart)
            repo="opencart/opencart"
            asset_pattern='opencart.*\.zip'
            source_fallback="https://github.com/opencart/opencart/archive/refs/heads/master.zip"
            env_var="DPX_OPENCART_ARCHIVE_URL"
            ;;
        ocstore)
            repo="myopencart/ocstore"
            asset_pattern='(?i)ocstore.*\.zip'
            source_fallback="https://github.com/myopencart/ocstore/archive/refs/heads/master.zip"
            env_var="DPX_OCSTORE_ARCHIVE_URL"
            ;;
        *) return 1 ;;
    esac

    # 1) Явный override пользователя/окружения
    if [[ -n "${!env_var:-}" ]]; then
        printf '%s\n' "${!env_var}"
        return 0
    fi

    local api_json=""
    api_json=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || api_json=""

    # 2) Asset из официального релиза
    if [[ -n "$api_json" ]]; then
        local url=""
        url=$(printf '%s' "$api_json" \
            | jq -r --arg pat "$asset_pattern" \
                '[.assets[]? | select(.name | test($pat))][0].browser_download_url // empty' 2>/dev/null)
        if [[ -n "$url" && "$url" != "null" ]]; then
            printf '%s\n' "$url"
            return 0
        fi
    fi

    # 3) Source-архив (может требовать composer build — предупреждаем)
    if [[ -n "$source_fallback" ]]; then
        print_warning "Release-asset не найден; использую source-архив ${repo}."
        print_warning "Если каркас не заработает, задайте ${env_var}=<URL готового пакета>."
        printf '%s\n' "$source_fallback"
        return 0
    fi

    return 1
}

# Скачивание и распаковка архива в workdir + нормализация docroot.
_new_archive_download_unpack() {
    local url="$1" workdir="$2"

    local ext="${url##*.}"
    local archive="$workdir/pkg.${ext}"

    print_step "auto" "Загрузка архива..."
    if ! _new_archive_fetch "$url" "$archive"; then
        print_error "Не удалось скачать: $url"
        return 1
    fi

    # Санити: архив не может быть крошечным
    local size
    size=$(wc -c < "$archive" 2>/dev/null | tr -d ' ')
    if [[ -z "$size" ]] || (( size < 10240 )); then
        print_error "Скачанный файл подозрительно мал (${size:-0} байт). Отмена."
        return 1
    fi

    print_step "auto" "Распаковка..."
    case "$ext" in
        zip)
            if ! command -v unzip >/dev/null 2>&1; then
                print_error "unzip не найден (нужен для zip-архивов)."
                return 1
            fi
            unzip -q -o "$archive" -d "$workdir" || return 1
            ;;
        tar.gz|tgz|gz)
            tar -xzf "$archive" -C "$workdir" || return 1
            ;;
        *)
            print_error "Неподдерживаемый формат архива: .$ext"
            return 1
            ;;
    esac
    rm -f "$archive"

    _new_normalize_docroot "$workdir"
}

# Создание БД (флаг --db): имя из конфига CMS или имя проекта.
_new_provision_db() {
    local project_name="$1" project_path="$2" cms_type="$3"

    local db_name
    db_name=$(db_get_db_name "$project_path" "$cms_type" 2>/dev/null) || db_name=""
    db_name="${db_name//[^a-zA-Z0-9_]/_}"
    [[ -z "$db_name" ]] && db_name="${project_name//-/_}"

    print_step "auto" "Создание базы данных '${db_name}'..."
    if ddev mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;" >/dev/null 2>&1; then
        print_success "БД '${db_name}' готова."
    else
        print_warning "Не удалось создать БД (контейнер БД мог ещё инициализироваться)."
    fi
}

# =================================================================
# КАРКАСЫ ПО ТИПАМ
# =================================================================

# WordPress: логика перенесена из legacy new-wp.sh без изменений поведения.
_new_scaffold_wordpress() {
    local project_name="$1" project_path="$2" php_version="$3" use_theme="${4:-yes}"

    local site_url
    site_url="https://${project_name}.$(get_config 'project_tld')"
    local locale admin_user admin_pass admin_email
    locale=$(get_arg "locale" "ru_RU")
    admin_user=$(get_arg "admin_user" "$(get_config 'admin_user')")
    admin_pass=$(get_arg "admin_pass" "$(get_config 'admin_pass')")
    admin_email=$(get_arg "admin_email" "$(get_config 'admin_email')")

    print_step "2" "Конфигурация и запуск DDEV"
    if ! ddev config --project-type wordpress --docroot "" \
            --project-tld "$(get_config 'project_tld')" \
            --php-version "$php_version" 2>&1; then
        print_error "Ошибка конфигурации DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Ошибка запуска DDEV"
        return 1
    fi

    print_step "3" "Установка WordPress через WP-CLI"
    if ! ddev_wp_install "$project_path" "$site_url" \
            "Новый сайт ${project_name}" "$admin_user" "$admin_pass" "$admin_email" "$locale"; then
        print_error "Ошибка установки WordPress"
        return 1
    fi

    local starter_theme_path
    starter_theme_path=$(get_config "starter_theme_path")

    if [[ "$use_theme" == "yes" ]] && [[ -d "$starter_theme_path" ]]; then
        print_step "4" "Копирование и активация стартовой темы '${project_name}'"

        local theme_dir="wp-content/themes/${project_name}"
        cp -r "${starter_theme_path}/." "$theme_dir"

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
        ddev_wp_theme_delete "twentytwentytwo twentytwentythree twentytwentyfour" "$project_path"
    elif [[ "$use_theme" == "yes" ]]; then
        print_warning "Стартовая тема не найдена (${starter_theme_path}). Шаг пропущен."
    fi

    print_step "5" "Очистка стандартных плагинов"
    ddev_wp_plugin_delete "akismet hello" "$project_path"

    print_celebration "WordPress проект '${project_name}' создан!"
    print_highlight "Админ-панель: ${site_url}/wp-admin/ (логин: ${admin_user})"
    return 0
}

# Joomla / OpenCart: скачивание релиза + DDEV project_type=php.
_new_scaffold_archive_cms() {
    local cms_type="$1" project_name="$2" project_path="$3" php_version="$4"

    local archive_url
    archive_url=$(_new_resolve_archive_url "$cms_type") || archive_url=""
    if [[ -z "$archive_url" ]]; then
        print_error "Не удалось определить URL релиза ${cms_type}."
        print_info  "Задайте DPX_${cms_type^^}_ARCHIVE_URL=<URL архива> и повторите."
        return 1
    fi
    print_info "Релиз: $archive_url"

    local tmpdir
    tmpdir=$(create_temp_dir) || { print_error "Нет временной директории."; return 1; }
    trap 'rm -rf "$tmpdir" 2>/dev/null' RETURN

    if ! _new_archive_download_unpack "$archive_url" "$tmpdir"; then
        print_error "Ошибка загрузки/распаковки ${cms_type}."
        return 1
    fi

    # Перенос распакованного контента в директорию проекта
    (
        shopt -s dotglob nullglob
        mv -- "$tmpdir"/* "$project_path"/ 2>/dev/null
    )

    print_step "auto" "Конфигурация DDEV (project_type: php)"
    if ! ddev_configure_project "$project_name" "php" "$php_version" \
            "$(get_config 'default_db_type')" "$(get_config 'default_db_version')" \
            "" "$(get_config 'project_tld')"; then
        print_error "Ошибка конфигурации DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Ошибка запуска DDEV"
        return 1
    fi

    case "$cms_type" in
        joomla)   print_info "Далее откройте сайт в браузере и завершите установку (/installation)." ;;
        opencart) print_info "Далее откройте сайт в браузере и завершите установку (/install)." ;;
        ocstore)  print_info "Далее откройте сайт в браузере, завершите установку (/install) и включите SEO Pro." ;;
    esac
    return 0
}

# Laravel: project_type=laravel, docroot=public, composer + .env под DDEV.
_new_laravel_env_rewrite() {
    local env_file="$1" app_url="$2"

    [[ -f "$env_file" ]] || { print_error ".env не найден после create-project."; return 1; }

    _new_env_set_kv "$env_file" "DB_HOST" "db"
    _new_env_set_kv "$env_file" "DB_DATABASE" "db"
    _new_env_set_kv "$env_file" "DB_USERNAME" "db"
    _new_env_set_kv "$env_file" "DB_PASSWORD" "db"
    _new_env_set_kv "$env_file" "APP_URL" "$app_url"
    _new_env_set_kv "$env_file" "APP_ENV" "local"

    print_success ".env сконфигурирован под DDEV (db/db/db)."
    return 0
}

_new_scaffold_laravel() {
    local project_name="$1" project_path="$2" php_version="$3"

    print_step "2" "Конфигурация DDEV (project_type: laravel, docroot: public)"
    if ! ddev_configure_project "$project_name" "laravel" "$php_version" \
            "$(get_config 'default_db_type')" "$(get_config 'default_db_version')" \
            "public" "$(get_config 'project_tld')"; then
        print_error "Ошибка конфигурации DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Ошибка запуска DDEV"
        return 1
    fi

    # composer create-project требует пустой каталог: ставим во временную
    # подпапку и поднимаем содержимое (включая dotfiles: .env, .gitignore).
    print_step "3" "composer create-project laravel/laravel (это займет время)..."
    if ! ddev composer create-project --no-interaction --prefer-dist \
            laravel/laravel _app_tmp; then
        print_error "composer create-project провален."
        rm -rf "_app_tmp"
        return 1
    fi

    (
        shopt -s dotglob nullglob
        mv -- _app_tmp/* . 2>/dev/null
    )
    rmdir _app_tmp 2>/dev/null || true

    local site_url
    site_url="https://${project_name}.$(get_config 'project_tld')"
    if ! _new_laravel_env_rewrite "${project_path}/.env" "$site_url"; then
        return 1
    fi

    print_celebration "Laravel проект '${project_name}' создан!"
    print_highlight "Миграции:  ddev artisan migrate"
    print_highlight "URL:       ${site_url}"
    return 0
}

# Plain PHP: минимальный каркас + опциональная БД (--db).
_new_scaffold_php() {
    local project_name="$1" project_path="$2" php_version="$3"

    cat > index.php << EOF
<?php
phpinfo();
EOF

    print_step "2" "Конфигурация DDEV (project_type: php)"
    if ! ddev_configure_project "$project_name" "php" "$php_version" \
            "$(get_config 'default_db_type')" "$(get_config 'default_db_version')" \
            "" "$(get_config 'project_tld')"; then
        print_error "Ошибка конфигурации DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Ошибка запуска DDEV"
        return 1
    fi

    if has_arg "db"; then
        _new_provision_db "$project_name" "$project_path" "php"
    fi

    print_celebration "PHP проект '${project_name}' создан!"
    return 0
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_new() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_new_help
        return 0
    fi

    print_header "Создание нового проекта"

    # --- Имя проекта: позиционный аргумент или интерактив ---
    local project_name
    project_name=$(get_positional_arg 1 "")
    [[ -z "$project_name" ]] && project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Имя нового проекта (например, my-cool-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    local project_path="${PROJECTS_ROOT}/${project_name}"
    if [[ -d "$project_path" ]]; then
        print_error "Директория уже существует: $project_path"
        return 1
    fi

    # --- Тип проекта: --cms/--type (=value и раздельные формы), иначе меню ---
    local cms_type
    cms_type=$(new_resolve_type "$(get_arg "cms" "")")
    if [[ -z "$cms_type" ]]; then
        cms_type=$(new_resolve_type "$(get_arg "type" "")")
    fi
    if [[ -z "$cms_type" ]]; then
        cms_type=$(new_select_type) || return 1
    fi
    print_success "Тип проекта: $(get_cms_name "$cms_type")"

    local php_version
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")
    if ! has_arg "project_name" && [[ $# -eq 0 ]]; then
        prompt_input "Версия PHP" "$php_version" php_version
    fi

    local use_theme="yes"
    has_arg "no_theme" && use_theme="no"

    local site_url
    site_url="https://${project_name}.$(get_config 'project_tld')"

    print_header "Проверьте параметры"
    echo "Имя проекта:      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Тип:              ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "URL сайта:        ${COLOR_GREEN}${site_url}${COLOR_RESET}"
    echo "Версия PHP:       ${COLOR_GREEN}${php_version}${COLOR_RESET}"
    echo "База данных (--db): ${COLOR_GREEN}$(has_arg 'db' && echo 'да' || echo 'нет')${COLOR_RESET}"
    echo "Путь:             ${COLOR_GREEN}${project_path}${COLOR_RESET}"
    print_separator

    if ! has_arg "yes"; then
        confirm "Создать проект?" || return 1
    fi

    devilbox_stop

    mkdir -p "$project_path" || { print_error "Не удалось создать директорию."; return 1; }

    # --- Каркас по типу; при ошибке убираем созданную пустую директорию ---
    local scaffold_rc=0
    case "$cms_type" in
        wordpress)
            ( cd "$project_path" && _new_scaffold_wordpress "$project_name" "$project_path" "$php_version" "$use_theme" ) || scaffold_rc=1
            ;;
        joomla|opencart|ocstore)
            ( cd "$project_path" && _new_scaffold_archive_cms "$cms_type" "$project_name" "$project_path" "$php_version" ) || scaffold_rc=1
            ;;
        laravel)
            ( cd "$project_path" && _new_scaffold_laravel "$project_name" "$project_path" "$php_version" ) || scaffold_rc=1
            ;;
        php)
            ( cd "$project_path" && _new_scaffold_php "$project_name" "$project_path" "$php_version" ) || scaffold_rc=1
            ;;
        *)
            print_error "Внутренняя ошибка: неизвестный тип '$cms_type'."
            scaffold_rc=1
            ;;
    esac

    if [[ $scaffold_rc -ne 0 ]]; then
        print_error "Создание проекта провалилось. Чистим директорию..."
        rm -rf "$project_path"
        return 1
    fi

    if has_arg "db" && [[ "$cms_type" != "php" ]]; then
        _new_provision_db "$project_name" "$project_path" "$cms_type"
    fi

    print_separator
    print_highlight "Путь:        ${project_path}"
    print_highlight "URL:         ${site_url}"
    print_highlight "Следующий шаг: dpx tunnel --project-name ${project_name}"
    print_separator

    ddev_launch "$project_name"
    return 0
}
