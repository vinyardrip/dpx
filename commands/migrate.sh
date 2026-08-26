#!/usr/bin/env bash
# =================================================================
# DPX Command: migrate - migration project with Devilbox on DDEV
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

show_migrate_help() {
    cat << EOF
 ${COLOR_BOLD}migrate${COLOR_RESET} - Migration project with Devilbox on DDEV

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} migrate [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Moves existing project from Devilbox in DDEV:
    - Copies files project
    - Exports database from Devilbox
    - Configures configuration CMS for DDEV
    - Imports database with replace URL

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME        Name project for DDEV
    --devilbox-folder FOLDER   Name folders project in Devilbox/data
    --cms-type TYPE            Type CMS (wordpress, joomla, opencart, php)
    --php-version VERSION      Version PHP for DDEV (by default: 7.4)
    --devilbox-php VERSION     Version PHP Devilbox for export (by default: 7)
    --db-name NAME             Name database in Devilbox
    --db-type TYPE             Type database for DDEV (mysql, mariadb)
    --db-version VERSION       Version database for DDEV (by default: 5.7)
    --no-db                    Project without bases data
    --keep-backup              Not remove file backup database
    -y, --yes                  Skipp confirmation
    -h, --help                 Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} migrate
    ${TOOL_NAME} migrate --project-name mysite --devilbox-folder mysite-old
    ${TOOL_NAME} migrate --project-name mysite --cms-type wordpress --php-version 8.1 -y
    ${TOOL_NAME} migrate --project-name mysite --no-db  # without bases data
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_migrate() {
    # Parsing arguments in global array
    parse_args "$@" || return 1

    # Show help
    if has_arg "help"; then
        show_migrate_help
        return 0
    fi

    print_header "Migration project with Devilbox on DDEV"

    # =================================================================
    #  Step 1: Selection type project
    # =================================================================
    local cms_type has_db=true

    if has_arg "no_db"; then
        has_db=false
        cms_type="php"
    else
        cms_type=$(get_arg "cms_type" "")
        if [[ -z "$cms_type" ]]; then
            print_header "Selection type project"
            echo "1. WordPress"
            echo "2. Joomla"
            echo "3. OpenCart"
            echo "4. Clean PHP/HTML (without bases data)"

            local choice
            read -r -p "Select [1]: " choice
            choice="${choice:-1}"

            case "$choice" in
                1) cms_type="wordpress"; has_db=true ;;
                2) cms_type="joomla"; has_db=true ;;
                3) cms_type="opencart"; has_db=true ;;
                4) cms_type="php"; has_db=false ;;
                *) print_error "Invalid selection."; return 1 ;;
            esac
        fi
    fi

    local ddev_project_type
    ddev_project_type=$(get_ddev_project_type "$cms_type")
    print_success "Chosen type CMS: $(get_cms_name "$cms_type") (for DDEV: $ddev_project_type)"

    # =================================================================
    #  Step 2: Input parameters project
    # =================================================================
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Name project for DDEV (e.g., my-new-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    # [FIX] Paths already expandeds in core.sh durings load_config
    local ddev_projects_path
    ddev_projects_path=$(get_config "ddev_projects_base_path")
    local ddev_path="${ddev_projects_path}/${project_name}"

    # Check existence directors
    if [[ -d "$ddev_path" ]]; then
        print_warning "Director project '$ddev_path' already exist."
        if has_arg "yes" || confirm "Remove its and ALL data DDEV for result project?"; then
            ddev delete "$project_name" -y 2>/dev/null || true
            rm -rf "$ddev_path"
            print_success "Project and its data delets."
        else
            print_error "Migration cancel."
            return 1
        fi
    fi

    # Folder project in Devilbox
    local devilbox_folder
    devilbox_folder=$(get_arg "devilbox_folder" "")

    if [[ -z "$devilbox_folder" ]]; then
        # Show available projects
        print_info "Available projects in Devilbox/data:"
        devilbox_list_projects | head -20
        echo ""
        prompt_input "2. Name folders project in Devilbox/data" "" devilbox_folder
    fi
    validate_non_empty "$devilbox_folder" "Name folders Devilbox" || return 1

    local devilbox_project_path
    devilbox_project_path=$(get_devilbox_project_path "$devilbox_folder")

    if ! validate_directory "$devilbox_project_path" "Source director Devilbox"; then
        return 1
    fi

    # Version PHP
    local php_version
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")

    if ! has_arg "php_version"; then
        prompt_input "3. Version PHP for DDEV" "$php_version" php_version
    fi

    # Parameters database
    local db_type db_version devilbox_php_version db_name
    db_type=$(get_arg "db_type" "$(get_config 'default_db_type')")
    db_version=$(get_arg "db_version" "$(get_config 'default_db_version')")
    devilbox_php_version=$(get_arg "devilbox_php" "7")
    db_name=$(get_arg "db_name" "")

    if [[ "$has_db" == true ]]; then
        if ! has_arg "devilbox_php"; then
            prompt_input "4. Version PHP Devilbox for export database" "$devilbox_php_version" devilbox_php_version
        fi
        if ! has_arg "db_type"; then
            prompt_input "5. Type database for DDEV (mysql, mariadb)" "$db_type" db_type
        fi
        if ! has_arg "db_version"; then
            prompt_input "6. Version database for DDEV" "$db_version" db_version
        fi

        print_header "Account data database in Devilbox"
        if [[ -z "$db_name" ]]; then
            prompt_input "Name database in Devilbox" "" db_name
        fi
        validate_non_empty "$db_name" "Name database" || return 1

        print_success "Use standard account data: user: root, password: (empty)"
    fi

    # =================================================================
    #  Forming URL
    # =================================================================
    local local_url="https://${project_name}.$(get_config "project_tld")"
    local old_url="https://${devilbox_folder}.loc"

    # [FIX] Paths already expandeds in core.sh durings load_config
    local db_backup_path
    db_backup_path=$(get_config "db_local_path")
    local backup_file="${db_backup_path}/db_${project_name}.sql"

    # =================================================================
    #  Confirmation parameters
    # =================================================================
    print_header "Verify parameters"
    echo "Name project DDEV:    ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Folder Devilbox:      ${COLOR_GREEN}${devilbox_folder}${COLOR_RESET}"
    echo "Type CMS:             ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "Version PHP (DDEV):   ${COLOR_GREEN}${php_version}${COLOR_RESET}"

    if [[ "$has_db" == true ]]; then
        echo "database in Devilbox:       ${COLOR_GREEN}${db_name}${COLOR_RESET}"
        echo "database for DDEV:         ${COLOR_GREEN}${db_type}:${db_version}${COLOR_RESET}"
        echo "Old URL:          ${COLOR_YELLOW}${old_url}${COLOR_RESET}"
        echo "New URL:           ${COLOR_GREEN}${local_url}${COLOR_RESET}"
        echo "File backup:         ${COLOR_GREEN}${backup_file}${COLOR_RESET}"
    fi

    print_separator

    if ! has_arg "yes"; then
        confirm "Continue migration?" || return 1
    fi

    # =================================================================
    #  Execute migrations
    # =================================================================

    # Step 1: Preparation environment
    print_header "Preparation environment"
    print_info "Stopping DDEV, so that release resources for Devilbox..."
    ddev poweroff 2>&1 || true
    print_success "DDEV stopped."

    # Step 2: Export database from Devilbox (ifs need)
    local devilbox_path
    devilbox_path=$(get_devilbox_path)

    if [[ "$has_db" == true ]]; then
        print_step "1" "Export bases data from Devilbox"

        # Work with Devilbox in subshell
        (
            cd "$devilbox_path" || exit 1

            # Switch on need version PHP
            if [[ -f ".env" ]]; then
                mv .env env.bak 2>/dev/null || true
            fi

            if [[ -f ".env-${devilbox_php_version}" ]]; then
                mv ".env-${devilbox_php_version}" .env
            else
                print_warning "File .env-${devilbox_php_version} not found"
            fi

            # Start services
            dpx_docker_compose up -d httpd php mysql 2>&1
            print_info "Expect start services..."
            sleep 15

            # Export database
            ensure_directory "$db_backup_path"
            dpx_docker_compose exec -T mysql mysqldump -u root "$db_name" > "$backup_file" 2>&1
            print_success "Base data success export."

            # Replace URL for non-WordPress (WordPress replace via WP-CLI)
            if [[ "$cms_type" != "wordpress" ]]; then
                print_step "2" "Replace URL in SQL-file"
                safe_sed_inplace "s|${old_url}|${local_url}|g" "$backup_file"
                # Remove backup file from BSD sed
                rm -f "${backup_file}${DPX_SED_INPLACE_EXT}" 2>/dev/null || true
                print_success "URL replacs."
            fi
        ) || return 1
    fi

    # Step 3: Copi files
    local step_num=3
    if [[ "$has_db" != true ]]; then
        step_num=1
    elif [[ "$cms_type" == "wordpress" ]]; then
        step_num=3
    else
        step_num=3
    fi

    print_step "$step_num" "Copi files project"
    mkdir -p "$ddev_path"
    cp -R "$devilbox_project_path/." "$ddev_path"
    print_success "Files copieds."

    # Step 4: Configuration DDEV (in subshell)
    ((step_num++))
    print_step "$step_num" "Configuration DDEV"

    (
        cd "$ddev_path" || exit 1

        if [[ "$has_db" == true ]]; then
            ddev config --project-name "$project_name" --project-type "$ddev_project_type" \
                --php-version "$php_version" --database "${db_type}:${db_version}" \
                --docroot "" --webserver-type apache-fpm --project-tld "$(get_config "project_tld")" 2>&1
        else
            ddev config --project-name "$project_name" --project-type "$ddev_project_type" \
                --php-version "$php_version" --disable-settings-management \
                --docroot "" --webserver-type apache-fpm --project-tld "$(get_config "project_tld")" 2>&1
        fi
    ) || return 1

    print_success "Configuration DDEV create."

    # Step 5: Setup configuration files CMS
    if [[ "$has_db" == true ]]; then
        ((step_num++))
        configure_cms_for_ddev "$ddev_path" "$cms_type" "$local_url"
    fi

    # Step 6: Released ports and start DDEV
    if [[ "$has_db" == true ]]; then
        print_header "Released ports"
        print_info "Stopping Devilbox before start DDEV..."
        (cd "$devilbox_path" && dpx_docker_compose down >/dev/null 2>&1)
        print_success "Devilbox success stopped."
    fi

    ((step_num++))
    print_step "$step_num" "Start DDEV"

    (
        cd "$ddev_path" || exit 1
        ddev start -y 2>&1
    ) || return 1

    print_success "Project run."

    # Step 7: Import database
    if [[ "$has_db" == true ]]; then
        print_info "Import bases data..."

        (
            cd "$ddev_path" || exit 1
            ddev import-db --file="$backup_file" 2>&1
        ) || return 1

        print_success "Base data imported."

        # Step 8: Replace URL for WordPress
        if [[ "$cms_type" == "wordpress" ]]; then
            ((step_num++))
            print_step "$step_num" "Automatic replace URL (WP-CLI)"

            (
                cd "$ddev_path" || exit 1
                ddev exec "wp search-replace '$old_url' '$local_url' --all-tables --allow-root" 2>&1
            ) || return 1

            print_success "URL success replacs."
        fi
    fi

    # Final step: delete backup
    if [[ "$has_db" == true ]] && ! has_arg "keep_backup"; then
        print_header "Final step"
        if has_arg "yes" || confirm "Remove file backup ($backup_file)?" "n"; then
            rm -f "$backup_file"
            print_success "File delete."
        else
            print_info "File saved: $backup_file"
        fi
    fi

    # Restore configurations Devilbox (in subshell)
    if [[ "$has_db" == true ]] && [[ -f "${devilbox_path}/env.bak" ]]; then
        (
            cd "$devilbox_path" || exit 1
            mv .env ".env-${devilbox_php_version}" 2>/dev/null || true
            mv env.bak .env
        )
    fi

    # --- Completion ---
    print_celebration "Migration success completion!"
    print_highlight "Site accessible: ${local_url}"

    ddev_launch "$project_name"

    return 0
}

# Export functions command