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
    Automatically creates a safety backup of the current local database.
    Replaces URL with production on local.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project DDEV
    --cms-type TYPE        Type CMS (wordpress, joomla, opencart, php)
    --db-file FILE         Name file database (without .sql)
    --prod-url URL         URL production site
    --prod-tld TLD         Domain zone production (by default: by)
    --no-backup            Skip the safety backup
    -y, --yes              Skip confirmations
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

    print_header "$(t refresh.title)"

    # --- Step 1: Selection type CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")

    if [[ -z "$cms_type" ]]; then
        cms_type=$(select_cms_type "$(t refresh.select.cms)") || return 1
    fi
    print_success "$(t refresh.chosen.type "$(get_cms_name "$cms_type")")"

    # --- Step 2: Name project ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "$(t refresh.select.project)")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    # [FIX] Paths already expandeds in core.sh durings load_config
    local project_path
    project_path=$(projects_get_path "$project_name")

    validate_directory "$project_path" "Project directory" || return 1

    # --- Step 3: Domain zone production ---
    local prod_tld prod_url
    prod_tld=$(get_arg "prod_tld" "$(get_config 'default_prod_tld')")
    prod_url=$(get_arg "prod_url" "")

    if [[ -z "$prod_url" ]]; then
        if ! has_arg "prod_tld"; then
            prompt_input "$(t refresh.zone.prompt)" "$prod_tld" prod_tld
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

    local local_url
    local_url="https://${project_name}.$(get_config "project_tld")"

    # --- Step 4: Check status project ---
    print_info "Verifying project status '$project_name'..."
    if ! ddev_is_project_running "$project_name"; then
        print_warning "Project '$project_name' is not running."
        if has_arg "yes" || confirm "Start its now?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Operation cancelled."
            return 1
        fi
    fi
    print_success "$(t refresh.running)"

    # --- Step 5: Name file database ---
    local db_filename
    db_filename=$(get_arg "db_file" "")

    if [[ -z "$db_filename" ]]; then
        # [FIX] Autodetect nameds database from config CMS (wp-config.php /
        # configuration.php / config.php). Fallback — name project.
        local detected_db
        if ! detected_db=$(db_get_db_name "$project_path" "$cms_type"); then
            print_error "Configured database name is invalid. Refresh aborted."
            return 1
        fi

        if [[ -z "$detected_db" ]]; then
            if [[ -t 0 ]]; then
                prompt_input "$(t refresh.db.name)" "$project_name" detected_db
            else
                detected_db="$project_name"
            fi
        fi
        print_info "$(t refresh.db.resolved "${detected_db}")"
        local picked_dump=""
        if picked_dump=$(db_pick_dump_file "$(get_db_prod_path)" "$detected_db"); then
            db_filename="$picked_dump"
        else
            prompt_input "2. Database dump from '$(get_db_prod_path)' (name or path)" "$detected_db" db_filename
        fi
    fi

    local source_db_file
    if [[ "$db_filename" == */* ]]; then
        source_db_file="$db_filename"
    else
        source_db_file=$(db_get_prod_filepath "$db_filename")
    fi
    validate_file "$source_db_file" "Production database dump" || return 1

    # =================================================================
    #  MANDATORY RESERVE COPI
    # =================================================================

    local backup_file=""
    if ! has_arg "no_backup"; then
        backup_file=$(db_backup_local "$project_name" "$project_path")

        if [[ -z "$backup_file" ]]; then
            print_warning "Failed to create the safety backup."
            if ! confirm "Continue without a safety backup?"; then
                return 1
            fi
        fi
    fi

    # --- Confirmation ---
    print_header "Verify parameters"
    echo "$(t refresh.verify.project "${project_name}" "$(get_cms_name "$cms_type")")"
    echo "$(t refresh.verify.source "${source_db_file}")"
    if [[ -n "$backup_file" ]]; then
        echo "$(t refresh.verify.backup "${backup_file}")"
    fi
    print_separator
    print_warning "$(t refresh.overwrite.warn "$project_name")"

    if ! has_arg "yes"; then
        confirm "$(t refresh.continue)" || return 1
    fi

    # [FIX] Stopping Devilbox ONLY after confirmation
    devilbox_stop

    # =================================================================
    #  [C-3] INTERRUPT SAFETY: trap + snapshot marker
    #
    # The import/replace below is a long, destructive DB mutation. Before
    # it starts, create a pre-mutation ddev snapshot and register it in
    # .dpx/current_snapshot so boot-time orphan recovery can restore it
    # after a crash. INT/TERM traps attempt an immediate in-process
    # restore; if that fails the marker stays for `check_orphaned_snapshot`.
    # =================================================================

    refresh_snapshot_marker() {
        rm -f "${project_path}/.dpx/current_snapshot" 2>/dev/null
        trap - INT TERM EXIT
    }

    refresh_interrupted() {
        local sig="$1"
        echo "" >&2
        print_warning "Interrupted (${sig}) — restoring pre-mutation database snapshot..." >&2
        local snap_name
        snap_name="$(head -1 "${project_path}/.dpx/current_snapshot" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$snap_name" ]]; then
            if (cd "$project_path" && ddev snapshot restore "$snap_name" 2>&1); then
                print_success "Database restored from snapshot: $snap_name" >&2
                refresh_snapshot_marker
            else
                print_error "Snapshot restore failed; marker preserved for orphan recovery." >&2
            fi
        else
            print_error "No snapshot marker found; manual recovery may be required (dpx db restore)." >&2
        fi
        exit 130
    }

    local refresh_snap_name
    refresh_snap_name=$(db_create_snapshot "$project_path" "pre_refresh") || {
        print_error "Pre-mutation safety snapshot failed. Aborting to protect the database."
        return 1
    }
    mkdir -p "${project_path}/.dpx" 2>/dev/null
    printf '%s\n' "$refresh_snap_name" > "${project_path}/.dpx/current_snapshot"

    trap 'refresh_interrupted INT' INT
    trap 'refresh_interrupted TERM' TERM

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
            ddev_wp_search_replace "$prod_url" "$local_url" "$project_path" \
                --precise --skip-plugins --skip-themes || exit 1

            # Full cleanup cache (handlers + transients + Redis + file cache)
            db_wp_clear_cache "$project_path"
        else
            # --- Joomla, OpenCart, other PHP projects ---
            print_step "2-3" "Prepare and import the database with URL replacement"
            db_import_with_replace "$source_db_file" "$prod_url" "$local_url" "$project_path" || exit 1

            # [ISSUE 1] CMS-aware post-processing; no WP checks for non-WP.
            print_warning "$(t msg.refresh.nonwp.warn "$(get_cms_name "$cms_type")")"
            if ! has_arg "yes"; then
                confirm "$(t q.refresh.nonwp)" || exit 1
            fi
            db_post_import_cms "$project_path" "$cms_type"
        fi

        # --- Completion ---
        print_celebration "$(t refresh.done)"
        print_highlight "$(t refresh.done.detail "$project_name")"
        print_highlight "$(t refresh.done.url "${local_url}")"

        ddev_launch "$project_name"
    )
    local refresh_rc=$?
    trap - INT TERM

    if [[ $refresh_rc -eq 0 ]]; then
        # [C-3] Success: local DB intentionally holds the imported data.
        # Drop the marker so the next command does not offer a pointless
        # restore of the now-superseded pre-mutation snapshot.
        refresh_snapshot_marker
        return 0
    fi

    # [C-3] Handled failure mid-mutation: the DB may be partially
    # imported/replaced. Attempt an immediate restore from the marker; if
    # that fails, leave the marker for boot-time orphan recovery.
    print_warning "Update failed mid-operation — attempting snapshot restore..." >&2
    local snap_name
    snap_name="$(head -1 "${project_path}/.dpx/current_snapshot" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$snap_name" ]] \
       && (cd "$project_path" && ddev snapshot restore "$snap_name" 2>&1); then
        print_success "Database restored from snapshot: $snap_name" >&2
        refresh_snapshot_marker
    else
        print_error "Snapshot restore failed; marker preserved for orphan recovery." >&2
    fi
    return 1
}
