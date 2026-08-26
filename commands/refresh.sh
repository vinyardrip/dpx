#!/usr/bin/env bash
# =================================================================
# DPX Command: refresh - update local database datas with production
# =================================================================

# Connect modules
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/devilbox.sh"
source "${DPX_ROOT}/lib/projects.sh"

# =================================================================
# HELP
# =================================================================

show_refresh_help() {
    cat << EOF
 ${COLOR_BOLD}refresh${COLOR_RESET} - Update local database datas with production

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} refresh [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Updates local database fresh dump with production.
    Automatics creates reserve cop current local database.
    Replaces URL with production on local.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project DDEV
    --cms-type TYPE        Type CMS (wordpress, joomla, opencart, php)
    --db-file FILE         Name file database (without .sql)
    --prod-url URL         URL production site
    --prod-tld TLD         Domain zone production (by default: by)
    --no-backup            Not creating reserve cop
    -y, --yes              Skipp confirmation
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} refresh
    ${TOOL_NAME} refresh --project-name mysite --db-file mysite_prod
    ${TOOL_NAME} refresh --project-name mysite --prod-url https://mysite.com -y
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_refresh() {
    # Parsing arguments in global array
    parse_args "$@" || return 1

    # Show help
    if has_arg "help"; then
        show_refresh_help
        return 0
    fi

    print_header "Update local database with production"

    # --- Step 1: Selection type CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")

    if [[ -z "$cms_type" ]]; then
        cms_type=$(select_cms_type "Select type project for update") || return 1
    fi
    print_success "Chosen type: $(get_cms_name "$cms_type")"

    # --- Step 2: Name project ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Select project for update")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    # [FIX] Paths already expandeds in core.sh durings load_config
    local project_path
    project_path=$(projects_get_path "$project_name")

    validate_directory "$project_path" "Director project" || return 1

    # --- Step 3: Domain zone production ---
    local prod_tld prod_url
    prod_tld=$(get_arg "prod_tld" "$(get_config 'default_prod_tld')")
    prod_url=$(get_arg "prod_url" "")

    if [[ -z "$prod_url" ]]; then
        if ! has_arg "prod_tld"; then
            prompt_input "    Domain zone production (.by, .com, etc)" "$prod_tld" prod_tld
        fi

        local raw_domain="${project_name}.${prod_tld}"

        # [FIX] Cleanup from protocols ifs user inserted full URL
        raw_domain="${raw_domain#*//}"     # Removes all until // inclusive
        raw_domain="${raw_domain%%/*}"     # Removes all after first slash
        raw_domain="${raw_domain%/}"       # Removes trailing slash

        local protocol_choice
        protocol_choice=$(prompt_choice "3. Select protocol production" "https" "http")

        case "$protocol_choice" in
            https) prod_url="https://${raw_domain}" ;;
            http)  prod_url="http://${raw_domain}" ;;
        esac
    fi

    local local_url="https://${project_name}.$(get_config "project_tld")"

    # --- Step 4: Check status project ---
    print_info "Verify status project '$project_name'..."
    if ! ddev_is_project_running "$project_name"; then
        print_warning "Project '$project_name' not run."
        if has_arg "yes" || confirm "Start its now?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Operation cancel."
            return 1
        fi
    fi
    print_success "Project run and readies to work."

    # --- Step 5: Name file database ---
    local db_filename
    db_filename=$(get_arg "db_file" "")

    if [[ -z "$db_filename" ]]; then
        # [FIX] Autodetect nameds database from config CMS (wp-config.php /
        # configuration.php / config.php). Fallback — name project.
        local detected_db
        detected_db=$(db_get_db_name "$project_path" "$cms_type") || detected_db=""

        if [[ -n "$detected_db" ]]; then
            print_info "From config CMS defin database: ${detected_db}"
        else
            detected_db="$project_name"
            print_info "Name database not recognized, uses name project: ${detected_db}"
        fi

        prompt_input "2. Name file database from '$(get_db_prod_path)' (without .sql)" "$detected_db" db_filename
    fi

    local source_db_file
    source_db_file=$(db_get_prod_filepath "$db_filename")
    validate_file "$source_db_file" "File bases data with production" || return 1

    # =================================================================
    #  MANDATORY RESERVE COPI
    # =================================================================

    local backup_file=""
    if ! has_arg "no_backup"; then
        backup_file=$(db_backup_local "$project_name" "$project_path")

        if [[ -z "$backup_file" ]]; then
            print_warning "Not remove create reserve cop."
            if ! confirm "Continue without reserve cops?"; then
                return 1
            fi
        fi
    fi

    # --- Confirmation ---
    print_header "Verify parameters"
    echo "Project for update:      ${COLOR_GREEN}${project_name} ($(get_cms_name "$cms_type"))${COLOR_RESET}"
    echo "Source data (cont):     ${COLOR_GREEN}${source_db_file}${COLOR_RESET}"
    if [[ -n "$backup_file" ]]; then
        echo "Reserve cop:            ${COLOR_GREEN}${backup_file}${COLOR_RESET}"
    fi
    print_separator
    print_warning "Current local base data project '$project_name' will FULLY OVERWRIT!"

    if ! has_arg "yes"; then
        confirm "Continue update?" || return 1
    fi

    # [FIX] Stopping Devilbox ONLY after confirmation
    devilbox_stop

    # =================================================================
    #  Process update (in subshell for isolations cd)
    # =================================================================

    (
        cd "$project_path" || exit 1

        if uses_wp_cli_for_url_replace "$cms_type"; then
            # --- WordPress ---
            print_step "2" "Import production dump in DDEV"
            db_import "$source_db_file" "$project_path" || exit 1

            print_step "3" "Replace URL on local value (WP-CLI)"
            ddev_wp_search_replace "$prod_url" "$local_url" "$project_path" || exit 1

            # Full cleanup cache (handlers + transients + Redis + file cache)
            db_wp_clear_cache "$project_path"
        else
            # --- Joomla, OpenCart, other PHP projects ---
            print_step "2-3" "Preparation and import bases data with replace URL"
            db_import_with_replace "$source_db_file" "$prod_url" "$local_url" "$project_path" || exit 1

            # [ISSUE 1] CMS-aware post-processing; no WP checks for non-WP.
            print_warning "$(t msg.refresh.nonwp.warn "$(get_cms_name "$cms_type")")"
            if ! has_arg "yes"; then
                confirm "$(t q.refresh.nonwp)" || exit 1
            fi
            db_post_import_cms "$project_path" "$cms_type"
        fi

        # --- Completion ---
        print_celebration "Ready!"
        print_highlight "Local site '$project_name' success update datas with production."
        print_highlight "It accessible by address: ${local_url}"

        ddev_launch "$project_name"
    ) || return 1

    return 0
}