#!/usr/bin/env bash
# =================================================================
# DPX Command: backup - full backup project (files + base data)
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/backup.sh"

show_backup_help() {
    cat << EOF
 ${COLOR_BOLD}backup${COLOR_RESET} - Full backup project (files + base data)

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} backup [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Creates tar.gz archive: files project + dump database (ddev export-db).
    Exclude: .ddev/.importdb, node_modules, vendor, .git,
    folders output backups (.ddev-backups, backups).
    Automatic rotation: stores last N archives.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project DDEV
    --output DIR           Directory for the archive (by default: full_backup_path)
    --keep N               How many last archives store (by default: full_backup_keep)
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} backup
    ${TOOL_NAME} backup --project-name mysite --keep 5
EOF
}

cmd_backup() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_backup_help
        return 0
    fi

    print_header "Full backup project (files + database)"

    # --- Selection project ---
    local project_name
    project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Select project for backup")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    local project_path
    project_path=$(projects_get_path "$project_name")
    validate_directory "$project_path" "Project directory" || return 1

    # --- Project must was run (needed export-db) ---
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

    # --- Parameters backup ---
    local backup_dir keep_count
    backup_dir=$(get_arg "output" "$(get_config "full_backup_path")")
    keep_count=$(get_arg "keep" "$(get_config "full_backup_keep" "3")")

    # --- Confirmation ---
    echo "Project:            ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    printf '%s %s\n' "$(t msg.backup.directory)" "${COLOR_GREEN}${backup_dir}${COLOR_RESET}"
    printf '%s %s\n' "$(t msg.backup.retention)" "${COLOR_GREEN}${keep_count}${COLOR_RESET}"

    if ! has_arg "yes"; then
        confirm "Create full backup?" || { print_info "Cancel."; return 0; }
    fi

    # --- Create backup ---
    local archive_file
    archive_file=$(project_full_backup "$project_name" "$project_path" "$backup_dir" "$keep_count") || return 1

    [[ -n "$archive_file" ]] && print_highlight "Ready: $(basename "$archive_file")"
    return 0
}
