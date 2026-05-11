#!/usr/bin/env bash
# =================================================================
# DPX Database Module - импорт, экспорт, замена URL
# Версия: v1.4.24 — Reorder tunnel steps, X-Forwarded-Host, nuke file cache
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_DATABASE_LOADED:-}" ]] && return 0
readonly _DPX_DATABASE_LOADED=1

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"

# =================================================================
# ЕДИНАЯ ТОЧКА ИЗВЛЕЧЕНИЯ db_prefix (v1.4.20)
#
# grep из wp-config.php — БЕЗ вызова PHP вообще.
# Валидация: только [a-zA-Z0-9_]. При невалидном — фатал.
# Все функции модуля используют ЭТУ функцию.
# =================================================================

db_get_prefix() {
    local project_path="$1"
    local config_file="${project_path}/wp-config.php"

    if [[ ! -f "$config_file" ]]; then
        print_error "db_get_prefix: wp-config.php не найден: $config_file" >&2
        return 1
    fi

    local prefix
    prefix=$(grep -E '^\s*\$table_prefix\s*=' "$config_file" 2>/dev/null \
        | grep -oE "['\"].*[\'\"]" | tr -d "'\"" | head -1)

    # Фолбек для стандартной установки
    [[ -z "$prefix" ]] && prefix="wp_"

    # Валидация: только буквы, цифры, подчёркивания
    if ! [[ "$prefix" =~ ^[a-zA-Z0-9_]+$ ]]; then
        print_error "db_get_prefix: невалидный префикс '${prefix}' (допускаются только a-zA-Z0-9_)" >&2
        return 1
    fi

    echo "$prefix"
}

# =================================================================
# SQL-ONLY: Чтение option из БД напрямую через ddev mysql
#
# НИКАКОГО WP-CLI. Чистый SQL к MySQL.
# Возвращает обрезанное значение через stdout.
#
# v1.4.21: ФИЛЬТРУЕМ PHP 8.5 Deprecated с stdout.
# ddev mysql запускает PHP через контейнер, и PHP 8.5
# выводит "Deprecated: Case statements..." на STDOUT
# (не stderr!). Поэтому 2>/dev/null НЕ помогает.
# Решение: grep -v '^Deprecated:' отсекает мусор.
# =================================================================

db_sql_get_option() {
    local project_path="$1"
    local option_name="$2"

    local prefix
    prefix=$(db_get_prefix "$project_path") || return 1

    local value
    value=$(cd "$project_path" && ddev mysql -N -B -e "SELECT option_value FROM ${prefix}options WHERE option_name='${option_name}';" 2>/dev/null \
        | grep -v '^Deprecated:' \
        | head -1)

    # Чистка от whitespace и \r
    value="${value// /}"
    value="${value%$'\r'}"
    value="${value%/}"

    echo "$value"
}

# =================================================================
# SQL-ONLY: Удаление transients по маске через ddev mysql
#
# Используется для Flatsome и других плагинов, чьи транзиенты
# нужно чистить без загрузки PHP/WP-CLI.
# v1.4.21: stderr подавлен, stdout не фильтруем (DELETE не
# возвращает данных, только affected rows).
# =================================================================

db_sql_delete_transients() {
    local project_path="$1"
    local mask="$2"  # например 'flatsome_%' или 'elementor_%'

    local prefix
    prefix=$(db_get_prefix "$project_path") || return 1

    (cd "$project_path" && ddev mysql -N -B -e "DELETE FROM ${prefix}options WHERE option_name LIKE '_transient_${mask}' OR option_name LIKE '_transient_timeout_${mask}';" 2>/dev/null) || true
}

# =================================================================
# SQL-ONLY: Подсчёт оставшихся старых URL в БД (debug)
#
# Сканирует wp_options и wp_postmeta на предмет старого URL.
# Используется для диагностики смешанных URL.
# =================================================================

