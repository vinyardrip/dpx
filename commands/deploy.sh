#!/usr/bin/env bash
# =================================================================
# DPX Command: deploy - deploy existing project on DDEV
# =================================================================

# Connect modules
source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/devilbox.sh"

# =================================================================
# HELP
# =================================================================

show_deploy_help() {
    cat << EOF
 ${COLOR_BOLD}deploy${COLOR_RESET} - Deploy existing project on DDEV

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} deploy [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Deploys existing project on DDEV with import database with production.
    Automatics configures configuration CMS and replaces URL.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project (folders)
    --cms-type TYPE        Type CMS (wordpress, joomla, opencart, php)
    --db-file FILE         Name file database (without .sql)
    --prod-url URL         URL production site
    --php-version VERSION  Version PHP (by default: 7.4)
    --db-type TYPE         Type database (mysql, mariadb)
    --db-version VERSION   Version database (by default: 5.7)
    -y, --yes              Skipp confirmation
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} deploy
    ${TOOL_NAME} deploy --project-name mysite --cms-type wordpress
    ${TOOL_NAME} deploy --project-name mysite --php-version 8.1 -y
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_deploy() {
    # Parsing arguments in global array
    parse_args "$@" || return 1

    # Show help
    if has_arg "help"; then
        show_deploy_help
        return 0
    fi

    print_header "Deploy existing project on DDEV"

    # --- Step 1: Selection type project ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")

    if [[ -z "$cms_type" ]]; then
        cms_type=$(select_cms_type "Select type project") || return 1
    fi
    print_success "Chosen type CMS: $(get_cms_name "$cms_type")"

    # --- Step 2: Input nameds project ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Enter name folders project (e.g., my-joomla-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    # Paths already expandeds in core.sh durings load_config
    local ddev_projects_path
    ddev_projects_path=$(get_config "ddev_projects_base_path")
    local project_path="${ddev_projects_path}/${project_name}"

    validate_directory "$project_path" "Director project" || return 1

    # --- Step 3: Check existing project DDEV ---
    if ddev_project_exists "$project_name"; then
        print_warning "DDEV already contains data for project '$project_name'."
        if has_arg "yes" || confirm "Remove all existing data DDEV and start anew?"; then
            ddev delete "$project_name" -y 2>&1
            print_success "Old data DDEV success delets."
        else
            print_error "Deploy cancel."
            return 1
        fi
    fi

    # --- Step 4: Input nameds file database ---
    local db_filename
    db_filename=$(get_arg "db_file" "")

    if [[ -z "$db_filename" ]]; then
        prompt_input "2. Name file database from '$(get_db_prod_path)' (without .sql)" "" db_filename
    fi
    validate_non_empty "$db_filename" "Name file database" || return 1

    local source_db_file
    source_db_file=$(db_get_prod_filepath "$db_filename")
    validate_file "$source_db_file" "File bases data" || return 1

    # --- Step 5: Input URL production ---
    local prod_url
    prod_url=$(get_arg "prod_url" "")

    if [[ -z "$prod_url" ]]; then
        local raw_domain
        prompt_input "3. Domain production site (e.g., my-joomla-site.by)" "" raw_domain
        validate_non_empty "$raw_domain" "Domain" || return 1

        # [FIX] Cleanup from protocols and trailing slash
        # User may inserted https://mysite.com/ from browser
        raw_domain="${raw_domain#*//}"     # Removes all until // inclusive (http://, https://)
        raw_domain="${raw_domain%%/*}"     # Removes all after first slash (paths)
        raw_domain="${raw_domain%/}"       # Removes trailing slash ifs remaining

        local protocol_choice
        protocol_choice=$(prompt_choice "   Select protocol" "https" "http")

        case "$protocol_choice" in
            https) prod_url="https://${raw_domain}" ;;
            http)  prod_url="http://${raw_domain}" ;;
        esac
    fi

    # --- Step 6: Additional parameters ---
    local php_version db_type db_version
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")
    db_type=$(get_arg "db_type" "$(get_config 'default_db_type')")
    db_version=$(get_arg "db_version" "$(get_config 'default_db_version')")

    if ! has_arg "php_version"; then
        prompt_input "4. Version PHP for DDEV" "$php_version" php_version
        prompt_input "5. Type database (mysql, mariadb)" "$db_type" db_type
        prompt_input "6. Version database (e.g., 5.7)" "$db_version" db_version
    fi

    local local_url="https://${project_name}.$(get_config "project_tld")"
    local ddev_project_type
    ddev_project_type=$(get_ddev_project_type "$cms_type")

    # --- Step 7: Confirmation parameters ---
    print_header "Verify parameters"
    echo "Name project:      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Type CMS:          ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "Old URL:       ${COLOR_YELLOW}${prod_url}${COLOR_RESET}"
    echo "New URL:        ${COLOR_GREEN}${local_url}${COLOR_RESET}"
    echo "Version PHP:       ${COLOR_GREEN}${php_version}${COLOR_RESET}"
    echo "Base data:      ${COLOR_GREEN}${db_type}:${db_version}${COLOR_RESET}"
    print_separator

    if ! has_arg "yes"; then
        confirm "All back? Begin?" || return 1
    fi

    # [FIX] Stopping Devilbox ONLY after confirmation all parameters
    # This prevents stop working environments durings error input
    devilbox_stop

    # =================================================================
    #  Execute deploy (in subshell for isolations cd)
    # =================================================================

    (
        cd "$project_path" || exit 1

        # Step 1: Configuration DDEV
        ddev_configure_project "$project_name" "$ddev_project_type" "$php_version" "$db_type" "$db_version" "" "$(get_config "project_tld")" || exit 1

        # Step 2: Start project
        safe_start_ddev_project "$project_name" "$project_path" || exit 1

        # Step 3: Setup configuration files CMS
        configure_cms_for_ddev "$project_path" "$cms_type" "$local_url"

        # Steps 4-5: Import and replace URL
        if uses_wp_cli_for_url_replace "$cms_type"; then
            # WordPress: import + WP-CLI replace
            print_step "4" "Import bases data"
            db_import "$source_db_file" "$project_path" || exit 1

            print_step "5" "Replace URL in base data (WP-CLI)"
            ddev_wp_search_replace "$prod_url" "$local_url" "$project_path" || exit 1

            # Full cleanup cache (handlers + transients + Redis + file cache)
            db_wp_clear_cache "$project_path"
        else
            # Joomla, OpenCart, etc: import with replace URL in file
            print_step "4-5" "Preparation and import bases data with replace URL"
            db_import_with_replace "$source_db_file" "$prod_url" "$local_url" "$project_path" || exit 1
        fi

        # --- Completion ---
        print_celebration "Project success deployed!"
        print_highlight "Site accessible by address: ${local_url}"

        ddev_launch "$project_name"
    ) || return 1

    return 0
}