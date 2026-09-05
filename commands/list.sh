#!/usr/bin/env bash
# =================================================================
# DPX Command: list - output list DDEV projects
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# HELP
# =================================================================

show_list_help() {
    cat << EOF
 ${COLOR_BOLD}list${COLOR_RESET} - List DDEV projects with versions PHP

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} list [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Shows list all DDEV projects with versions PHP
    and maximum tested version.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --sort-by FIELD    Sorted by floor (name, php, php_max, status)
    --format FORMAT    Format output (table, json, simple)
    --group            Grouping by versions PHP
    -h, --help         Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} list
    ${TOOL_NAME} list --sort-by php_max --group
    ${TOOL_NAME} list --format json
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_list() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_list_help
        return 0
    fi

    local sort_by format group
    sort_by=$(get_arg "sort_by" "name")
    format=$(get_arg "format" "table")
    group=$(get_arg "group" "")

    local ddev_projects_path="${PROJECTS_ROOT:-$(get_config "ddev_projects_base_path")}"

    if [[ ! -d "$ddev_projects_path" ]]; then
        print_error "Projects directory not found: $ddev_projects_path"
        return 1
    fi

    print_header "List DDEV projects"

    local running_projects
    running_projects=$(ddev list --active-only 2>/dev/null)

    local temp_file
    temp_file=$(create_temp_file)
    trap "rm -f '$temp_file'" EXIT

    local count=0
    for project_path in "$ddev_projects_path"/*/; do
        [[ -d "$project_path" ]] || continue

        local config_file="${project_path}.ddev/config.yaml"

        if [[ -f "$config_file" ]]; then
            local project_name
            project_name=$(basename "$project_path")

            local php_version
            php_version=$(ddev_get_php_version "${project_path%/}")
            [[ -z "$php_version" ]] && php_version="-"

            local php_max
            php_max=$(dpx_get_php_max "$project_name")

            local status="stopped"
            if echo "$running_projects" | grep -qE "(^|[^a-zA-Z0-9_-])${project_name}([^a-zA-Z0-9_-]|$)"; then
                status="running"
            fi

            printf "%s|%s|%s|%s\n" "$project_name" "$php_version" "$php_max" "$status" >> "$temp_file"
            ((count++))
        fi
    done

    if [[ $count -eq 0 ]]; then
        print_warning "No DDEV projects found in: $ddev_projects_path"
        return 0
    fi

    case "$format" in
        json)
            echo "["
            local first=true
            while IFS='|' read -r name php php_max status; do
                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    echo ","
                fi
                printf '  {"name": "%s", "php": "%s", "php_max": "%s", "status": "%s"}' "$name" "$php" "$php_max" "$status"
            done < <(sort -t'|' -k1 "$temp_file")
            echo ""
            echo "]"
            ;;

        simple)
            while IFS='|' read -r name php php_max status; do
                echo "$name $php $php_max $status"
            done < <(sort -t'|' -k1 "$temp_file")
            ;;

        table|*)
            printf "\n%-25s | %-8s | %-8s | %s\n" "Project" "PHP" "PHP Max" "Status"
            printf '%-25s | %-8s | %-8s | %s\n' '-------------------------' '--------' '--------' '--------'

            local sort_field=1
            case "$sort_by" in
                php)     sort_field=2 ;;
                php_max) sort_field=3 ;;
                status)  sort_field=4 ;;
                name|*)  sort_field=1 ;;
            esac

            local sort_cmd="sort -t'|' -k${sort_field}"
            [[ "$sort_by" == "php" || "$sort_by" == "php_max" ]] && sort_cmd="sort -t'|' -k${sort_field}n"

            if [[ "$group" == "1" ]]; then
                local prev_group=""
                while IFS='|' read -r name php php_max status; do
                    local current_group
                    case "$sort_by" in
                        php)     current_group="$php" ;;
                        php_max) current_group="$php_max" ;;
                        status)  current_group="$status" ;;
                        *)       current_group="" ;;
                    esac

                    if [[ -n "$current_group" ]] && [[ "$current_group" != "$prev_group" ]] && [[ -n "$prev_group" ]]; then
                        printf '%-25s | %-8s | %-8s | %s\n' '-------------------------' '--------' '--------' '--------'
                    fi

                    local status_colored
                    if [[ "$status" == "running" ]]; then
                        status_colored="${COLOR_GREEN}running${COLOR_RESET}"
                    else
                        status_colored="${COLOR_YELLOW}stopped${COLOR_RESET}"
                    fi

                    local php_max_display="$php_max"
                    if [[ "$php_max" != "-" ]] && [[ "$php_max" != "$php" ]]; then
                        php_max_display="${COLOR_CYAN}${php_max}${COLOR_RESET}"
                    fi

                    printf "%-25s | %-8s | %-8b | %b\n" "$name" "$php" "$php_max_display" "$status_colored"
                    prev_group="$current_group"
                done < <(eval "$sort_cmd" "$temp_file")
            else
                while IFS='|' read -r name php php_max status; do
                    local status_colored
                    if [[ "$status" == "running" ]]; then
                        status_colored="${COLOR_GREEN}running${COLOR_RESET}"
                    else
                        status_colored="${COLOR_YELLOW}stopped${COLOR_RESET}"
                    fi

                    local php_max_display="$php_max"
                    if [[ "$php_max" != "-" ]] && [[ "$php_max" != "$php" ]]; then
                        php_max_display="${COLOR_CYAN}${php_max}${COLOR_RESET}"
                    fi

                    printf "%-25s | %-8s | %-8b | %b\n" "$name" "$php" "$php_max_display" "$status_colored"
                done < <(eval "$sort_cmd" "$temp_file")
            fi

            echo ""
            print_info "Always projects: $count"
            print_info "Storage metadata: $(dpx_meta_file)"
            ;;
    esac

    return 0
}