db_sql_count_old_url() {
    local project_path="$1"
    local old_url="$2"

    local prefix
    prefix=$(db_get_prefix "$project_path") || return 1

    local count=0
    count=$(cd "$project_path" && ddev mysql -N -B -e "
        SELECT (
            SELECT COUNT(*) FROM ${prefix}options WHERE option_value LIKE '%${old_url}%'
        ) + (
            SELECT COUNT(*) FROM ${prefix}postmeta WHERE meta_value LIKE '%${old_url}%'
        );" 2>/dev/null \
        | grep -v '^Deprecated:' \
        | head -1)

    echo "${count:-0}"
}

# =================================================================
# ПУТИ
# =================================================================

get_db_prod_path() {
    get_config "db_prod_path"
}

get_db_local_path() {
    get_config "db_local_path"
}

# =================================================================
# ИМПОРТ И ЭКСПОРТ (БЕЗ ПРИНУДИТЕЛЬНОГО GZIP)
# =================================================================

db_import() {
    local sql_file="$1"
    local project_path="$2"

    [[ -n "$project_path" ]] && cd "$project_path" || return 1
    validate_file "$sql_file" "SQL файл" || return 1

    print_step "auto" "Импорт базы данных [$(basename "$sql_file")]"

    if ddev import-db --file="$sql_file" >/dev/null 2>&1; then
        print_success "База данных импортирована."
        return 0
    else
        print_error "Ошибка при импорте базы данных."
        return 1
    fi
}

db_export() {
    local output_file="$1"
    local project_path="$2"
    local gzip="${3:-false}"

    [[ -n "$project_path" ]] && cd "$project_path" || return 1
    ensure_directory "$(dirname "$output_file")"

    print_step "auto" "Экспорт базы данных..."

    if ddev export-db --gzip="$gzip" --file="$output_file" >/dev/null 2>&1; then
        print_success "Экспорт завершен: $(basename "$output_file")"
        return 0
    else
        print_error "Ошибка при экпорте базы данных."
        return 1
    fi
}

# =================================================================
# ЛОКАЛЬНЫЙ БЭКАП (Snap / Refresh Backup)
# =================================================================

db_backup_local() {
    local project_name="$1"
    local project_path="$2"
    local backup_dir="${3:-$(get_db_local_path)}"
    local tag="${4:-LOCAL_BACKUP}"

    ensure_directory "$backup_dir"

    local filename
    filename=$(db_generate_export_filename "$project_name" "$tag")
    local backup_file="${backup_dir}/${filename%.gz}"

    print_step "auto" "Создание резервной копии перед операцией..." >&2

    if db_export "$backup_file" "$project_path" "false" >&2; then
        echo "$backup_file"
        return 0
    else
        return 1
    fi
}

# =================================================================
# ИМПОРТ С ЗАМЕНОЙ URL (для не-WordPress проектов)
# =================================================================

db_import_with_replace() {
    local sql_file="$1"
    local old_url="$2"
    local new_url="$3"
    local project_path="$4"

    print_step "auto" "Подготовка SQL с заменой URL..."

    local temp_sql=$(create_temp_file).sql
    sed "s|${old_url}|${new_url}|g" "$sql_file" > "$temp_sql"

    print_info "URL заменены: $old_url -> $new_url"

    if db_import "$temp_sql" "$project_path"; then
        rm -f "$temp_sql"
        return 0
    else
        rm -f "$temp_sql"
        return 1
    fi
}

# =================================================================
# CLEAR CACHE — Ядерный сброс кэша WordPress (v1.4.24)
#
# WP-CLI используется ТОЛЬКО для cache flush.
# Добавлено физическое удаление статического файлового кэша (W3TC, WP Rocket).
# =================================================================

db_wp_clear_cache() {
    local project_path="$1"

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then return 1; fi

    # Шаг 1: Flatsome транзиенты через SQL
    (
        cd "$project_path" || exit 1
        ddev exec test -d /var/www/html/wp-content/themes/flatsome 2>/dev/null
    ) 2>/dev/null && {
        print_step "auto" "Flatsome transients cleanup (SQL)..." >&2
        db_sql_delete_transients "$project_path" "flatsome_%"
    }

    # Шаг 2: WP-CLI cache operations
    print_step "auto" "Удаление транзиентов и очистка кэша (Redis + WP-CLI)..." >&2
    (
        cd "$project_path" || exit 1
        ddev exec php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp transient delete --all --allow-root >/dev/null 2>&1
        ddev redis-cli flushall >/dev/null 2>&1
        ddev exec php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp cache flush --allow-root >/dev/null 2>&1
    ) || true

    # Шаг 3: Ядерная очистка статических файловых кэшей
    print_step "auto" "Очистка файлового кэша (W3TC, Hummingbird, WP Rocket)..." >&2
    (
        cd "$project_path" || exit 1
        ddev exec rm -rf /var/www/html/wp-content/cache/* 2>/dev/null
        ddev exec rm -rf /var/www/html/wp-content/wphb-cache/* 2>/dev/null
    ) || true
}

# =================================================================
# SNAPSHOT MANAGEMENT (v1.4.18)
# Смерть паранойи: доверяем DDEV exit code, не ищем файлы физически.
# =================================================================

db_create_snapshot() {
    local project_path="$1"
    local tag="${2:-dpx_tunnel}"

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then
        print_error "db_create_snapshot: директория проекта не указана." >&2
        return 1
    fi

    local snapshot_name="${tag}_$(date +%H%M%S)"
    print_step "auto" "Safety Snapshot: $snapshot_name..." >&2

    # Создаем снапшот, подавляем интерактив.
    # ВАЖНО: Если $? == 0, значит DDEV гарантирует, что снапшот есть.
    dpx_exec_and_log "$project_path" ddev snapshot --name="$snapshot_name" --yes >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        print_success "Snapshot создан: $snapshot_name" >&2
        echo "$snapshot_name" # Возвращаем имя для caller'а
        return 0
    else
        print_error "CRITICAL: Snapshot creation failed! Мутация БД БЛОКИРОВАНА." >&2
        return 1
    fi
}

# Восстанавливает БД из ddev snapshot.
# Все UI → stderr. Ничего не возвращает через stdout.
#
# АРГУМЕНТЫ:
#   $1 — project_path
#   $2 — snapshot_name
db_restore_snapshot() {
    local project_path="$1"
    local snapshot_name="$2"

    if [[ -z "$project_path" ]]; then
        print_error "db_restore_snapshot: директория проекта не указана."
        return 1
    fi

    if [[ -z "$snapshot_name" ]]; then
        print_error "db_restore_snapshot: имя снапшота не указано."
        return 1
    fi

    print_step "auto" "Восстановление БД из snapshot: $snapshot_name..."
    (
        cd "$project_path" || exit 1
        ddev snapshot restore "$snapshot_name" 2>&1 \
            | grep -vE "PHP Deprecated|Deprecated:"
    ) >&2
    local restore_result=$?

    if [[ $restore_result -eq 0 ]]; then
        print_success "БД восстановлена из snapshot: $snapshot_name"
        return 0
    else
        print_error "Не удалось восстановить snapshot: $snapshot_name"
        print_error "Выполните вручную: ddev snapshot restore $snapshot_name"
        return 1
    fi
}

# =================================================================
# SMART REPLACE TUNNEL (v1.4.23) — Основной движок миграции
#
# АРХИТЕКТУРА:
#   - Снапшот создается ВНЕ этой функции (Атомарность сессии)
#   - db_prefix извлекается ЧЕРЕЗ db_get_prefix() (ЕДИНСТВЕННАЯ точка)
#   - Валидация ТОЛЬКО через SQL (db_sql_get_option)
#   - Flatsome транзиенты чистятся через SQL (без WP-CLI)
#   - WP-CLI используется ТОЛЬКО для search-replace (сериализация)
#
# v1.4.23 — ТРИ ПРОХОДА: HTTPS -> HTTP -> Bare Domain
#   Причина: protocol-relative (//domain) НЕ ловит голые домены
#   в настройках меню и билдеров (Flatsome, Elementor).
#
#   Правильный порядок (безопасный):
#     1. https://OLD → https://NEW  (точный HTTPS)
#     2. http://OLD  → https://NEW  (HTTP → HTTPS, туннель всегда HTTPS)
#     3. OLD       → NEW          (голый домен — ловит меню, билдеры)
#
#   Первые два прохода вычищают все вхождения с протоколами,
#   третий проход безопасно заменяет всё оставшееся без риска
#   создать двойные протоколы (https://https://...).
#
#   DEBUG: каждый проход выводит результат wp search-replace
#   (включая количество замен) в debug.log.
# =================================================================

db_smart_replace_tunnel() {
    local old_url="$1"
    local new_url="$2"
    local project_path="$3"

    if [[ -z "$old_url" || -z "$new_url" || -z "$project_path" ]]; then return 1; fi
    if [[ "$old_url" == "$new_url" ]]; then return 0; fi

    # Единая точка извлечения префикса
    local db_prefix
    db_prefix=$(db_get_prefix "$project_path") || {
        print_error "Не удалось извлечь db_prefix. Остановка!" >&2
        return 1
    }

    local snapshot_name
    snapshot_name=$(db_create_snapshot "$project_path")
    local snap_rc=$?

    if [[ $snap_rc -ne 0 || -z "$snapshot_name" ]]; then
        print_error "Не удалось создать Safety Snapshot. Остановка!" >&2
        return 1
    fi

    echo "" >&2
    print_info "${COLOR_BOLD}${COLOR_YELLOW}[WAIT]${COLOR_RESET} Глубокая миграция БД (--precise). Это займет время..." >&2

    # Извлекаем голые домены для построения точных проходов
    local old_bare
    old_bare=$(echo "$old_url" | sed 's|https\?://||;s|/$||')
    local new_bare
    new_bare=$(echo "$new_url" | sed 's|https\?://||;s|/$||')

    local replace_rc=0
    local replace_output=""

    # ==================================================================
    # ПРОХОД 1: HTTPS точный
    # https://grandmebel.lo → https://cloudflare...
    # ==================================================================
    print_step "auto" "[1/3] Замена HTTPS: $old_url -> $new_url" >&2
    replace_output=$(
        cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
        /usr/local/bin/wp search-replace "$old_url" "$new_url" \
        --all-tables --precise --allow-root \
        2>/dev/null | grep -vE '^Deprecated:'
    )
    replace_rc=$?
    # Логируем результат (даже если пустой)
    echo "[DEBUG] Pass 1 (HTTPS): rc=$replace_rc output=${replace_output:-'(empty)'}" >> "${project_path}/.dpx/debug.log" 2>/dev/null
    if [[ -n "$replace_output" ]]; then
        print_info "  → $replace_output" >&2
    fi

    if [[ $replace_rc -ne 0 ]]; then
        print_error "Ошибка замены HTTPS (проход 1)." >&2
        [[ -n "$snapshot_name" ]] && db_restore_snapshot "$project_path" "$snapshot_name"
        return 1
    fi

    sleep 1; sync 2>/dev/null || true

    # ==================================================================
    # ПРОХОД 2: HTTP → HTTPS
    # http://grandmebel.lo → https://cloudflare...
    # Туннель всегда HTTPS, поэтому HTTP-ссылки конвертируем.
    # ==================================================================
    local old_http="http://${old_bare}"
    # Только если old_url был HTTPS (стандартный случай DDEV)
    if [[ "$old_url" == https://* && -n "$old_bare" ]]; then
        print_step "auto" "[2/3] Замена HTTP→HTTPS: $old_http -> $new_url" >&2
        replace_output=$(
            cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
            /usr/local/bin/wp search-replace "$old_http" "$new_url" \
            --all-tables --precise --allow-root \
            2>/dev/null | grep -vE '^Deprecated:'
        )
        replace_rc=$?
        echo "[DEBUG] Pass 2 (HTTP): rc=$replace_rc output=${replace_output:-'(empty)'}" >> "${project_path}/.dpx/debug.log" 2>/dev/null
        if [[ -n "$replace_output" ]]; then
            print_info "  → $replace_output" >&2
        fi
        sleep 1; sync 2>/dev/null || true
    else
        print_info "[2/3] Пропущен (old_url не HTTPS)" >&2
    fi

    # ==================================================================
    # ПРОХОД 3: Голый домен (без протокола)
    # Ловит меню, настройки билдеров и сериализованные массивы
    # ==================================================================
    if [[ -n "$old_bare" && "$old_bare" != "$new_bare" ]]; then
        print_step "auto" "[3/3] Замена голого домена: $old_bare -> $new_bare" >&2
        replace_output=$(
            cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
            /usr/local/bin/wp search-replace "$old_bare" "$new_bare" \
            --all-tables --precise --allow-root \
            2>/dev/null | grep -vE '^Deprecated:'
        )
        replace_rc=$?
        echo "[DEBUG] Pass 3 (Bare): rc=$replace_rc output=${replace_output:-'(empty)'}" >> "${project_path}/.dpx/debug.log" 2>/dev/null
        if [[ -n "$replace_output" ]]; then
            print_info "  → $replace_output" >&2
        fi
        sleep 1; sync 2>/dev/null || true
    fi

    # Чистим кэш ПЕРЕД валидацией (Flatsome через SQL, остальное через WP-CLI)
    db_wp_clear_cache "$project_path"

    # ==================================================================
    # ДИАГНОСТИКА: подсчёт оставшихся старых URL (debug)
    # ==================================================================
    local remaining=0
    remaining=$(db_sql_count_old_url "$project_path" "$old_bare")
    echo "[DEBUG] Remaining old_url ('$old_bare') in DB: $remaining" >> "${project_path}/.dpx/debug.log" 2>/dev/null
    if (( remaining > 0 )); then
        print_warning "Диагностика: в БД осталось $remaining вхождений старого URL (подробности в .dpx/debug.log)" >&2
    fi

    # СТРОГО SQL ВАЛИДАЦИЯ — никакого WP-CLI!
    print_info "Валидация: прямой SQL-запрос к БД (ddev mysql)..." >&2

    local actual_url="" attempt=0
    while (( attempt < 3 )); do
        actual_url=$(db_sql_get_option "$project_path" "home") || actual_url=""

        if [[ -n "$actual_url" && "$actual_url" == *"$new_bare"* ]]; then
            print_success "Валидация OK: SQL home = $actual_url" >&2
            break
        fi

        ((attempt++))
        if (( attempt < 3 )); then
            print_warning "БД в процессе записи (попытка $attempt/3). Ждём 2 сек..." >&2
            sleep 2; sync 2>/dev/null || true
        fi
    done

    # FAIL-SAFE: ФАТАЛЬНАЯ ОСТАНОВКА
    if [[ "$actual_url" != *"$new_bare"* ]]; then
        print_error "ФАТАЛЬНАЯ ОШИБКА: SQL-валидация провалилась!" >&2
        print_error "Ожидалось: *$new_bare*, получено из БД: $actual_url" >&2
        print_error "SQL: SELECT option_value FROM ${db_prefix}options WHERE option_name='home';" >&2
        [[ -n "$snapshot_name" ]] && db_restore_snapshot "$project_path" "$snapshot_name"
        return 1
    fi

    echo "$snapshot_name"
}

# =================================================================
# SMART REPLACE — Общая миграция URL (v1.4.23)
#
# Универсальная функция для экспорта на продакшен и ручной
# миграции. Не включает очистку кэша (caller решает).
# WP-CLI с PHP-изоляцией для search-replace.
#
# v1.4.23: Три прохода — HTTPS -> HTTP -> Bare Domain.
# =================================================================

db_wp_smart_replace() {
    local old_url="$1"
    local new_url="$2"
    local project_path="$3"

    if [[ -z "$old_url" || -z "$new_url" || -z "$project_path" ]]; then
        print_error "db_wp_smart_replace: не указаны аргументы (old_url new_url project_path)."
        return 1
    fi

    if [[ ! -d "$project_path" ]]; then
        print_error "db_wp_smart_replace: директория проекта не найдена: $project_path"
        return 1
    fi

    if [[ "$old_url" == "$new_url" ]]; then
        print_info "old_url и new_url совпадают ($old_url). Замена пропущена."
        return 0
    fi

    # Safety Snapshot
    local snapshot_name="pre_replace_$(date +%s)"
    print_step "auto" "Safety Snapshot: $snapshot_name..."
    (
        cd "$project_path" || exit 1
        ddev snapshot --name="$snapshot_name" --yes >/dev/null 2>&1
    )
    if [[ $? -eq 0 ]]; then
        print_success "Safety Snapshot создан: $snapshot_name"
    else
        print_warning "Не удалось создать snapshot. Продолжаем без страховки."
    fi

    # Warning
    print_info "Внимание: глубокая замена (--precise) на больших базах может занять до 1 минуты."

    # Извлекаем голые домены для трёх точных проходов
    local old_bare_domain
    old_bare_domain=$(echo "$old_url" | sed 's|https\?://||;s|/$||')
    local new_bare_domain
    new_bare_domain=$(echo "$new_url" | sed 's|https\?://||;s|/$||')

    # Проход 1: HTTPS точный
    print_step "auto" "[1/3] Замена HTTPS: $old_url -> $new_url"
    (
        cd "$project_path" || exit 1
        ddev exec php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp search-replace \
            "$old_url" "$new_url" \
            --all-tables --precise --allow-root 2>&1 \
            | grep -vE 'PHP Deprecated|Deprecated:|^$'
    )
    if [[ $? -ne 0 ]]; then
        print_error "Ошибка замены полного URL."
        return 1
    fi

    # Проход 2: HTTP → HTTPS
    if [[ "$old_url" == https://* && -n "$old_bare_domain" ]]; then
        print_step "auto" "[2/3] Замена HTTP→HTTPS: http://${old_bare_domain} -> $new_url"
        (
            cd "$project_path" || exit 1
            ddev exec php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp search-replace \
                "http://${old_bare_domain}" "$new_url" \
                --all-tables --precise --allow-root 2>&1 \
                | grep -vE 'PHP Deprecated|Deprecated:|^$'
        ) || print_warning "Замена HTTP→HTTPS завершена с ошибкой."
    fi

    # Проход 3: Голый домен
    if [[ -n "$old_bare_domain" ]]; then
        print_step "auto" "[3/3] Замена голого домена: ${old_bare_domain} -> ${new_bare_domain}"
        (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp search-replace "${old_bare_domain}" "${new_bare_domain}" --all-tables --precise --allow-root 2>&1 | grep -vE 'PHP Deprecated|Deprecated:|^$') || true
    fi

    print_success "Тройная замена URL завершена."
    return 0
}

# =================================================================
# WP-CLI ЭКСПОРТ С БЕЗОПАСНОЙ ЗАМЕНОЙ (v1.4.21)
#
# Использует db_wp_smart_replace (--precise + triple-pass).
# =================================================================

db_wp_export_safe() {
    local output_file="$1"
    local local_url="$2"
    local prod_url="$3"
    local project_path="$4"

    [[ -n "$project_path" ]] && cd "$project_path" || return 1

    print_step "auto" "Экспорт с заменой URL для продакшена..."

    if ! db_wp_smart_replace "$local_url" "$prod_url" "$project_path"; then
        print_error "Не удалось выполнить замену URL перед экспортом."
        return 1
    fi

    db_wp_clear_cache "$project_path"

    if ddev export-db --file="$output_file" >/dev/null 2>&1; then
        print_success "База экспортирована: $(basename "$output_file")"

        if ! db_wp_smart_replace "$prod_url" "$local_url" "$project_path"; then
            print_error "КРИТИЧЕСКАЯ ОШИБКА: не удалось вернуть URL обратно!"
            print_error "Выполните вручную: ddev snapshot restore <имя_снапшота>"
            return 1
        fi

        db_wp_clear_cache "$project_path"
        print_info "URL в локальной базе восстановлены."
        return 0
    else
        print_error "Ошибка экспорта базы."
        print_warning "Попытка восстановления URL после ошибки экспорта..."
        db_wp_smart_replace "$prod_url" "$local_url" "$project_path" || true
        db_wp_clear_cache "$project_path" 2>/dev/null || true
        return 1
    fi
}

# =================================================================
# ВСПОМОГАТЕЛЬНЫЕ
# =================================================================

db_get_prod_filepath() {
    local filename="$1"
    local base_path=$(get_db_prod_path)
    echo "${base_path}/${filename}.sql"
}

db_generate_export_filename() {
    local project_name="$1"
    local suffix="${2:-FROM_LOCAL}"
    local tag=$(echo "$suffix" | tr '[:lower:]' '[:upper:]')
    local ts=$(date +"%y%m%d_%H%M")
    echo "${project_name}_${tag}_${ts}.sql"
}

# =================================================================
# ЭКСПОРТ ФУНКЦИЙ
# =================================================================

export -f get_db_prod_path get_db_local_path db_import db_export
export -f db_backup_local db_import_with_replace db_wp_export_safe
export -f db_wp_smart_replace db_wp_clear_cache
export -f db_create_snapshot db_restore_snapshot db_smart_replace_tunnel
export -f db_get_prod_filepath db_generate_export_filename
export -f db_get_prefix db_sql_get_option db_sql_delete_transients
export -f db_sql_count_old_url
