#!/usr/bin/env bash
# =================================================================
# DPX Sudo Module - безопасная работа с привилегиями и файлами
# Протокол Safe Sudo: бэкап → правка → проверка → rollback/cleanup
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_SUDO_LOADED:-}" ]] && return 0
readonly _DPX_SUDO_LOADED=1

# =================================================================
# КОНСТАНТЫ
# =================================================================

readonly DPX_SUDO_MAX_ATTEMPTS=3
readonly DPX_SUDO_TIMEOUT=60

# =================================================================
# SAFE SUDO — цикл аутентификации с ограничением попыток
# =================================================================

dpx_sudo() {
    local attempt=1

    while (( attempt <= DPX_SUDO_MAX_ATTEMPTS )); do
        if (( attempt > 1 )); then
            print_warning "Попытка $attempt из $DPX_SUDO_MAX_ATTEMPTS..."
        fi

        if command -v timeout >/dev/null 2>&1; then
            timeout "$DPX_SUDO_TIMEOUT" sudo "$@" && return 0
        else
            if command -v gtimeout >/dev/null 2>&1; then
                gtimeout "$DPX_SUDO_TIMEOUT" sudo "$@" && return 0
            else
                sudo "$@" && return 0
            fi
        fi

        local rc=$?
        if (( rc == 124 )); then
            print_error "Таймаут sudo (${DPX_SUDO_TIMEOUT}с). Попробуйте снова."
        fi

        ((attempt++))
    done

    print_error "Не удалось выполнить sudo после $DPX_SUDO_MAX_ATTEMPTS попыток."
    return 1
}

# =================================================================
# FILE SNAPSHOT — создание и управление бэкапами
# =================================================================

dpx_snapshot() {
    local file="$1"
    local backup_file="${file}.bak"

    if [[ ! -f "$file" ]]; then
        print_error "Файл не найден для бэкапа: $file"
        return 1
    fi

    if cp "$file" "$backup_file" 2>/dev/null; then
        print_info "Бэкап: $backup_file"
        echo "$backup_file"
        return 0
    else
        print_error "Не удалось создать бэкап: $file"
        return 1
    fi
}

dpx_rollback() {
    local file="$1"
    local backup_file="${file}.bak"

    if [[ ! -f "$backup_file" ]]; then
        print_error "Бэкап не найден: $backup_file"
        return 1
    fi

    if cp "$backup_file" "$file" 2>/dev/null; then
        print_success "Откат: $file (из $backup_file)"
        rm -f "$backup_file"
        return 0
    else
        if dpx_sudo cp "$backup_file" "$file"; then
            print_success "Откат (sudo): $file"
            dpx_sudo rm -f "$backup_file" 2>/dev/null
            return 0
        else
            print_error "Не удалось восстановить из бэкапа: $file"
            return 1
        fi
    fi
}

dpx_cleanup_snapshot() {
    local file="$1"
    local backup_file="${file}.bak"

    if [[ -f "$backup_file" ]]; then
        rm -f "$backup_file" 2>/dev/null || dpx_sudo rm -f "$backup_file" 2>/dev/null
        print_info "Бэкап удалён: $backup_file"
    fi
}

# =================================================================
# /ETC/HOSTS — безопасная правка с проверкой через ping
# =================================================================

dpx_hosts_add() {
    local hostname="$1"
    local ip="${2:-127.0.0.1}"

    validate_non_empty "$hostname" "hostname для /etc/hosts" || return 1

    if grep -qE "^[^#]*\\b${hostname}\\b" /etc/hosts 2>/dev/null; then
        print_info "Запись для $hostname уже есть в /etc/hosts."
        return 0
    fi

    print_info "Добавляем $hostname в /etc/hosts..."

    dpx_snapshot /etc/hosts || return 1

    if ! dpx_sudo bash -c "echo '${ip} ${hostname}' >> /etc/hosts"; then
        print_error "Не удалось добавить запись в /etc/hosts."
        dpx_rollback /etc/hosts || true
        return 1
    fi

    local ping_cmd="ping -c 1 -W 2"
    if [[ "$DPX_OS_TYPE" == "macos" ]]; then
        ping_cmd="ping -c 1 -t 2"
    fi

    if $ping_cmd "$hostname" >/dev/null 2>&1; then
        print_success "Запись $hostname добавлена и доступна."
        dpx_cleanup_snapshot /etc/hosts
        return 0
    else
        print_warning "Ping $hostname не прошёл. Проверяем DNS-резолв..."
        local resolved=false
        if command -v getent >/dev/null 2>&1; then
            getent hosts "$hostname" >/dev/null 2>&1 && resolved=true
        elif [[ "$DPX_OS_TYPE" == "macos" ]]; then
            dscacheutil -q host -a name "$hostname" >/dev/null 2>&1 && resolved=true
        fi

        if [[ "$resolved" == true ]]; then
            print_success "Запись $hostname резолвится. Ping заблокирован файрволом — ок."
            dpx_cleanup_snapshot /etc/hosts
            return 0
        else
            print_error "Запись $hostname не резолвится. Откат /etc/hosts..."
            dpx_rollback /etc/hosts || true
            return 1
        fi
    fi
}

