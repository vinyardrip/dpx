#!/usr/bin/env bash
# =================================================================
# DPX Command: db-restore - Restore database from local backup
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"

show_db_restore_help() {
    cat << EOF
 Restore - restore project DB from a local backup archive

 Usage:
    dpx db restore | dpx db-restore

 Shows available backups (newest first), takes a protective dump
 of the current DB, imports the selected one and runs CMS-aware
 post-import processing.
EOF
}

cmd_db_restore() {
    parse_args "$@" || return 1
    print_header "$(t dbrestore.title)"

    # 1. Selection project
    local project_name
    project_name=$(projects_select_interactive "$(t dbrestore.select.project)")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # 2. Search available backups in db_local
    local backup_dir=$(get_db_local_path)
    if [[ ! -d "$backup_dir" ]]; then
        print_error "Backups directory not found: $backup_dir"
        return 1
    fi

    # [FIX P-8] Unified dump selection via db_pick_dump_file:
    #   * prefix-locked to "${project_name}_" (project `shop` no longer
    #     matches `shop2_SNAP_...` dumps — the old glob lacked the `_`
    #     delimiter);
    #   * filename-timestamp ordering (newest first) instead of mtime;
    #   * refuses a widened list in non-tty sessions instead of silently
    #     defaulting to entry 1 of another project's dumps.
    # --db-file (or a positional path) is honored as a direct input.
    local selected_file=""
    local file_arg
    file_arg="$(get_arg "db_file" "")"
    [[ -z "$file_arg" ]] && file_arg="$(get_positional_arg 1 "")"
    if [[ -n "$file_arg" ]]; then
        # Accepts a bare name in db_local_path or an absolute path.
        if [[ -f "$file_arg" ]]; then
            selected_file="$file_arg"
        elif [[ -f "${backup_dir}/${file_arg}" ]]; then
            selected_file="${backup_dir}/${file_arg}"
        elif [[ -f "${backup_dir}/${file_arg}.sql" ]]; then
            selected_file="${backup_dir}/${file_arg}.sql"
        else
            print_error "Dump file not found: $file_arg"
            return 1
        fi
    else
        selected_file=$(db_pick_dump_file "$backup_dir" "${project_name}_") || {
            print_warning "$(t dbrestore.no.backups "$project_name" "$backup_dir")"
            return 1
        }
    fi

    # 4. Check status DDEV
    if ! ddev_is_project_running "$project_name"; then
        confirm "Project '$project_name' is not running. Start it now?" && safe_start_ddev_project "$project_name" "$project_path" || return 1
    fi

    # 5. Execute import
    # [FIX I-4] Declining a DESTRUCTIVE confirm now prints a clear
    # cancelled message and returns non-zero instead of exiting rc=0
    # silently (which looked like success to callers/scripts).
    if confirm "$(t dbrestore.confirm.replace "$project_name" "$(basename "$selected_file")")"; then
        # Create protective backup current state before import
        print_info "$(t dbrestore.protective)"
        local backup_file
        backup_file=$(db_backup_local "$project_name" "$project_path") || { print_error "$(t dbrestore.protective.failed)"; return 1; }
        print_success "$(t dbrestore.protective.saved "$(basename "$backup_file")")"

        print_info "$(t dbrestore.importing)"

        # [ISSUE 1] Type CMS: from the --cms-type argument or autodetection.
        # Resolved BEFORE the import — post-processing depends on it.
        local cms_type
        cms_type=$(get_arg "cms_type" "")
        if [[ -z "$cms_type" ]]; then
            cms_type=$(detect_cms_type "$project_path")
            print_info "$(t dbrestore.cms.detected "$(get_cms_name "$cms_type")")"
        fi

        # Execute in subshell for isolations cd
        (
            cd "$project_path" || exit 1

            if db_import "$selected_file" "$project_path"; then
                print_success "$(t dbrestore.done)"

                # [ISSUE 1] Post-processing PAGE by type CMS.
                # WordPress-routine (wp-cli) performs only for wordpress;
                # Joomla/OpenCart/PHP receive with action and message.
                db_post_import_cms "$project_path" "$cms_type"
            else
                print_error "$(t dbrestore.import.failed)"
                exit 1
            fi
        ) || return 1
    else
        # [FIX I-4] Explicit decline: visible message + non-zero status.
        print_warning "$(t common.cancelled)"
        return 1
    fi
}