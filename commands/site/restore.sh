#!/usr/bin/env bash
# =================================================================
# DPX Command: site restore - full project restore from backup
#
# Restores a FULL_<project>_<timestamp>.tar.gz archive produced by
# `dpx backup` / `dpx site backup`:
#   1. Safety DB snapshot (rollback point);
#   2. Unpack code/uploads over the project directory (merge semantics:
#      existing extra files are kept, archived files overwrite);
#   3. Import the embedded database dump into DDEV;
#   4. CMS-aware cache cleanup.
#
# Routed as `dpx site restore`; legacy alias `dpx restore`.
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/database.sh"

show_site_restore_help() {
    cat << EOF
 ${COLOR_BOLD}site restore${COLOR_RESET} - Restore project from a full backup archive

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} site restore [ARCHIVE] [options]
    ${TOOL_NAME} restore [ARCHIVE]        # legacy alias

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Takes a safety DB snapshot, unpacks code/uploads into the project
    directory and imports the embedded database dump into DDEV.
    Without ARCHIVE an interactive picker lists archives from
    full_backup_path.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Target DDEV project (default: parsed from
                           the archive filename)
    -y, --yes              Skip confirmations
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} site restore
    ${TOOL_NAME} site restore ~/backups/FULL_mysite_2026-01-01_120000.tar.gz
    ${TOOL_NAME} restore --project-name mysite -y
EOF
}

# Interactive picker: newest FULL_*.tar.gz from full_backup_path.
# STDOUT: selected path; empty on cancel. UI -> STDERR.
_restore_pick_archive() {
    local backup_dir
    backup_dir="$(get_config 'full_backup_path')"
    ensure_directory "$backup_dir"

    local -a files=()
    # shellcheck disable=SC2012  # mtime sorting is the point; names machine-generated
    mapfile -t files < <(ls -1t "${backup_dir}"/FULL_*.tar.gz 2>/dev/null)

    if (( ${#files[@]} == 0 )); then
        print_error "$(t restore.no.archives) $backup_dir"
        return 1
    fi

    print_info "$(t restore.pick):"
    local i
    for i in "${!files[@]}"; do
        printf '  %d) %s\n' $((i + 1)) "$(basename "${files[i]}")" >&2
    done

    local choice=""
    read -r -p "Select [1]: " choice
    choice="${choice:-1}"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
        print_error "$(t err.unknown.choice "$choice")"
        return 1
    fi
    printf '%s\n' "${files[$((choice - 1))]}"
}

# Derive project name from archive name FULL_<project>_<TS>.tar.gz
_restore_project_from_filename() {
    local base
    base="$(basename "$1")"
    [[ "$base" =~ ^FULL_(.+)_20[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.tar\.gz$ ]] \
        && printf '%s\n' "${BASH_REMATCH[1]}"
}

cmd_site_restore() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_site_restore_help
        return 0
    fi

    print_header "$(t restore.title)"

    # --- Archive resolution ---
    local archive
    archive="$(get_positional_arg 1 "")"
    [[ -z "$archive" ]] && archive="$(get_arg "file" "")"

    if [[ -z "$archive" ]]; then
        archive="$(_restore_pick_archive)" || return 1
    fi
    validate_file "$archive" "Backup archive" || return 1

    print_step "1" "$(t restore.title)"
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        print_error "$(t cfg.err.archive.corrupt) $archive"
        return 1
    fi

    # --- Target project ---
    local project_name
    project_name="$(get_arg "project_name" "")"
    if [[ -z "$project_name" ]]; then
        project_name="$(_restore_project_from_filename "$archive")"
    fi
    if [[ -z "$project_name" ]]; then
        prompt_input "$(t restore.target)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    local projects_base project_path
    projects_base="$(get_config 'ddev_projects_base_path')"
    project_path="${projects_base}/${project_name}"

    if [[ ! -d "$project_path" ]]; then
        print_error "$(t restore.missing.project) dpx new/deploy"
        return 1
    fi
    print_info "$(t restore.target): ${project_name}"

    # --- Safety snapshot BEFORE touching anything ---
    print_step "2" "$(t restore.snapshot)"
    local snap_name
    snap_name=$(db_create_snapshot "$project_path" "pre_restore") || {
        print_error "$(t restore.snapshot) failed."
        return 1
    }

    # --- Confirmation ---
    echo "$(t restore.target):      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "$(t restore.dump.found): $(tar -tzf "$archive" | grep -E '\.sql(\.gz)?$' | head -1)"
    print_warning "$(t restore.overwrite.warn)"
    if ! has_arg "yes"; then
        confirm "$(t q.proceed)" || { print_info "Cancelled."; return 0; }
    fi

    # --- Unpack (merge into project dir; dump lands beside it) ---
    print_step "3" "$(t restore.unpack)"
    if ! tar -xzf "$archive" -C "$projects_base"; then
        print_error "$(t restore.unpack) failed."
        return 1
    fi

    # --- Database import ---
    local dump_file="${projects_base}/${project_name}_db.sql.gz"
    if [[ -f "$dump_file" ]]; then
        print_step "4" "$(t restore.import)"
        db_import "$dump_file" "$project_path" || {
            print_error "$(t restore.import) failed."
            return 1
        }
        rm -f "$dump_file"
    else
        print_warning "$(t restore.dump.found): $(basename "$dump_file") — skipped"
    fi

    # --- CMS cache cleanup ---
    print_step "5" "CMS cache..."
    db_post_import_cms "$project_path"

    print_celebration "$(t restore.done)"
    print_highlight "$(t restore.target): ${project_path}"
    print_highlight "$(t restore.snapshot): $snap_name"

    ddev_launch "$project_name"
    return 0
}

show_restore_help() { show_site_restore_help; }
