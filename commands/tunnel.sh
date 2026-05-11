#!/usr/bin/env bash
# =================================================================
# DPX Command: tunnel - проброс туннеля для показа проекта заказчику
# Провайдеры: cloudflared (рабочий), ngrok (заглушка)
# Архитектура: DPX_SMART_TUNNEL — самоактивирующийся блок
# Версия: v1.4.21 — Fix mixed URLs, ddev mysql Deprecated leak
# =================================================================

# Подключаем модули
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"

# =================================================================
# КОНСТАНТЫ
# =================================================================

readonly TUNNEL_MARKER_START="/** DPX_SMART_TUNNEL */"
readonly TUNNEL_MARKER_END="/** END_DPX_SMART_TUNNEL */"
readonly TUNNEL_PROVIDER_CLOUDFLARE="cloudflare"
readonly TUNNEL_PROVIDER_NGROK="ngrok"
readonly WP_CONFIG_PROTECTED_TAIL=10

# =================================================================
# CROSS-PLATFORM PATH NORMALIZATION (v1.4.11)
# =================================================================

# Нормализует путь, разрешая симлинки.
# Приоритет: realpath (GNU/coreutils) → greadlink (macOS+brew) → readlink -f (Linux) → as-is.
_dpx_realpath() {
    local target="$1"
    if [[ -z "$target" ]]; then echo ""; return 0; fi
    if command -v realpath >/dev/null 2>&1; then
        realpath -- "$target" 2>/dev/null
    elif command -v greadlink >/dev/null 2>&1; then
        greadlink -f -- "$target" 2>/dev/null
    elif command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
        readlink -f -- "$target" 2>/dev/null
    else
        echo "$target"
    fi
}

# =================================================================
# СПРАВКА
# =================================================================

show_tunnel_help() {
    cat << EOF
 ${COLOR_BOLD}tunnel${COLOR_RESET} - Проброс туннеля для показа проекта заказчику

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} tunnel [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Создает публичный туннель к локальному DDEV-проекту.
    Для WordPress автоматически:
      - Внедряет DPX_SMART_TUNNEL блок в wp-config.php (сразу
        после <?php тега). Блок самоактивируется, когда
        hostname не совпадает с локальным DDEV-доменом (.lo),
        и безопасно игнорируется в локальном режиме.
      - Заменяет URL в БД через wp search-replace.
    При завершении (Ctrl+C) выполняется полный откат:
    восстановление wp-config.php из снапшота (mv -f), возврат URL в БД.

 ${COLOR_BOLD}Интеллектуальный контекст:${COLOR_RESET}
    Если команда запущена из папки DDEV-проекта (или поддиректории),
    проект определяется автоматически через ddev describe.

 ${COLOR_BOLD}Провайдеры:${COLOR_RESET}
    cloudflare  — Cloudflare Tunnel (cloudflared) [рабочий]
    ngrok       — ngrok [заглушка, не реализован]

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --project-name NAME    Имя проекта DDEV
    --cms-type TYPE        Тип CMS (wordpress, joomla, opencart, php)
    --provider PROVIDER    Провайдер туннеля (cloudflare, ngrok)
    -y, --yes              Пропустить подтверждения
    -h, --help             Показать эту справку

 ${COLOR_BOLD}Требования:${COLOR_RESET}
    cloudflared — https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
    jq          — для парсинга ddev describe -j

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} tunnel
    ${TOOL_NAME} tunnel --project-name mysite
    ${TOOL_NAME} tunnel --project-name mysite --cms-type wordpress -y
    ${TOOL_NAME} tunnel --provider cloudflare --project-name mysite
EOF
}

# =================================================================
# УРОВЕНЬ 0: WP-CLI EXECUTOR
# =================================================================

tunnel_wp_exec() {
    local project_path="$1"
    shift

    local wp_cmd="php -d display_errors=0 -d error_reporting=0 /usr/local/bin/wp"
    local arg
    for arg in "$@"; do
        local escaped_arg="${arg//\'/\'\\\'\'}"
        wp_cmd+=" '${escaped_arg}'"
    done

    (
        cd "$project_path" || exit 1
        ddev exec "$wp_cmd" 2>/dev/null
    )
}

# =================================================================
# УРОВЕНЬ 0.1: BUILDER DETECTORS (v1.4.20)
# =================================================================

# Проверяет наличие плагина Elementor в проекте.
# Elementor кэширует CSS файлы отдельно от WP object cache —
# без flush-css стили могут оставаться старыми.
# Проверка через test -d (быстро, без инициализации WP-CLI).
tunnel_has_elementor() {
    local project_path="$1"
    (
        cd "$project_path" || exit 1
        ddev exec test -d /var/www/html/wp-content/plugins/elementor 2>/dev/null
    ) 2>/dev/null
}

# Проверяет наличие темы Flatsome.
# Flatsome хранит транзиенты и CSS-кэш со старыми URL.
# Транзиенты чистятся через SQL, CSS-кэш — через rm.
tunnel_has_flatsome() {
    local project_path="$1"
    (
        cd "$project_path" || exit 1
        ddev exec test -d /var/www/html/wp-content/themes/flatsome 2>/dev/null
    ) 2>/dev/null
}

# =================================================================
# УРОВЕНЬ 1: ПРОВАЙДЕРЫ ТУННЕЛЕЙ
# =================================================================

tunnel_detect_providers() {
    local -a available=()
    if command -v cloudflared >/dev/null 2>&1; then
        available+=("$TUNNEL_PROVIDER_CLOUDFLARE")
    fi
    if command -v ngrok >/dev/null 2>&1; then
        available+=("$TUNNEL_PROVIDER_NGROK")
    fi
    printf '%s\n' "${available[@]}"
}

tunnel_select_provider() {
    local preferred="${1:-}"
    if [[ -n "$preferred" ]]; then
        echo "$preferred"
        return 0
    fi

    local providers
    providers=$(tunnel_detect_providers)
    local count
    count=$(echo "$providers" | wc -l)
    count="${count// /}"

    if (( count == 0 )); then
        return 1
    elif (( count == 1 )); then
        echo "$providers" | head -1
        return 0
    else
        print_header "Выберите провайдер туннеля"
        local i=1
        while IFS= read -r prov; do
            echo "  $i. $prov" >&2
            ((i++))
        done <<< "$providers"
        local choice
        read -r -p "Выберите [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            echo "$providers" | sed -n "${choice}p"
            return 0
        else
            return 1
        fi
    fi
}

