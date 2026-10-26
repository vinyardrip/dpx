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

# =================================================================
# IMPORT TRANSACTION STATE (R-11)
#
# The selected dump overwrites the live database. A pre-import DDEV
# snapshot is registered before the first byte is imported so INT/TERM
# (and process exit after an unexpected failure) can restore the previous
# database state.
# =================================================================

_DPX_DB_RESTORE_PROJECT_PATH=""
_DPX_DB_RESTORE_SNAPSHOT=""
_DPX_DB_RESTORE_RECOVERING=0

_dpx_db_restore_clear_marker() {
    rm -f "${_DPX_DB_RESTORE_PROJECT_PATH}/.dpx/current_snapshot" 2>/dev/null
    _DPX_DB_RESTORE_SNAPSHOT=""
}

_dpx_db_restore_recover() {
    local project_path="${_DPX_DB_RESTORE_PROJECT_PATH:-}"
    local snapshot_name="${_DPX_DB_RESTORE_SNAPSHOT:-}"

    [[ -n "$project_path" && -n "$snapshot_name" ]] || return 1
    db_restore_snapshot "$project_path" "$snapshot_name"
}

_dpx_db_restore_interrupted() {
    local sig="$1"

    # EXIT can fire after an INT/TERM handler calls exit; never restore
    # twice during the same teardown.
    [[ "${_DPX_DB_RESTORE_RECOVERING:-0}" == "1" ]] && return 0
    _DPX_DB_RESTORE_RECOVERING=1

    echo "" >&2
    print_warning "Interrupted (${sig}) — restoring pre-import database snapshot..." >&2
    if _dpx_db_restore_recover; then
        print_success "Database restored from snapshot: ${_DPX_DB_RESTORE_SNAPSHOT}" >&2
        _dpx_db_restore_clear_marker
    else
        print_error "Snapshot restore failed; marker preserved for orphan recovery." >&2
    fi

    if [[ "$sig" != "EXIT" ]]; then
        exit 130
    fi
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
    local backup_dir
    backup_dir=$(get_db_local_path)
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

    # [R-11] Canonicalize before the import subshell changes directory.
    local unresolved_selected_file="$selected_file"
    if ! selected_file="$(dpx_absolute_path "$selected_file")"; then
        print_error "Cannot resolve dump file path: ${unresolved_selected_file}"
        return 1
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

        # [R-11] Pre-import snapshot + signal traps. The local protective
        # dump above is a file backup; this is the in-DDEV rollback point
        # used for automatic recovery if the import is interrupted.
        local import_snapshot
        import_snapshot=$(db_create_snapshot "$project_path" "pre_db_restore") || {
            print_error "Pre-import database snapshot failed. Import aborted."
            return 1
        }
        if [[ -z "$import_snapshot" ]]; then
            print_error "Pre-import database snapshot returned an empty name. Import aborted."
            return 1
        fi
        if ! mkdir -p "${project_path}/.dpx" 2>/dev/null; then
            print_error "Failed to create restore state directory: ${project_path}/.dpx"
            return 1
        fi
        if ! printf '%s\n' "$import_snapshot" > "${project_path}/.dpx/current_snapshot" 2>/dev/null; then
            rm -f "${project_path}/.dpx/current_snapshot" 2>/dev/null
            print_error "Failed to register the pre-import snapshot marker. Import aborted."
            return 1
        fi

        _DPX_DB_RESTORE_PROJECT_PATH="$project_path"
        _DPX_DB_RESTORE_SNAPSHOT="$import_snapshot"
        _DPX_DB_RESTORE_RECOVERING=0
        trap '_dpx_db_restore_interrupted INT' INT
        trap '_dpx_db_restore_interrupted TERM' TERM
        trap '_dpx_db_restore_interrupted EXIT' EXIT

        # Execute in subshell for isolations cd
        local import_rc=0
        (
            cd "$project_path" || exit 1

            if db_import "$selected_file" "$project_path"; then
                print_success "$(t dbrestore.done)"

                # [ISSUE 1] Post-processing PAGE by type CMS.
                # WordPress-routine (wp-cli) performs only for wordpress;
                # Joomla/OpenCart/PHP receive with action and message.
                if ! db_post_import_cms "$project_path" "$cms_type"; then
                    print_warning "Post-import CMS processing failed; database import itself succeeded."
                fi
            else
                print_error "$(t dbrestore.import.failed)"
                exit 1
            fi
        ) || import_rc=$?

        trap - INT TERM EXIT

        if (( import_rc != 0 )); then
            print_error "$(t dbrestore.import.failed)"
            if _dpx_db_restore_recover; then
                print_warning "Database restored from pre-import snapshot: $import_snapshot"
                _dpx_db_restore_clear_marker
            else
                print_error "Automatic restore failed; recovery marker preserved for orphan recovery."
            fi
            return 1
        fi

        # Successful import: drop the marker so boot-time orphan recovery
        # does not roll back a completed restore.
        _dpx_db_restore_clear_marker
    else
        # [FIX I-4] Explicit decline: visible message + non-zero status.
        print_warning "$(t common.cancelled)"
        return 1
    fi
}