#!/usr/bin/env bash
# =================================================================
# DPX Command: edit - editing metadata project
# Storage: ~/.config/dpx/projects.json
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# HELP
# =================================================================

show_edit_help() {
    cat << EOF
 ${COLOR_BOLD}edit${COLOR_RESET} - Editing metadata project

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} edit <project> [options]
    ${TOOL_NAME} edit [options]  (interactive selection project)

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Edits metadata project: maximum working version PHP,
    notes and other parameters.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --php-max VERSION   Install maximum working version PHP
    --notes "text"     Add note to project
    --show              Show current metadata
    --delete            Remove all metadata project
    -h, --help          Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} edit mysite --php-max 8.2
    ${TOOL_NAME} edit --php-max 8.3
    ${TOOL_NAME} edit mysite --show
    ${TOOL_NAME} edit mysite --notes "On PHP 8.3 fatal error"
    ${TOOL_NAME} edit mysite --delete

 ${COLOR_BOLD}Workflow:${COLOR_RESET}
    1. ${TOOL_NAME} set-php mysite     # Test different versions PHP
    2. Site works on PHP 8.2, on 8.3 falls
    3. ${TOOL_NAME} edit mysite --php-max 8.2  # Fixed result
    4. ${TOOL_NAME} list              # Kind php_max in list

 ${COLOR_BOLD}Storage:${COLOR_RESET}
    ~/.config/dpx/projects.json
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_edit() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_edit_help
        return 0
    fi

    # Get name project
    local project_name
    project_name=$(get_positional_arg 1)

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Select project for editing")
        [[ -z "$project_name" ]] && return 1
    fi

    # Verify existence project
    if ! projects_exists "$project_name"; then
        print_error "Project '$project_name' not found"
        return 1
    fi

    local project_path
    project_path=$(projects_get_path "$project_name")

    # --- FLAG --show ---
    if has_arg "show"; then
        print_header "Metadata: $project_name"

        local meta
        meta=$(dpx_meta_get_all "$project_name")

        if [[ -n "$meta" ]] && [[ "$meta" != "null" ]] && [[ "$meta" != "" ]]; then
            echo ""
            echo "$meta" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
            echo ""
            print_info "File: $(dpx_meta_file)"
        else
            print_warning "Metadata is empty"
        fi
        return 0
    fi

    # --- FLAG --delete ---
    if has_arg "delete"; then
        print_header "Delete metadata: $project_name"

        if dpx_meta_exists "$project_name"; then
            if confirm "Remove all metadata project '$project_name'?"; then
                dpx_meta_delete "$project_name"
                print_success "Metadata deleted"
            fi
        else
            print_warning "No metadata found"
        fi
        return 0
    fi

    # --- FLAG --php-max ---
    local php_max
    php_max=$(get_arg "php_max" "")

    if [[ -n "$php_max" ]]; then
        if [[ ! "$php_max" =~ ^[0-9]+\.[0-9]+$ ]]; then
            print_error "Invalid format versions PHP: $php_max"
            print_info "Expects format: 8.2, 7.4, 8.3 and t.d."
            return 1
        fi

        local current_php
        current_php=$(projects_get_php_version "$project_name")

        # Get type project from DDEV config
        local project_type
        project_type=$(grep -E "^type:" "${project_path}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

        print_header "Update metadata: $project_name"
        echo ""
        printf "Type project:           %s\n" "$project_type"
        printf "Current version PHP:    %s\n" "$current_php"
        printf "Maximum working:  %s\n" "$php_max"
        echo ""

        if confirm "Record php_max = $php_max?"; then
            dpx_meta_set "$project_name" "type" "$project_type"
            dpx_meta_set "$project_name" "php_max" "$php_max"
            dpx_meta_set "$project_name" "tested" "$(date +%Y-%m-%d)"
            print_success "Metadata updats"
            echo ""
            print_info "Storage: $(dpx_meta_file)"
        fi
        return 0
    fi

    # --- FLAG --notes ---
    local notes
    notes=$(get_arg "notes" "")

    if [[ -n "$notes" ]]; then
        dpx_meta_set "$project_name" "notes" "$notes"
        print_success "Note saved"
        return 0
    fi

    # --- INTERACTIVE MODE ---
    print_header "$(t "edit.title" "$project_name")"

    local current_php
    current_php=$(projects_get_php_version "$project_name")

    local saved_php_max
    saved_php_max=$(dpx_get_php_max "$project_name")

    local saved_notes
    saved_notes=$(dpx_get_notes "$project_name")

    local saved_tested
    saved_tested=$(dpx_get_tested "$project_name")

    local php_ver="$current_php"
    local php_max="$saved_php_max"
    local date_test="$saved_tested"
    local notes="$saved_notes"

    echo ""
    printf "%s\n" "$(t "edit.php_current" "$php_ver")"
    printf "%s\n" "$(t "edit.php_max" "${php_max:--}")"
    printf "%s\n" "$(t "edit.date_testing" "${date_test:--}")"
    printf "%s\n" "$(t "edit.notes" "${notes:--}")"
    echo ""

    echo "$(t "edit.menu.title")"
    echo "  $(t "edit.menu.php_max")"
    echo "  $(t "edit.menu.note")"
    echo "  $(t "edit.menu.show")"
    echo "  $(t "edit.menu.remove")"
    echo "  $(t "edit.menu.exit")"
    echo ""

    local choice
    read -r -p "$(t "edit.prompt")" choice

    case "$choice" in
        1)
            local new_php_max
            read -r -p "Enter maximum working version PHP (e.g., 8.2): " new_php_max

            if [[ -n "$new_php_max" ]]; then
                if [[ ! "$new_php_max" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    print_error "Invalid format versions"
                    return 1
                fi

                # Get type project
                local project_type
                project_type=$(grep -E "^type:" "${project_path}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

                dpx_meta_set "$project_name" "type" "$project_type"
                dpx_meta_set "$project_name" "php_max" "$new_php_max"
                dpx_meta_set "$project_name" "tested" "$(date +%Y-%m-%d)"
                print_success "php_max = $new_php_max saved"
            fi
            ;;
        2)
            local new_notes
            read -r -p "Enter note: " new_notes

            if [[ -n "$new_notes" ]]; then
                dpx_meta_set "$project_name" "notes" "$new_notes"
                print_success "Note saved"
            fi
            ;;
        3)
            echo ""
            dpx_meta_get_all "$project_name" | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || print_warning "Metadata is empty"
            echo ""
            print_info "File: $(dpx_meta_file)"
            ;;
        4)
            if confirm "Remove all metadata project?"; then
                dpx_meta_delete "$project_name"
                print_success "Metadata deleted"
            fi
            ;;
        0|*)
            print_info "Exit"
            ;;
    esac
}