tunnel_cloudflare_check() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        print_error "cloudflared не найден."
        print_info "Установка: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        return 1
    fi
    print_success "cloudflared найден: $(cloudflared --version 2>&1 | head -1)"
    return 0
}

tunnel_cloudflare_start() {
    local target_url="$1"
    local log_file="$2"
    local host_header="${3:-}"

    # Собираем команду cloudflared
    local -a cf_cmd=(cloudflared tunnel --url "$target_url")

    # КРИТИЧЕСКИ ВАЖНО: передаём Host-заголовок для Traefik.
    # Без него Traefik (маршрутизатор DDEV) не знает, какому
    # проекту отдать запрос, и возвращает 404.
    if [[ -n "$host_header" ]]; then
        cf_cmd+=(--http-host-header "$host_header")
    fi

    "${cf_cmd[@]}" > "$log_file" 2>&1 &
    local pid=$!

    print_info "cloudflared запущен (PID: $pid)..."
    print_info "Ожидание URL туннеля..."

    local tunnel_url=""
    local max_wait=30
    local waited=0

    while (( waited < max_wait )); do
        if [[ -f "$log_file" ]]; then
            tunnel_url=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1)
            if [[ -n "$tunnel_url" ]]; then break; fi
        fi
        sleep 1
        ((waited++))
        printf "." >&2
    done
    echo "" >&2

    if [[ -z "$tunnel_url" ]]; then
        print_error "Не удалось получить URL туннеля за ${max_wait} секунд."
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
        return 1
    fi

    _DPX_TUNNEL_PID="$pid"
    _DPX_TUNNEL_URL="$tunnel_url"
    print_success "Туннель создан: $tunnel_url"
    return 0
}

tunnel_cloudflare_stop() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_info "Остановка cloudflared (PID: $pid)..."
        kill "$pid" 2>/dev/null
        local wait_count=0
        while kill -0 "$pid" 2>/dev/null && (( wait_count < 10 )); do
            sleep 0.5
            ((wait_count++))
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
        print_success "cloudflared остановлен."
    fi
}

tunnel_ngrok_check()  { print_warning "ngrok: не реализован."; return 1; }
tunnel_ngrok_start()  { print_error "ngrok: не реализовано."; return 1; }
tunnel_ngrok_stop()   { :; }

tunnel_provider_check() {
    local provider="$1"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_check ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_check ;;
        *) print_error "Неизвестный провайдер: $provider"; return 1 ;;
    esac
}

tunnel_provider_start() {
    local provider="$1" target_url="$2" log_file="$3" host_header="$4"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_start "$target_url" "$log_file" "$host_header" ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_start "$target_url" "$log_file" ;;
        *) return 1 ;;
    esac
}

tunnel_provider_stop() {
    local provider="$1" pid="$2"
    case "$provider" in
        "$TUNNEL_PROVIDER_CLOUDFLARE") tunnel_cloudflare_stop "$pid" ;;
        "$TUNNEL_PROVIDER_NGROK")      tunnel_ngrok_stop "$pid" ;;
    esac
}

# =================================================================
# УРОВЕНЬ 2: ИНФРАСТРУКТУРА — DDEV & WP
#
# 2026 DDEV API Standards:
#   - .raw.services.web.host_ports_mapping — массив объектов (DDEV 2026+)
#     [{"exposed_port":"80","host_port":32768}] → select exposed_port==80
#   - .raw.services.web.host_ports — массив маппингов (DDEV 2025)
#     ["80:32768", "443:32769"] или ["80/tcp:32768"]
#     select(contains("80")) | split(":")[1] → хост-порт
#   - .raw.primary_url — основной домен проекта
#     https://grandmebel.lo → grandmebel.lo
# =================================================================