dpx_hosts_remove() {
    local hostname="$1"

    if ! grep -qE "^[^#]*\\b${hostname}\\b" /etc/hosts 2>/dev/null; then
        return 0
    fi

    print_info "Удаление $hostname из /etc/hosts..."

    dpx_snapshot /etc/hosts || return 1

    if [[ "$DPX_OS_TYPE" == "macos" ]]; then
        if ! dpx_sudo sed -i '' "/${hostname}/d" /etc/hosts; then
            dpx_rollback /etc/hosts || true
            return 1
        fi
    else
        if ! dpx_sudo sed -i "/${hostname}/d" /etc/hosts; then
            dpx_rollback /etc/hosts || true
            return 1
        fi
    fi

    print_success "Запись $hostname удалена из /etc/hosts."
    dpx_cleanup_snapshot /etc/hosts
    return 0
}

# =================================================================
# WP-CONFIG.PHP — Snapshot-Rollback Protocol (v1.4.5)
#
# Имя бэкапа: .wp-config.php.dpx_bak  (скрытый файл, С ТОЧКОЙ)
# Путь: РЯДОМ с wp-config.php, в корне проекта
# Откат: mv -f (атомарная замена на той же ФС)
#
# АРХИТЕКТУРНЫЕ ПРАВИЛА v1.4.5:
#   1. Функции, возвращающие данные через echo, НЕ должны
#      вызывать print_* в том же потоке. Все print_* → stderr.
#   2. diff -q валидация после cp: если файл изменился между
#      чтением и копированием (RSSSL и др.) — АБОРТ.
#   3. Post-Rollback Verification: после mv -f проверяем,
#      что DPX_SMART_TUNNEL исчез из файла.
# =================================================================

# Вычисляет путь к бэкапу для wp-config.php.
# Формат: /path/to/project/.wp-config.php.dpx_bak
_dpx_wp_config_backup_path() {
    local config_file="$1"
    local config_dir
    config_dir=$(dirname "$config_file")
    local config_base
    config_base=$(basename "$config_file")
    echo "${config_dir}/.${config_base}.dpx_bak"
}

# Проверяет наличие «зависшего» бэкапа от предыдущей сессии.
# Если найден — восстанавливает оригинал через mv -f.
dpx_wp_config_stale_check() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ -f "$backup_file" ]]; then
        print_warning "Обнаружен бэкап от предыдущей сессии: $backup_file"
        print_info "Восстанавливаем wp-config.php из зависшего бэкапа..."

        if mv -f "$backup_file" "$config_file" 2>/dev/null; then
            print_success "Оригинальный wp-config.php восстановлен из зависшего бэкапа."
        else
            if dpx_sudo mv -f "$backup_file" "$config_file"; then
                print_success "Оригинальный wp-config.php восстановлен из зависшего бэкапа (sudo)."
            else
                print_error "Не удалось восстановить wp-config.php из зависшего бэкапа!"
                print_error "Ручное восстановление: mv -f '$backup_file' '$config_file'"
                return 1
            fi
        fi
    fi

    return 0
}

# Создаёт снапшот wp-config.php → .wp-config.php.dpx_bak
# КРИТИЧЕСКОЕ ПРАВИЛО: вызывать ПЕРВОЙ операцией, ДО любых модификаций.
#
# ВАЛИДАЦИЯ (Zero-Trust v1.4.5):
#   1. exit code cp (права, диск)
#   2. [ -f "$backup_file" ] — физически существует
#   3. [ -s "$backup_file" ] — не пустой
#   4. diff -q — побайтовая идентичность (ловит RSSSL и др.)
#
# Возвращает путь к бэкапу через echo (stdout).
# print_* пишут в stderr — НЕ загрязняют возвращаемое значение.
dpx_wp_config_snapshot() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ ! -f "$config_file" ]]; then
        print_error "wp-config.php не найден: $config_file"
        return 1
    fi

    # Если бэкап уже существует — это зависший артефакт.
    # Zero-Trust: НЕ восстанавливаем (содержимое неизвестно), просто удаляем.
    if [[ -f "$backup_file" ]]; then
        print_warning "Обнаружен зависший снапшот: $backup_file"
        print_info "Zero-Trust: удаление перед созданием нового..."
        rm -f "$backup_file" 2>/dev/null || dpx_sudo rm -f "$backup_file" 2>/dev/null || {
            print_error "Не удалось удалить зависший снапшот!"
            return 1
        }
    fi

    # cp с проверкой exit code
    local cp_error
    cp_error=$(cp "$config_file" "$backup_file" 2>&1)
    local cp_rc=$?

    if [[ $cp_rc -ne 0 ]]; then
        print_error "Сбой создания снапшота wp-config.php (exit code: $cp_rc)!"
        print_error "Причина: $cp_error"
        print_error "Патч ОТМЕНЁН — оригинальный файл не будет изменён."
        return 1
    fi

    # Проверка: бэкап физически существует на диске
    if [[ ! -f "$backup_file" ]]; then
        print_error "Снапшот не создался! Файл отсутствует: $backup_file"
        print_error "Патч ОТМЕНЁН — оригинальный файл не будет изменён."
        return 1
    fi

    # Проверка: бэкап не пустой
    if [[ ! -s "$backup_file" ]]; then
        print_error "Снапшот создан, но пустой! Файл: $backup_file"
        rm -f "$backup_file" 2>/dev/null
        print_error "Патч ОТМЕНЁН — оригинальный файл не будет изменён."
        return 1
    fi

    # Проверка: бэкап ПОБАЙТОВО идентичен оригиналу (diff -q)
    # Ловит модификации от плагинов (RSSSL и др.) между чтением и cp.
    if ! diff -q "$config_file" "$backup_file" >/dev/null 2>&1; then
        print_error "Снапшот НЕ идентичен оригиналу! Файл изменён между cp и проверкой."
        print_error "Возможно, плагин (RSSSL и др.) модифицировал wp-config.php."
        rm -f "$backup_file" 2>/dev/null
        print_error "Патч ОТМЕНЁН — оригинальный файл не будет изменён."
        return 1
    fi

    print_info "Снапшот wp-config.php: $backup_file (diff -q OK)"
    # echo — ЕДИНСТВЕННЫЙ вывод в stdout. Возвращаемое значение чисто.
    echo "$backup_file"
    return 0
}

