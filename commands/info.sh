#!/usr/bin/env bash
# =================================================================
# DPX Command: info - вывод текущей конфигурации и версий окружения
# =================================================================

source "${DPX_ROOT}/lib/core.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_info_help() {
    cat << EOF
 ${COLOR_BOLD}info${COLOR_RESET} - Конфигурация и версии окружения

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} info

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Выводит текущую конфигурацию DPX, версии установленных инструментов
    и пути к рабочим директориям. Полезно для диагностики проблем.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    -h, --help      Показать эту справку
EOF
}

# =================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =================================================================

# Извлечь версию из вывода команды
_info_extract_version() {
    echo "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# Показать статус зависимости с цветовой индикацией
_info_dep_status() {
    local name="$1"
    local version="$2"
    local min_version="$3"
    local status

    if [[ -z "$version" ]]; then
        status="${COLOR_RED}НЕ НАЙДЕН${COLOR_RESET}"
    elif [[ -n "$min_version" ]]; then
        if version_ge "$version" "$min_version"; then
            status="${COLOR_GREEN}OK${COLOR_RESET}"
        else
            status="${COLOR_RED}УСТАРЕЛ${COLOR_RESET}"
        fi
    else
        status="${COLOR_GREEN}OK${COLOR_RESET}"
    fi

    printf "  %-18s %-15s %s\n" "$name" "${version:--}" "$status"
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_info() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_info_help
        return 0
    fi

    # --- Версия DPX ---
    print_header "${TOOL_NAME^^} v${DPX_VERSION}"

    # --- Системное окружение ---
    print_header "Системное окружение"
    printf "  %-18s %s\n" "ОС" "${DPX_OS_TYPE}"
    printf "  %-18s %s\n" "Bash" "${BASH_VERSION%% *}"
    printf "  %-18s %s\n" "HOME" "${REAL_HOME}"
    printf "  %-18s %s\n" "DPX_ROOT" "${DPX_ROOT}"
    echo ""

    # --- Зависимости ---
    print_header "Зависимости"

    # Bash
    local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]:-0}"
    _info_dep_status "Bash" "$bash_ver" "${MIN_BASH_VERSION:-4.0}"

    # DDEV
    local ddev_ver=""
    if command -v ddev >/dev/null 2>&1; then
        ddev_ver=$(_info_extract_version "$(ddev --version 2>/dev/null)")
    fi
    _info_dep_status "DDEV" "$ddev_ver" "${MIN_DDEV_VERSION:-1.21.0}"

    # Docker
    local docker_ver=""
    if command -v docker >/dev/null 2>&1; then
        docker_ver=$(_info_extract_version "$(docker --version 2>/dev/null)")
    fi
    _info_dep_status "Docker" "$docker_ver" "${MIN_DOCKER_VERSION:-20.10}"

    # jq
    local jq_ver=""
    if command -v jq >/dev/null 2>&1; then
        jq_ver=$(_info_extract_version "$(jq --version 2>/dev/null)")
    fi
    _info_dep_status "jq" "$jq_ver" "1.5"

    # cloudflared
    local cloudflared_ver=""
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared_ver=$(_info_extract_version "$(cloudflared --version 2>/dev/null)")
    fi
    _info_dep_status "cloudflared" "$cloudflared_ver" ""

    # git
    local git_ver=""
    if command -v git >/dev/null 2>&1; then
        git_ver=$(_info_extract_version "$(git --version 2>/dev/null)")
    fi
    _info_dep_status "git" "$git_ver" ""

    echo ""

    # --- Конфигурация ---
    print_header "Конфигурация"

    local config_file="${REAL_HOME}/.config/${TOOL_NAME}/${TOOL_NAME}.conf"
    if [[ -f "$config_file" ]]; then
        printf "  %-18s %s\n" "Файл конфигурации" "$config_file"
    else
        printf "  %-18s %s\n" "Файл конфигурации" "(не найден, используется default)"
        config_file="${DPX_ROOT}/config/${TOOL_NAME}.conf"
    fi

    # Ключевые параметры конфигурации
    local workspace projects_root db_prod db_local
    workspace=$(get_config "workspace_root" "-")
    projects_root=$(get_config "ddev_projects_base_path" "-")
    db_prod=$(get_config "db_prod_path" "-")
    db_local=$(get_config "db_local_path" "-")

    printf "  %-18s %s\n" "workspace_root" "$workspace"
    printf "  %-18s %s\n" "projects_base" "$projects_root"
    printf "  %-18s %s\n" "db_prod_path" "$db_prod"
    printf "  %-18s %s\n" "db_local_path" "$db_local"
    printf "  %-18s %s\n" "default_php" "$(get_config 'default_php_version' '-')"
    printf "  %-18s %s\n" "default_db" "$(get_config 'default_db_type' '-')"
    printf "  %-18s %s\n" "project_tld" "$(get_config 'project_tld' '-')"
    printf "  %-18s %s\n" "prod_tld" "$(get_config 'default_prod_tld' '-')"
    echo ""

    # --- Хранилище метаданных ---
    print_header "Метаданные"
    local meta_file
    meta_file=$(dpx_meta_file 2>/dev/null || echo "${REAL_HOME}/.config/${TOOL_NAME}/projects.json")

    if [[ -f "$meta_file" ]]; then
        local project_count
        project_count=$(jq '.projects | length' "$meta_file" 2>/dev/null || echo "?")
        printf "  %-18s %s\n" "Файл" "$meta_file"
        printf "  %-18s %s\n" "Проектов" "$project_count"
    else
        printf "  %-18s %s\n" "Файл" "(не создан)"
    fi

    echo ""

    # --- DDEV проекты ---
    print_header "DDEV проекты"

    if command -v ddev >/dev/null 2>&1; then
        local ddev_list
        ddev_list=$(ddev list --active-only 2>/dev/null || echo "")

        if [[ -n "$ddev_list" ]]; then
            echo "$ddev_list"
        else
            print_info "Нет запущенных проектов"
        fi
    else
        print_warning "DDEV не найден"
    fi
}