# Получает динамический хост-порт для контейнерного 80.
# DDEV маппит контейнерный порт 80 на динамический хост-порт
# (например, 80→32768, 443→32769). После каждого ddev restart
# порты могут меняться — поэтому всегда читаем из API.
#
# Формат host_ports (2026 DDEV): массив ["80:32768", "443:32769"]
#   .[] | select(contains("80"))  — фильтруем маппинг порта 80
#   split(":")[1]                 — берём хостовую часть
#
# Фолбек-цепочка (5 методов):
#   1. host_ports_mapping через jq select(exposed_port == 80) — DDEV 2026+ (object schema)
#   2. host_ports через jq select(contains("80")) — DDEV 2025 (string array)
#   3. host_ports через jq split(",")[0] (legacy-формат "32768,32769")
#   4. Парсинг из httpURLs[0]
#   5. Парсинг из httpsURLs[0]
tunnel_get_http_port() {
    local project_name="$1"

    # Способ 1 (DDEV 2026+): host_ports_mapping как массив объектов
    # [{"exposed_port":"80","host_port":32768},{"exposed_port":"443","host_port":32769}]
    local current_port
    current_port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.services.web.host_ports_mapping[]? | select(.exposed_port == "80" or .exposed_port == 80) | .host_port // empty' 2>/dev/null \
        | head -1)

    if [[ -n "$current_port" ]] && [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port > 0 )); then
        echo "$current_port"
        return 0
    fi

    # Способ 2 (DDEV 2025): host_ports как массив ["80:32768", "443:32769"]
    # Ищем маппинг контейнерного 80, забираем хост-порт
    current_port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.services.web.host_ports | .[] | select(contains("80")) | split(":")[-1] // empty' 2>/dev/null \
        | head -1)

    if [[ -n "$current_port" ]] && [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port > 0 )); then
        echo "$current_port"
        return 0
    fi

    # Способ 3 (legacy): host_ports как строка "32768,32769"
    current_port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.services.web.host_ports | split(",")[0] // empty' 2>/dev/null)

    if [[ -n "$current_port" ]] && [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port > 0 )); then
        echo "$current_port"
        return 0
    fi

    # Способ 4: Парсинг из httpURLs[0]
    local port
    port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.httpURLs[0] // empty' 2>/dev/null \
        | grep -oE ':[0-9]+' | tr -d ':' | head -1)
    if [[ -n "$port" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    # Способ 5: Парсинг из httpsURLs[0]
    port=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.httpsURLs[0] // empty' 2>/dev/null \
        | grep -oE ':[0-9]+' | tr -d ':' | head -1)
    if [[ -n "$port" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    # Фолбек
    print_warning "Не удалось определить хост-порт. Фолбек: 80"
    echo "80"
}

# Получает локальный домен проекта из DDEV API.
# primary_url = "https://grandmebel.lo" → "grandmebel.lo"
# Без хардкода — работает с любым project_tld.
tunnel_get_local_domain() {
    local project_name="$1"
    local local_domain
    local_domain=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.raw.primary_url // empty' 2>/dev/null \
        | sed 's|https://||;s|http://||')

    if [[ -z "$local_domain" ]]; then
        # Фолбек: конструируем из имени + TLD из конфига
        local project_tld
        project_tld=$(get_config "project_tld")
        local_domain="${project_name}.${project_tld}"
        print_warning "primary_url не получен. Фолбек: $local_domain"
    fi

    echo "$local_domain"
}

# URL с фолбеком: primary_endpoint → httpsURLs → httpURLs → имя+tld
tunnel_get_target_url() {
    local project_name="$1"
    local project_url
    project_url=$(ddev describe "$project_name" -j 2>/dev/null \
        | jq -r '.primary_endpoint // .raw.httpsURLs[0] // .raw.httpURLs[0] // empty' 2>/dev/null)
    if [[ -z "$project_url" ]]; then
        local project_tld
        project_tld=$(get_config "project_tld")
        project_url="https://${project_name}.${project_tld}"
        print_warning "URL из ddev describe не получен. Фолбек: $project_url"
    fi
    echo "$project_url"
}

# =================================================================
# УРОВЕНЬ 2.1: ПАТЧИНГ wp-config.php — DPX_SMART_TUNNEL
#            Snapshot-Rollback Protocol (v1.4.5)
#
# АРХИТЕКТУРНЫЕ ПРАВИЛА v1.4.5:
#   1. Снапшот — СТРОГО Шаг №1, ДО любых касаний файла
#   2. diff -q валидация: снапшот побайтово идентичен оригиналу
#   3. mv проверяется на exit code — при ошибке откат из снапшота
#   4. Post-Rollback: после mv -f проверяем, что DPX_SMART_TUNNEL исчез
#   5. tunnel_unpatch: если снапшота нет — файл НЕ менялся, фолбек
#      awk только для зависших блоков от старых версий dpx
#   6. Все print_* → stderr, echo → stdout (чистые данные)
# =================================================================

tunnel_is_config_patched() {
    local config_file="$1"
    [[ -f "$config_file" ]] && grep -q "DPX_SMART_TUNNEL" "$config_file" 2>/dev/null
}

tunnel_has_old_markers() {
    local config_file="$1"
    [[ -f "$config_file" ]] && grep -qE "DPX_TUNNEL_FIX|DPX_TUNNEL_START|DPX_TUNNEL_END" "$config_file" 2>/dev/null
}

tunnel_config_tail_intact() {
    local config_file="$1"
    [[ -f "$config_file" ]] && tail -n "$WP_CONFIG_PROTECTED_TAIL" "$config_file" | grep -q "wp-settings.php" 2>/dev/null
}

# Очистка старых блоков (вызывается ТОЛЬКО после создания снапшота!)
tunnel_cleanup_old_patches() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then return 0; fi
    if ! tunnel_has_old_markers "$config_file" && ! tunnel_is_config_patched "$config_file"; then return 0; fi

    print_info "Обнаружены старые блоки DPX. Вычищаем..."
    local temp_file
    temp_file=$(create_temp_file)

    awk '
        /DPX_TUNNEL_FIX[^_]/ || /DPX_TUNNEL_START/ || /DPX_SMART_TUNNEL/ { skip=1; next }
        /END_DPX_TUNNEL_FIX/ || /DPX_TUNNEL_END/   || /END_DPX_SMART_TUNNEL/ { skip=0; next }
        !skip { print }
    ' "$config_file" > "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        print_error "Ошибка очистки: пустой результат. Файл не перезаписан."
        rm -f "$temp_file"
        return 1
    fi

    mv "$temp_file" "$config_file"

    if ! tunnel_has_old_markers "$config_file" && ! tunnel_is_config_patched "$config_file"; then
        print_success "Старые блоки DPX удалены."
        return 0
    else
        print_warning "Не удалось полностью очистить старые блоки."
        return 1
    fi
}

tunnel_backup_wp_config() {
    local config_file="$1"
    dpx_wp_config_snapshot "$config_file"
}

tunnel_restore_wp_config() {
    local config_file="$1"
    dpx_wp_config_rollback "$config_file"
}

tunnel_verify_config_integrity() {
    local project_path="$1"
    local config_file="$2"
    print_info "Проверка целостности wp-config.php через WP-CLI..."
    local wp_version
    wp_version=$(tunnel_wp_exec "$project_path" core version --quiet 2>/dev/null)
    if [[ -n "$wp_version" ]]; then
        print_success "wp-config.php цел: WordPress $wp_version"
        return 0
    else
        print_error "wp-config.php повреждён! WP-CLI не может прочитать конфиг."
        if tunnel_restore_wp_config "$config_file"; then
            wp_version=$(tunnel_wp_exec "$project_path" core version --quiet 2>/dev/null)
            if [[ -n "$wp_version" ]]; then
                print_success "Конфиг восстановлен. WordPress $wp_version"
                return 0
            else
                print_error "Восстановленный конфиг также неработоспособен!"
                return 1
            fi
        else
            print_error "Бэкап недоступен. Требуется ручное исправление!"
            return 1
        fi
    fi
}