# Восстанавливает wp-config.php из .wp-config.php.dpx_bak через mv -f.
# mv -f на той же ФС — атомарная операция.
# После успешного mv бэкап перестаёт существовать (стал конфигом).
#
# Post-Rollback Verification (v1.4.5):
#   После mv -f проверяем, что DPX_SMART_TUNNEL исчез из файла.
#   Если блок на месте — rollback не сработал, КРИТИЧЕСКАЯ ОШИБКА.
dpx_wp_config_rollback() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ ! -f "$backup_file" ]]; then
        print_error "Бэкап wp-config.php не найден: $backup_file"
        return 1
    fi

    # mv -f: принудительная перезапись, даже если конфиг повреждён
    if mv -f "$backup_file" "$config_file" 2>/dev/null; then
        # Post-Rollback Verification: патч должен исчезнуть
        if grep -q "DPX_SMART_TUNNEL" "$config_file" 2>/dev/null; then
            print_error "КРИТИЧЕСКАЯ ОШИБКА: после mv -f блок DPX_SMART_TUNNEL всё ещё в файле!"
            print_error "Снапшот мог содержать блоки от предыдущей сессии."
            print_error "Проверьте вручную: $config_file"
            return 1
        fi
        print_success "wp-config.php восстановлен из снапшота (mv -f). Post-verify OK."
        return 0
    else
        if dpx_sudo mv -f "$backup_file" "$config_file"; then
            # Post-Rollback Verification (sudo path)
            if grep -q "DPX_SMART_TUNNEL" "$config_file" 2>/dev/null; then
                print_error "КРИТИЧЕСКАЯ ОШИБКА: после sudo mv -f блок DPX_SMART_TUNNEL всё ещё в файле!"
                print_error "Проверьте вручную: $config_file"
                return 1
            fi
            print_success "wp-config.php восстановлен из снапшота (sudo mv -f). Post-verify OK."
            return 0
        else
            print_error "Не удалось восстановить wp-config.php из снапшота!"
            print_error "Ручное восстановление: mv -f '$backup_file' '$config_file'"
            return 1
        fi
    fi
}

# Синтаксическая проверка wp-config.php через php -l в DDEV-контейнере.
dpx_wp_config_syntax_check() {
    local project_path="$1"
    local config_file="$2"

    print_info "Синтаксическая проверка wp-config.php (php -l)..."

    local php_l_result
    php_l_result=$(
        cd "$project_path" 2>/dev/null && \
        ddev exec "php -l /var/www/html/wp-config.php" 2>&1
    )

    if echo "$php_l_result" | grep -q "No syntax errors detected" 2>/dev/null; then
        print_success "php -l: синтаксис wp-config.php корректен."
        return 0
    else
        print_error "php -l: обнаружена синтаксическая ошибка в wp-config.php!"
        print_error "$php_l_result"
        return 1
    fi
}

# Удаляет .wp-config.php.dpx_bak. Страховочная очистка.
dpx_wp_config_cleanup() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ -f "$backup_file" ]]; then
        rm -f "$backup_file" 2>/dev/null || dpx_sudo rm -f "$backup_file" 2>/dev/null
        print_info "Снапшот удалён: $backup_file"
    fi
}

# =================================================================
# ЭКСПОРТ
# =================================================================

export DPX_SUDO_MAX_ATTEMPTS DPX_SUDO_TIMEOUT
