#!/usr/bin/env bash
# =================================================================
# DPX Command: db-snap - Fast local snapshot database
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"

show_db_snap_help() {
    cat << EOF
 Snap - quick local DB snapshot into db_local_path

 Usage:
    dpx db snap | dpx db-snap [options]

 Options:
    --project-name NAME    Target DDEV project
    -y, --yes              Skip confirmations
EOF
}

cmd_db_snap() {
    parse_args "$@" || return 1
    print_header "Create a local database snapshot"

    # 1. Selection project
    local project_name
    project_name=$(projects_select_interactive "Select project for snapshot database")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # 2. Check status DDEV
    if ! ddev_is_project_running "$project_name"; then
        confirm "Project '$project_name' is not running. Start it for export?" && \
            safe_start_ddev_project "$project_name" "$project_path" || return 1
    fi

    # 3. Generation nameds and export
    # [OPTIMIZATION] Save path in variable (avoid repeat calls)
    local db_dir
    db_dir=$(get_db_local_path)
    ensure_directory "$db_dir" || return 1
    if ! chmod 700 "$db_dir" 2>/dev/null; then
        print_error "Failed to secure permissions on snapshot directory: $db_dir"
        return 1
    fi

    # db_generate_export_filename already generates .sql (without .gz)
    local out_file
    out_file="${db_dir}/$(db_generate_export_filename "$project_name" "SNAP")"

    print_info "Exporting database [$project_name] (uncompressed for fast access)..."

    # Execute in subshell for isolations cd
    (
        umask 077
        cd "$project_path" || exit 1

        # [FIX] Removed 2>&1 - leave stderr visible for diagnostics errors
        # Backups criticals, errors shoulds was visibles!
        if ddev export-db --gzip=false --file="$out_file" >/dev/null; then
            if ! chmod 600 "$out_file" 2>/dev/null; then
                print_error "Failed to secure permissions on snapshot: $out_file"
                exit 1
            fi
            print_success "Snapshot created: $(basename "$out_file")"
            print_info "Size: $(du -h "$out_file" | awk '{print $1}')"
        else
            print_error "Failed to create snapshot."
            exit 1
        fi
    ) || return 1

    # 4. Rotation old snapshots (leave 3 last)
    # Important: invoke OUTSIDE subshell, only after success export
    core_rotate_backups "$project_name" "$db_dir" "SNAP" 3
}

# [FIX] Removed export -f - function invokes via source in router,
# export not needed and pollutes environment