# =================================================================
# Патч wp-config.php: внедрение DPX_SMART_TUNNEL блока
#
# ПОРЯДОК ОПЕРАЦИЙ (v1.4.5 — атомарный + diff):
#   1. cp → .wp-config.php.dpx_bak  (ПЕРВЫМ ДЕЛОМ!)
#   2. [ -f ] + [ -s ] проверка бэкапа
#   3. diff -q — побайтовая идентичность (ловит RSSSL)
#   4. Проверка хвоста
#   5. Очистка старых блоков (теперь безопасно — есть снапшот)
#   6. Идемпотентность
#   7. Поиск <?php (гибкий — подстрока)
#   8. Сборка нового конфига
#   9. mv С ПРОВЕРКОЙ EXIT CODE — при ошибке откат
#  10. php -l валидация — при ошибке откат
#  11. Верификация маркера + хвоста
# =================================================================
# =================================================================
# Патч wp-config.php: внедрение DPX_SMART_TUNNEL блока (v1.4.24)
# =================================================================
tunnel_patch_wp_config() {
    local config_file="$1"
    local local_tld="${2:-lo}"

    if [[ ! -f "$config_file" ]]; then
        print_warning "wp-config.php не найден. Пропускаем патчинг."
        return 0
    fi

    local backup_file
    backup_file=$(tunnel_backup_wp_config "$config_file") || {
        print_error "Сбой создания снапшота. Патч ОТМЕНЁН. Оригинал не изменён."
        return 1
    }

    if [[ ! -f "$backup_file" ]]; then
        print_error "Снапшот не создался! Файл отсутствует: $backup_file"
        return 1
    fi

    if ! tunnel_config_tail_intact "$config_file"; then
        print_error "wp-config.php повреждён (отсутствует wp-settings.php)."
        dpx_wp_config_cleanup "$config_file"
        return 1
    fi

    if ! tunnel_cleanup_old_patches "$config_file"; then
        print_error "Ошибка очистки старых блоков. Откат из снапшота..."
        tunnel_restore_wp_config "$config_file" || true
        return 1
    fi

    if tunnel_is_config_patched "$config_file"; then
        return 0
    fi

    local php_tag_line
    php_tag_line=$(grep -n '<?php' "$config_file" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$php_tag_line" ]]; then
        print_error "Тег <?php не найден."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local total_lines
    total_lines=$(wc -l < "$config_file")
    total_lines="${total_lines// /}"

    local protected_start=$((total_lines - WP_CONFIG_PROTECTED_TAIL + 1))
    if (( php_tag_line >= protected_start )); then
        print_error "Тег <?php в защищённой зоне хвоста."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local block_file
    block_file=$(create_temp_file)
    cat <<BLOCK_EOF > "$block_file"

/** DPX_SMART_TUNNEL */
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}

// Cloudflare/ngrok pass the original requested host via X-Forwarded-Host.
// We overwrite HTTP_HOST so WordPress natively generates correct URLs.
if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) {
    \$_SERVER['HTTP_HOST'] = \$_SERVER['HTTP_X_FORWARDED_HOST'];
}

if (isset(\$_SERVER['HTTP_HOST']) && substr(\$_SERVER['HTTP_HOST'], -strlen('.${local_tld}')) !== '.${local_tld}') {
    if (!defined('WP_HOME'))   define('WP_HOME', 'https://' . \$_SERVER['HTTP_HOST']);
    if (!defined('WP_SITEURL')) define('WP_SITEURL', 'https://' . \$_SERVER['HTTP_HOST']);
}
/** END_DPX_SMART_TUNNEL */
BLOCK_EOF

    local temp_file
    temp_file=$(create_temp_file)
    head -n "$php_tag_line" "$config_file" > "$temp_file"
    cat "$block_file" >> "$temp_file"
    tail -n +$((php_tag_line + 1)) "$config_file" >> "$temp_file"
    rm -f "$block_file"

    # Guard existing bare define('WP_HOME'/'WP_SITEURL') with !defined().
    # Prevents "constant already defined" PHP 9 warning when DPX block
    # defines them first (tunnel active), then DDEV/prod block tries again.
    # Only touches lines that DON'T already have a !defined() guard.
    sed -i \
        -e "/^[[:space:]]*define('WP_HOME',/ { /!defined('WP_HOME')/! s/^\([[:space:]]*\)define('WP_HOME',/\1if (!defined('WP_HOME')) define('WP_HOME',/ }" \
        -e "/^[[:space:]]*define('WP_SITEURL',/ { /!defined('WP_SITEURL')/! s/^\([[:space:]]*\)define('WP_SITEURL',/\1if (!defined('WP_SITEURL')) define('WP_SITEURL',/ }" \
        "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        print_error "Ошибка патча: пустой результат."
        rm -f "$temp_file"
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! mv "$temp_file" "$config_file"; then
        print_error "Не удалось перезаписать wp-config.php (ошибка mv)!"
        rm -f "$temp_file" 2>/dev/null
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    local project_path
    project_path=$(dirname "$config_file")
    if ! dpx_wp_config_syntax_check "$project_path" "$config_file"; then
        print_error "Синтаксическая ошибка! Откат из снапшота..."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! tunnel_is_config_patched "$config_file"; then
        print_error "Smart-блок не внедрился. Верификация провалена."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    if ! tunnel_config_tail_intact "$config_file"; then
        print_error "Патч повредил хвост wp-config.php! Откат..."
        tunnel_restore_wp_config "$config_file"
        return 1
    fi

    print_success "wp-config.php: DPX_SMART_TUNNEL внедрён (TLD: .${local_tld})"
    print_info "Снапшот сохранён до завершения туннеля: $backup_file"
    return 0
}

# =================================================================
# Откат wp-config.php из снапшота (v1.4.5 — Zero-Trust + Post-Verify)
#
# ЛОГИКА:
#   - Есть снапшот → mv -f (100% идентичность оригиналу)
#   - Нет снапшота + есть DPX-блоки → awk-очистка (ТОЛЬКО для
#     зависших блоков от старых версий dpx без снапшотов)
#   - Нет снапшота + нет блоков → ничего не делаем (файл не менялся)
#
# КРИТИЧЕСКОЕ ПРАВИЛО: если снапшота нет и блоков нет,
# файл гарантированно не менялся (снапшот = первая операция).
# Никакого awk на «авось»!
# =================================================================
tunnel_unpatch_wp_config() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    # ПУТЬ 1: Есть снапшот — восстанавливаем mv -f (100% идентичность)
    if [[ -f "$backup_file" ]]; then
        print_info "Восстановление wp-config.php из снапшота (mv -f)..."
        if tunnel_restore_wp_config "$config_file"; then
            # mv -f уже переименовал бэкап в конфиг — cleanup не нужен
            print_success "wp-config.php восстановлен из снапшота (побайтово)."
            return 0
        else
            print_error "КРИТИЧЕСКАЯ ОШИБКА: mv -f не удался!"
            return 1
        fi
    fi

    # ПУТЬ 2: Нет снапшота, но есть DPX-блоки от старых запусков
    # (без снапшотов — legacy-режим). Осторожная awk-очистка.
    if [[ -f "$config_file" ]] && tunnel_is_config_patched "$config_file"; then
        print_warning "Снапшот отсутствует, но найдены DPX-блоки. awk-очистка..."

        local temp_file
        temp_file=$(create_temp_file)

        awk '
            /DPX_SMART_TUNNEL/ || /DPX_TUNNEL_START/ || /DPX_TUNNEL_FIX[^_]/ { skip=1; next }
            /END_DPX_SMART_TUNNEL/ || /DPX_TUNNEL_END/ || /END_DPX_TUNNEL_FIX/ { skip=0; next }
            !skip { print }
        ' "$config_file" > "$temp_file"

        if [[ -s "$temp_file" ]]; then
            if mv "$temp_file" "$config_file"; then
                print_success "DPX-блоки удалены (legacy-фолбек)."
                return 0
            else
                print_error "Ошибка mv при фолбек-очистке!"
                rm -f "$temp_file"
                return 1
            fi
        else
            print_error "awk-очистка дала пустой результат! Файл не перезаписан."
            rm -f "$temp_file"
            return 1
        fi
    fi

    # ПУТЬ 3: Нет снапшота, нет блоков — файл не менялся, всё ок
    return 0
}

