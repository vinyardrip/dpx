#!/usr/bin/env bash
# =================================================================
# DPX Projects Module - работа со списком проектов
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_PROJECTS_LOADED:-}" ]] && return 0
readonly _DPX_PROJECTS_LOADED=1

# Подключаем зависимости
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/ddev.sh"

# =================================================================
# ПОЛУЧЕНИЕ СПИСКА ПРОЕКТОВ
# =================================================================

projects_get_base_path() {
    get_config "ddev_projects_base_path"
}

projects_list() {
    local base_path=$(projects_get_base_path)

    if [[ ! -d "$base_path" ]]; then
        return 1
    fi

    local projects=()

    while IFS= read -r config_file; do
        local project_dir
        project_dir=$(dirname "$(dirname "$config_file")")
        local project_name
        project_name=$(basename "$project_dir")
        projects+=("$project_name")
    done < <(find "$base_path" -maxdepth 3 -name "config.yaml" -path "*/.ddev/config.yaml" 2>/dev/null | sort)

    if [[ ${#projects[@]} -gt 0 ]]; then
        printf '%s\n' "${projects[@]}"
    fi
}

projects_count() {
    local count=$(projects_list | wc -l)
    echo "${count// /}"
}

projects_exists() {
    local project_name="$1"
    local base_path=$(projects_get_base_path)
    local config_file="${base_path}/${project_name}/.ddev/config.yaml"
    [[ -f "$config_file" ]]
}

projects_get_path() {
    local project_name="$1"
    local base_path=$(projects_get_base_path)
    echo "${base_path}/${project_name}"
}

projects_get_php_version() {
    local project_name="$1"
    local project_path=$(projects_get_path "$project_name")
    local config_file="${project_path}/.ddev/config.yaml"

    if [[ -f "$config_file" ]]; then
        grep -E "^php_version:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'"
    else
        echo "-"
    fi
}

# =================================================================
# ИНТЕРАКТИВНЫЙ ВЫБОР ПРОЕКТА
# =================================================================

projects_select_interactive() {
    local return_path=false
    local prompt="${1:-Выберите проект}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --return-path) return_path=true ;;
            *) prompt="$1" ;;
        esac
        shift
    done

    local base_path=$(projects_get_base_path)

    if [[ ! -d "$base_path" ]]; then
        print_error "Директория проектов не найдена: $base_path" >&2
        return 1
    fi

    local running_projects
    running_projects=$(ddev list --active-only 2>/dev/null)

    local projects=()
    local project_data=()

    while IFS= read -r config_file; do
        local project_dir
        project_dir=$(dirname "$(dirname "$config_file")")
        local project_name
        project_name=$(basename "$project_dir")

        local php_version
        php_version=$(grep -E "^php_version:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")
        [[ -z "$php_version" ]] && php_version="-"

        local status="stopped"
        if echo "$running_projects" | grep -qE "(^|[^a-zA-Z0-9_-])${project_name}([^a-zA-Z0-9_-]|$)" 2>/dev/null; then
            status="running"
        fi

        projects+=("$project_name")
        project_data+=("${project_name}|${php_version}|${status}")
    done < <(find "$base_path" -maxdepth 3 -name "config.yaml" -path "*/.ddev/config.yaml" 2>/dev/null | sort)

    local count=${#projects[@]}

    if [[ $count -eq 0 ]]; then
        print_warning "DDEV проекты не найдены в: $base_path" >&2
        return 1
    fi

    print_header "$prompt" >&2

    echo "" >&2
    printf '%b' "$COLOR_BOLD" >&2
    printf ' %-3s | %-31s | %-8s | %s\n' "№" "Проект" "PHP" "Статус" >&2
    printf '%b' "$COLOR_RESET" >&2
    echo "-----|---------------------------------|----------|---------" >&2

    local i=1
    for data in "${project_data[@]}"; do
        IFS='|' read -r name php status <<< "$data"

        local status_colored
        if [[ "$status" == "running" ]]; then
            status_colored="${COLOR_GREEN}running${COLOR_RESET}"
        else
            status_colored="${COLOR_YELLOW}stopped${COLOR_RESET}"
        fi

        printf " %-3d | %-31s | %-8s | %b\n" "$i" "$name" "$php" "$status_colored" >&2
        ((i++))
    done

    echo "" >&2

    local choice
    read -r -p "Введите номер или имя проекта: " choice

    local selected=""

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= count )); then
        selected="${projects[$((choice-1))]}"
    elif [[ -n "$choice" ]]; then
        local name
        for name in "${projects[@]}"; do
            if [[ "$name" == "$choice" ]]; then
                selected="$name"
                break
            fi
        done

        if [[ -z "$selected" ]]; then
            print_error "Проект '$choice' не найден" >&2
            return 1
        fi
    else
        return 1
    fi

    if [[ "$return_path" == true ]]; then
        echo "${base_path}/${selected}"
    else
        echo "$selected"
    fi
}