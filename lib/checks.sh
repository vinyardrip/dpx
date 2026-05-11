#!/usr/bin/env bash
# =================================================================
# DPX Checks Module - проверки зависимостей и окружения
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_CHECKS_LOADED:-}" ]] && return 0
readonly _DPX_CHECKS_LOADED=1

# =================================================================
# КОНСТАНТЫ МИНИМАЛЬНЫХ ВЕРСИЙ
# =================================================================

readonly MIN_BASH_VERSION="4.0"
readonly MIN_DDEV_VERSION="1.21.0"
readonly MIN_DOCKER_VERSION="20.10"
readonly MIN_JQ_VERSION="1.5"

# =================================================================
# СРАВНЕНИЕ ВЕРСИЙ (semver)
# =================================================================

# Возвращает: 0 = равны, 1 = $1 > $2, 2 = $1 < $2
version_compare() {
    [[ "$1" == "$2" ]] && return 0

    local IFS='.'
    local i ver1 ver2

    read -ra ver1 <<< "$1"
    read -ra ver2 <<< "$2"

    # Выравниваем длину массивов
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do ver2[i]=0; done

    for ((i=0; i<${#ver1[@]}; i++)); do
        if ((10#${ver1[i]:-0} > 10#${ver2[i]:-0})); then return 1; fi
        if ((10#${ver1[i]:-0} < 10#${ver2[i]:-0})); then return 2; fi
    done

    return 0
}

# Возвращает 0 (success), если $1 >= $2 (кроссплатформенная через awk)
version_ge() {
    awk -v v1="$1" -v v2="$2" 'BEGIN {
        split(v1, a, "."); split(v2, b, ".");
        for (i=1; i<=3; i++) {
            if (a[i]+0 < b[i]+0) exit 1;
            if (a[i]+0 > b[i]+0) exit 0;
        }
        exit 0;
    }'
}

# Извлечение версии из строки
# Поддерживает форматы: "v1.23.4", "ddev v1.23.4", "1.23.4", "1.23"
# Умеет читать и аргумент $1, и STDIN (для пайплайнов)
extract_version() {
    local input="${1:-$(cat)}"
    echo "$input" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# =================================================================
# ПРОВЕРКИ
# =================================================================

check_bash_version() {
    if (( BASH_VERSINFO[0] < 4 )); then
        print_error "Требуется Bash >= ${MIN_BASH_VERSION}, текущая: ${BASH_VERSION:-unknown}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            print_info "macOS: установите brew install bash и обновите PATH"
        fi
        return 1
    fi
    return 0
}

check_dependency() {
    local cmd="$1"
    local package="${2:-$1}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "Команда '$cmd' не найдена. Установите $package."
        return 1
    fi
    return 0
}

check_ddev() {
    if ! check_dependency "ddev" "DDEV"; then
        return 1
    fi

    local ddev_version
    ddev_version=$(ddev --version 2>/dev/null)
    ddev_version=$(extract_version "$ddev_version")

    if [[ -z "$ddev_version" ]]; then
        print_warning "Не удалось определить версию DDEV"
        return 0
    fi

    if version_ge "$ddev_version" "$MIN_DDEV_VERSION"; then
        print_info "DDEV версия: $ddev_version ✓"
    else
        print_error "DDEV устарел: $ddev_version. Требуется >= ${MIN_DDEV_VERSION}"
        return 1
    fi

    return 0
}

check_docker() {
    if ! check_dependency "docker" "Docker"; then
        return 1
    fi

    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null)

    if [[ -z "$docker_version" ]]; then
        print_error "Docker daemon не запущен или недоступен!"
        case "$DPX_OS_TYPE" in
            macos) print_error "Запустите Docker Desktop для macOS" ;;
            linux) print_error "Попробуйте: sudo systemctl start docker" ;;
        esac
        return 1
    fi

    docker_version=$(extract_version "$docker_version")

    if version_ge "$docker_version" "$MIN_DOCKER_VERSION"; then
        print_info "Docker версия: ${docker_version} ✓ (daemon running)"
    else
        print_error "Docker устарел: $docker_version. Требуется >= ${MIN_DOCKER_VERSION}"
        return 1
    fi

    return 0
}

check_jq() {
    if ! check_dependency "jq" "jq (https://stedolan.github.io/jq/)"; then
        print_error "jq обязателен для парсинга JSON-вывода DDEV (ddev describe --format=json)."
        print_info "Установка:"
        print_info "  Ubuntu/Debian: sudo apt install jq"
        print_info "  macOS:         brew install jq"
        return 1
    fi

    local jq_version
    jq_version=$(jq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

    if [[ -n "$jq_version" ]]; then
        if version_ge "$jq_version" "$MIN_JQ_VERSION"; then
            print_info "jq версия: $jq_version ✓"
        else
            print_error "jq устарел: $jq_version. Требуется >= ${MIN_JQ_VERSION}"
            return 1
        fi
    fi

    return 0
}

# =================================================================
# КОМПЛЕКСНАЯ ПРОВЕРКА
# =================================================================

check_dependencies() {
    local has_errors=0
    local start_time
    start_time=$(date +%s)

    print_header "Pre-flight Checks"
    print_info "OS: ${DPX_OS_TYPE} (${OSTYPE:-unknown})"
    print_info "Bash: ${BASH_VERSION%% *}"

    check_bash_version || return 1
    print_info "Bash >= ${MIN_BASH_VERSION} ✓"

    # Базовые утилиты (jq для JSON, tar для SRDB/Devilbox)
    # Примечание: docker-compose проверяется отдельно (v1 бинарник vs v2 плагин)
    for cmd in sed grep awk curl tar jq; do
        check_dependency "$cmd" || has_errors=1
    done

    # docker compose: v2 (плагин docker compose) или v1 (бинарник docker-compose)
    if docker compose version >/dev/null 2>&1; then
        print_info "docker compose (v2) ✓"
    elif command -v docker-compose >/dev/null 2>&1; then
        print_info "docker-compose (v1) ✓"
    else
        print_error "docker compose не найден (ни v2 плагин, ни v1 бинарник)."
        has_errors=1
    fi

    echo ""
    check_docker || has_errors=1

    echo ""
    check_ddev || has_errors=1

    echo ""
    check_jq || has_errors=1

    local duration=$(( $(date +%s) - start_time ))
    echo ""

    if [[ $has_errors -eq 0 ]]; then
        print_success "All checks passed (${duration}s)"
    else
        print_error "Some checks failed"
    fi

    return $has_errors
}

# =================================================================
# ЭКСПОРТ
# =================================================================

export MIN_BASH_VERSION MIN_DDEV_VERSION MIN_DOCKER_VERSION MIN_JQ_VERSION