# =================================================================
# УРОВЕНЬ 3: DATABASE SYNC — Движок миграции (v1.4.18)
#
# АРХИТЕКТУРА v1.4.18 — Атомарность сессии:
#   Снапшот создается ВЫЗЫВАЮЩИМ скриптом (tunnel.sh) СТРОГО
#   ДО начала мутации. Имя snapshot мгновенно пишется на диск
#   (.dpx/current_snapshot). Если WP-CLI зависнет или юзер
#   нажмёт Ctrl+C, ловушка (trap) найдёт метку и гарантированно
#   сделает откат.
#
#   db_smart_replace_tunnel (database.sh) — чистый движок замены.
#   Не создаёт снапшот, не делает откат. Только замена + SQL
#   валидация.
#
# SQL Validation: прямой запрос к MySQL через ddev mysql -N -B.
# Final Chord: двойное восстановление wp-config.php в tunnel_cleanup.
# =================================================================

_DPX_DB_MUTATING=0
_DPX_ACTUAL_HOME=""

# =================================================================
# АТОМАРНАЯ СИНХРОНИЗАЦИЯ БД (v1.4.18)
# =================================================================

# Получает РЕАЛЬНЫЙ home URL СТРОГО через SQL (без WP-CLI).
# Использует db_sql_get_option() — единый SQL-читатель.
tunnel_get_actual_home() {
    local project_path="$1"
    db_sql_get_option "$project_path" "home"
}

tunnel_wp_db_replace() {
    local project_path="$1" tunnel_url="$2"

    print_info "Получение ACTUAL_HOME из БД (SQL-запрос)..."
    local actual_home
    actual_home=$(tunnel_get_actual_home "$project_path")

    if [[ -z "$actual_home" ]]; then
        print_error "Не удалось получить home URL из БД (SQL). Остановка!"
        return 1
    fi

    _DPX_ACTUAL_HOME="$actual_home"
    print_info "ACTUAL_HOME из БД: $actual_home"

    if [[ "$actual_home" == "$tunnel_url" ]]; then
        print_warning "URL совпадают. Замена не нужна."
        return 0
    fi

    # КИТ №3: АТОМАРНОСТЬ СЕССИИ. Создаем бэкап и ставим метку ДО мутации!
    local snapshot_name
    snapshot_name=$(db_create_snapshot "$project_path")
    if [[ -z "$snapshot_name" ]]; then
        return 1 # Ошибка уже выведена внутри
    fi

    # Фиксируем состояние на диске
    mkdir -p "${project_path}/.dpx" 2>/dev/null
    echo "$snapshot_name" > "${project_path}/.dpx/current_snapshot"

    # Теперь безопасно начинаем мутацию
    _DPX_DB_MUTATING=1

    if ! db_smart_replace_tunnel "$actual_home" "$tunnel_url" "$project_path"; then
        _DPX_DB_MUTATING=0
        print_error "Мутация БД провалилась. Ожидайте автоматического отката..."
        return 1
    fi

    _DPX_DB_MUTATING=0

    # Tunnel-specific flushes
    tunnel_wp_exec "$project_path" rewrite flush --allow-root --quiet 2>/dev/null || true
    sleep 1

    # Elementor CSS flush (только если плагин установлен — проверка через test -d)
    if tunnel_has_elementor "$project_path"; then
        print_info "Elementor: flush-css..."
        tunnel_wp_exec "$project_path" elementor flush-css --allow-root --quiet 2>/dev/null || true
        sleep 1
    fi

    # Flatsome CSS cache cleanup (только если тема установлена)
    # Удаляем каталог flatsome-css в uploads — там запечённые URL
    if tunnel_has_flatsome "$project_path"; then
        print_info "Flatsome: CSS cache cleanup..."
        (
            cd "$project_path" || exit 1
            ddev exec rm -rf /var/www/html/wp-content/uploads/flatsome-css 2>/dev/null
        ) 2>/dev/null || true
    fi

    return 0
}

# Откат БД через ddev snapshot restore (v1.4.21)
# План А: snapshot restore. План Б: reverse search-replace.
# Flatsome транзиенты чистятся через SQL (без WP-CLI).
# WP-CLI используется ТОЛЬКО для search-replace и cache flush.
#
# v1.4.23: Rollback — ТРИ прохода (HTTPS, HTTP, Bare Domain).
# Все WP-CLI вызовы — через php -d display_errors=0.
tunnel_wp_db_rollback() {
    local project_path="$1"
    local tunnel_url="${2:-$_DPX_TUNNEL_URL}"
    local local_url="${3:-$_DPX_TUNNEL_LOCAL_URL}"

    local snap_file="${project_path}/.dpx/current_snapshot"
    local saved_snap_name=""
    local snapshot_available=false

    if [[ -f "$snap_file" ]]; then
        saved_snap_name=$(cat "$snap_file")
        saved_snap_name="${saved_snap_name// /}"
        if [[ -n "$saved_snap_name" ]]; then
            snapshot_available=true
        fi
    fi

    local rollback_ok=false

    if [[ "$snapshot_available" == "true" ]]; then
        echo "" >&2
        print_info "ОТКАТ БД (План А): Восстановление из снапшота $saved_snap_name..." >&2

        if dpx_exec_and_log "$project_path" ddev snapshot restore "$saved_snap_name"; then
            rollback_ok=true
            print_success "База данных восстановлена из snapshot." >&2
        else
            print_error "Snapshot restore FAILED: $saved_snap_name" >&2
            print_warning "Переходим к Плану Б (reverse search-replace)..." >&2
        fi
        rm -f "$snap_file"
    fi

    if [[ "$rollback_ok" == "false" ]]; then
        if [[ -z "$tunnel_url" || -z "$local_url" ]]; then
            print_error "Ручное восстановление невозможно: URL неизвестны." >&2
            return 1
        fi

        echo "" >&2
        print_warning "ОТКАТ БД (План Б): Reverse search-replace (3 прохода)..." >&2

        local tunnel_bare=$(echo "$tunnel_url" | sed 's|https\?://||;s|/$||')
        local local_bare=$(echo "$local_url" | sed 's|https\?://||;s|/$||')

        # Проход 1: HTTPS точный (обратный)
        print_info "  [1/3] $tunnel_url -> $local_url" >&2
        (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
            /usr/local/bin/wp search-replace "$tunnel_url" "$local_url" \
            --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
        sleep 1; sync 2>/dev/null || true

        # Проход 2: HTTP tunnel → HTTPS local
        if [[ -n "$tunnel_bare" ]]; then
            print_info "  [2/3] http://$tunnel_bare -> $local_url" >&2
            (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
                /usr/local/bin/wp search-replace "http://${tunnel_bare}" "$local_url" \
                --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
            sleep 1; sync 2>/dev/null || true
        fi

        # Проход 3: Голый домен
        if [[ -n "$tunnel_bare" && "$tunnel_bare" != "$local_bare" ]]; then
            print_info "  [3/3] $tunnel_bare -> $local_bare" >&2
            (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
                /usr/local/bin/wp search-replace "$tunnel_bare" "$local_bare" \
                --all-tables --precise --allow-root --quiet) >/dev/null 2>&1
            sleep 1; sync 2>/dev/null || true
        fi

        rollback_ok=true
        print_success "Reverse search-replace завершён (3 прохода)." >&2
    fi

    print_info "Post-rollback cleanup..." >&2

    # Flatsome транзиенты через SQL (без WP-CLI)
    if tunnel_has_flatsome "$project_path"; then
        print_step "auto" "Flatsome transients cleanup (SQL)..." >&2
        db_sql_delete_transients "$project_path" "flatsome_%"
    fi

    # WP-CLI: транзиенты + cache flush (php -d display_errors=0)
    (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
        /usr/local/bin/wp transient delete --all --allow-root --quiet) >/dev/null 2>&1 || true
    sleep 1

    (cd "$project_path" && ddev exec php -d display_errors=0 -d error_reporting=0 \
        /usr/local/bin/wp cache flush --allow-root --quiet) >/dev/null 2>&1 || true
    sleep 1

    # Elementor CSS flush (только если плагин есть)
    if tunnel_has_elementor "$project_path"; then
        print_step "auto" "Elementor CSS flush..." >&2
        tunnel_wp_exec "$project_path" elementor flush-css --allow-root --quiet 2>/dev/null || true
        sleep 1; sync 2>/dev/null || true
    fi

    # Flatsome CSS cache cleanup (только если тема есть)
    if tunnel_has_flatsome "$project_path"; then
        print_step "auto" "Flatsome CSS cache cleanup..." >&2
        (cd "$project_path" && ddev exec rm -rf /var/www/html/wp-content/uploads/flatsome-css 2>/dev/null) 2>/dev/null || true
    fi

    tunnel_wp_exec "$project_path" rewrite flush --allow-root --quiet 2>/dev/null || true
    rm -f "$snap_file"

    print_success "БД возвращена к локальному состоянию. Кэш очищен." >&2
    return 0
}

# =================================================================
# УРОВЕНЬ 4: ЖИЗНЕННЫЙ ЦИКЛ — Trap и очистка
# =================================================================

_DPX_TUNNEL_PROJECT_PATH=""
_DPX_TUNNEL_URL=""
_DPX_TUNNEL_LOCAL_URL=""
_DPX_TUNNEL_CMS_TYPE=""
_DPX_TUNNEL_PID=""
_DPX_TUNNEL_LOG_FILE=""
_DPX_TUNNEL_CONFIG_FILE=""
_DPX_TUNNEL_PROVIDER=""
_DPX_ROLLBACK_DONE=false
_DPX_ACTUAL_HOME=""

# Порядок КРИТИЧЕН (v1.4.19 — PHP 8.5 Isolation):
#   0. ATOMIC LOCK — проверка _DPX_ROLLBACK_DONE
#   1. Восстановление wp-config.php (Часть 1) — mv из снапшота
#   2. Откат БД — wp-config чист, WP-CLI работает
#   3. ФИНАЛЬНЫЙ АККОРД — cp -f бэкапа поверх конфига
#      (DDEV snapshot restore может перезапустить контейнеры и
#       перегенерировать wp-config-ddev.php, перетирая наш откат)
#   4. Проверка DPX_SMART_TUNNEL маркера
#   5. Остановка провайдера
#   6. Удаление лога и cleanup бэкапа
tunnel_cleanup() {
    local exit_code=$?

    # ==============================================================
    # ATOMIC LOCK: предотвращаем двойной откат
    # ==============================================================
    if [[ "$_DPX_ROLLBACK_DONE" == "true" ]]; then exit "$exit_code"; fi
    _DPX_ROLLBACK_DONE=true

    # Разоружаем trap ПЕРЕД любыми действиями
    trap - INT TERM EXIT

    echo "" >&2
    print_header "Завершение туннеля — откат"

    # ==============================================================
    # 1. ВОССТАНОВЛЕНИЕ wp-config.php (Часть 1)
    # Возвращаем чистый конфиг, чтобы WP-CLI при откате БД
    # не сошел с ума от пропатченных констант.
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_CONFIG_FILE" ]] && [[ -f "$_DPX_TUNNEL_CONFIG_FILE" ]]; then
        tunnel_unpatch_wp_config "$_DPX_TUNNEL_CONFIG_FILE"
    fi

    # ==============================================================
    # 2. ОТКАТ БД
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_PROJECT_PATH" && -n "$_DPX_TUNNEL_URL" && -n "$_DPX_TUNNEL_LOCAL_URL" ]]; then
        if [[ "$_DPX_TUNNEL_CMS_TYPE" == "wordpress" ]]; then
            tunnel_wp_db_rollback "$_DPX_TUNNEL_PROJECT_PATH"
        fi
    fi

    # ==============================================================
    # 3. ФИНАЛЬНЫЙ АККОРД (Подавление вмешательства DDEV)
    # DDEV snapshot restore может перезапустить контейнеры и
    # перегенерировать wp-config-ddev.php. Мы жестко
    # перезаписываем файл оригинальным бэкапом поверх всего!
    # ==============================================================
    if [[ -n "$_DPX_TUNNEL_CONFIG_FILE" ]]; then
        local backup_file
        backup_file=$(_dpx_wp_config_backup_path "$_DPX_TUNNEL_CONFIG_FILE")
        if [[ -f "$backup_file" ]]; then
            print_info "Финальный аккорд: жесткое восстановление wp-config.php..." >&2
            cp -f "$backup_file" "$_DPX_TUNNEL_CONFIG_FILE" 2>/dev/null
        fi

        # Проверка и удаление метки
        if grep -q "DPX_SMART_TUNNEL" "$_DPX_TUNNEL_CONFIG_FILE" 2>/dev/null; then
            print_error "КРИТИЧЕСКАЯ ОШИБКА: DPX_SMART_TUNNEL всё ещё в файле после отката!" >&2
        else
            dpx_wp_config_cleanup "$_DPX_TUNNEL_CONFIG_FILE"
        fi
    fi

    # ==============================================================
    # 4. Остановка провайдера и логов
    # ==============================================================
    [[ -n "$_DPX_TUNNEL_PID" ]] && tunnel_provider_stop "$_DPX_TUNNEL_PROVIDER" "$_DPX_TUNNEL_PID"
    [[ -n "$_DPX_TUNNEL_LOG_FILE" && -f "$_DPX_TUNNEL_LOG_FILE" ]] && rm -f "$_DPX_TUNNEL_LOG_FILE"

    print_celebration "Откат завершён. Проект вернулся к локальному состоянию."
    exit "$exit_code"
}

# =================================================================
# ИНТЕЛЛЕКТУАЛЬНЫЙ КОНТЕКСТ — Автоопределение проекта
# =================================================================

# Определяет проект DDEV по текущей директории.
#
# Метод 1 (быстрый, v1.4.13): поиск .ddev/config.yaml в дереве.
#   Если .ddev/config.yaml найден в $PWD или выше — читаем name:.
#   НЕ требует DDEV daemon, работает даже если контейнеры не запущены.
#   Поддерживает симлинки через _dpx_realpath().
#
# Метод 2 (фолбек): ddev describe -j.
#   DDEV сам ищет .ddev/config.yaml через свой механизм.
#   Требует запущенный DDEV daemon. Срабатывает когда
#   файловая система недоступна (NFS, удалённые volume).
tunnel_detect_project_from_cwd() {
    # Метод 1: Файловая система — .ddev/config.yaml (БЫСТРЫЙ)
    local search_dir
    search_dir=$(_dpx_realpath "$PWD")
    while [[ -n "$search_dir" && "$search_dir" != "/" ]]; do
        if [[ -f "${search_dir}/.ddev/config.yaml" ]]; then
            local detected_name
            detected_name=$(grep -E '^name:' "${search_dir}/.ddev/config.yaml" 2>/dev/null \
                | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
            if [[ -n "$detected_name" ]]; then
                # Верифицируем: проект существует в DDEV?
                if ddev describe "$detected_name" -j >/dev/null 2>&1; then
                    echo "$detected_name"
                    return 0
                fi
            fi
            return 1
        fi
        search_dir=$(dirname "$search_dir")
    done

    # Метод 2: DDEV auto-detection (ФОЛБЕК)
    local proj_name
    proj_name=$(ddev describe -j 2>/dev/null | jq -r '.raw.name // empty' 2>/dev/null)
    if [[ -n "$proj_name" ]]; then
        echo "$proj_name"
        return 0
    fi

    return 1
}

# Возвращает АБСОЛЮТНЫЙ путь к корню проекта.
# Приоритет: файловая система (поиск .ddev) → DDEV API .raw.approot.
tunnel_detect_project_path_from_cwd() {
    # Метод 1: Файловая система (БЫСТРЫЙ)
    local search_dir
    search_dir=$(_dpx_realpath "$PWD")
    while [[ -n "$search_dir" && "$search_dir" != "/" ]]; do
        if [[ -f "${search_dir}/.ddev/config.yaml" ]]; then
            echo "$search_dir"
            return 0
        fi
        search_dir=$(dirname "$search_dir")
    done

    # Метод 2: DDEV API (ФОЛБЕК)
    local proj_path
    proj_path=$(ddev describe -j 2>/dev/null | jq -r '.raw.approot // empty' 2>/dev/null)
    if [[ -n "$proj_path" ]]; then
        echo "$proj_path"
        return 0
    fi

    return 1
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_tunnel() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_tunnel_help
        return 0
    fi

    print_header "Проброс туннеля v${DPX_VERSION}"

    # --- Проверка jq ---
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq не найден. Обязателен для парсинга DDEV JSON-вывода."
        print_info "Установка: Ubuntu/Debian: sudo apt install jq | macOS: brew install jq"
        return 1
    fi

    # --- Провайдер ---
    local provider
    provider=$(get_arg "provider" "")
    if [[ -z "$provider" ]]; then
        provider=$(tunnel_select_provider)
        if [[ $? -ne 0 ]] || [[ -z "$provider" ]]; then
            print_error "Провайдер туннеля не найден."
            return 1
        fi
    fi
    print_info "Провайдер: $provider"
    tunnel_provider_check "$provider" || return 1

    # --- Выбор проекта ---
    local project_name
    local project_path
    local auto_detected=false

    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        # Автоопределение через DDEV API (из любой поддиректории)
        project_name=$(tunnel_detect_project_from_cwd)
        if [[ -n "$project_name" ]]; then
            auto_detected=true
            project_path=$(tunnel_detect_project_path_from_cwd)
            print_success "Автоопределение: проект '$project_name' (DDEV API)"
        fi
    fi

    # Фолбек: интерактивный выбор
    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Выберите проект для туннеля")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    # Путь к проекту
    if [[ -z "$project_path" ]]; then
        project_path=$(projects_get_path "$project_name")
    fi
    validate_directory "$project_path" "Директория проекта" || return 1

    print_info "Корень проекта: $project_path"

    # --- Тип CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")
    if [[ -z "$cms_type" ]]; then
        cms_type=$(detect_cms_type "$project_path")
        print_info "Автоопределение CMS: $(get_cms_name "$cms_type")"
        if [[ "$cms_type" != "wordpress" ]]; then
            print_warning "Тип: $(get_cms_name "$cms_type"). URL в БД заменён НЕ будет."
            if ! confirm "Продолжить без замены URL?"; then
                cms_type=$(select_cms_type "Выберите тип проекта") || return 1
            fi
        fi
    fi
    print_success "Тип проекта: $(get_cms_name "$cms_type")"

    # ==================================================================
    # STALE BACKUP CHECK (v1.4.10): если предыдущая сессия туннеля
    # завершилась крашем (kill -9, power loss), бэкап wp-config.php
    # остался на диске. Восстанавливаем оригинал из снапшота (mv -f).
    # ==================================================================
    if [[ "$cms_type" == "wordpress" ]]; then
        dpx_wp_config_stale_check "${project_path}/wp-config.php" || return 1
    fi

    # --- Статус DDEV ---
    if ! ddev_is_project_running "$project_name"; then
        print_warning "Проект '$project_name' не запущен."
        if has_arg "yes" || confirm "Запустить?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Проект должен быть запущен."
            return 1
        fi
    fi
    print_success "Проект запущен."

    # --- URL и порт (2026 DDEV API) ---
    local project_url
    project_url=$(tunnel_get_target_url "$project_name")
    print_info "Локальный URL: $project_url"

    local http_port
    http_port=$(tunnel_get_http_port "$project_name")
    print_info "Хост-порт (DDEV → Docker): $http_port"

    # Локальный домен из DDEV API (без хардкода!)
    local local_domain
    local_domain=$(tunnel_get_local_domain "$project_name")
    print_info "Локальный домен: $local_domain"

    # TLD извлекаем из домена (последняя часть после точки)
    local local_tld
    local_tld="${local_domain##*.}"

    local local_url="https://${local_domain}"

    # ==================================================================
    # ФОРМИРОВАНИЕ ЦЕЛЕВОГО URL ДЛЯ CLOUDFLARED
    #
    # cloudflared работает на ХОСТЕ, не в Docker.
    # Подключаемся к http://127.0.0.1:<host_port>,
    # где <host_port> — динамический порт, который DDEV
    # пробросил с контейнерного 80 на хост.
    #
    # ЗАГОЛОВОК Host: CRITICAL для Traefik!
    # DDEV использует Traefik для маршрутизации. Traefik
    # определяет проект по заголовку Host. Без него — 404.
    #
    # Домен берётся из DDEV API (.raw.primary_url),
    # а НЕ хардкодится из конфига.
    # ==================================================================
    local cloudflared_target_url="http://127.0.0.1:${http_port}"
    local cloudflared_host_header="$local_domain"
    print_info "cloudflared → $cloudflared_target_url (Host: $cloudflared_host_header)"

    # --- Лог-файл ---
    local log_file
    log_file=$(create_temp_file)
    _DPX_TUNNEL_LOG_FILE="$log_file"

    # --- Подтверждение ---
    print_header "Проверьте параметры"
    cat >&2 << PARAMS
Проект:            ${COLOR_GREEN}${project_name} ($(get_cms_name "$cms_type"))${COLOR_RESET}
Корень проекта:    ${COLOR_GREEN}${project_path}${COLOR_RESET}
Локальный URL:     ${COLOR_YELLOW}${local_url}${COLOR_RESET}
Хост-порт:         ${COLOR_GREEN}${http_port}${COLOR_RESET}
Host-заголовок:    ${COLOR_GREEN}${cloudflared_host_header}${COLOR_RESET}
Провайдер:         ${COLOR_GREEN}${provider}${COLOR_RESET}
Локальный TLD:     ${COLOR_GREEN}.${local_tld}${COLOR_RESET}
Замена URL:        ${COLOR_GREEN}$([ "$cms_type" = "wordpress" ] && echo "Да (wp search-replace + smart wp-config)" || echo "Нет (только проброс порта)")${COLOR_RESET}
PARAMS

    print_separator
    print_info "Ctrl+C → полный откат: mv -f из снапшота + wp search-replace назад"

    if ! has_arg "yes"; then
        confirm "Начать проброс туннеля?" || return 1
    fi

    # --- Trap ---
    _DPX_TUNNEL_PROJECT_PATH="$project_path"
    _DPX_TUNNEL_LOCAL_URL="$local_url"
    _DPX_TUNNEL_CMS_TYPE="$cms_type"
    _DPX_TUNNEL_PROVIDER="$provider"

    if [[ "$cms_type" == "wordpress" ]]; then
        _DPX_TUNNEL_CONFIG_FILE="${project_path}/wp-config.php"
    fi

    trap 'tunnel_cleanup' INT TERM EXIT

    # ==================================================================
    # НОВЫЙ ПОРЯДОК: СТАРТ ТУННЕЛЯ -> МУТАЦИЯ БД -> ПАТЧ КОНФИГА
    # Зачем? Чтобы WP-CLI менял базу ДО ТОГО, как wp-config.php получит
    # хардкод-константы WP_HOME, из-за которых WP-CLI игнорирует замены.
    # ==================================================================

    # --- Шаг 1: Запуск туннеля ---
    print_step "1" "Запуск туннеля ($provider)"
    tunnel_provider_start "$provider" "$cloudflared_target_url" "$log_file" "$cloudflared_host_header" || {
        print_error "Не удалось запустить туннеля."
        return 1
    }
    local tunnel_url="$_DPX_TUNNEL_URL"

    # --- Шаг 2: Database Sync ---
    if [[ "$cms_type" == "wordpress" ]]; then
        print_step "2" "Замена URL в базе данных"
        tunnel_wp_db_replace "$project_path" "$tunnel_url" || {
            print_error "Ошибка замены URL. Откат..."
            return 1
        }
    fi

    # --- Шаг 3: Патч wp-config.php ---
    if [[ "$cms_type" == "wordpress" ]]; then
        print_step "3" "Патч wp-config.php (DPX_SMART_TUNNEL)"
        if ! tunnel_patch_wp_config "${project_path}/wp-config.php" "$local_tld"; then
            print_error "Патч wp-config.php провален. Откат..."
            return 1
        fi
    fi

    # --- Готово ---
    cat >&2 << READY

${COLOR_GREEN}🎉 Туннель активен! 🎉${COLOR_RESET}

${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}
${COLOR_BOLD}  Публичный URL: ${tunnel_url}${COLOR_RESET}
${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}

Отправьте этот URL заказчику.
Нажмите Ctrl+C для завершения туннеля и отката.
READY

    # --- Ожидание Ctrl+C ---
    local uptime=0
    while kill -0 "$_DPX_TUNNEL_PID" 2>/dev/null; do
        sleep 5
        ((uptime += 5))
        if (( uptime % 60 == 0 )); then
            print_info "Туннель: $((uptime / 60)) мин. | URL: $tunnel_url"
        fi
    done

    print_warning "Туннель завершился неожиданно. Откат..."
    return 1
}
