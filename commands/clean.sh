#!/usr/bin/env bash
# =================================================================
# DPX Command: clean - remove stale DPX temporary state
# =================================================================

source "${DPX_ROOT}/lib/core.sh"

show_clean_help() {
    cat << EOF
 Clean stale DPX temporary files.

 Usage:
    dpx clean              Remove .dpx/tmp files older than 7 days
    dpx clean --snapshots  Also remove DDEV DB snapshots (.ddev-db-snapshots)
    dpx clean --all        Remove all .dpx/tmp files and DDEV DB snapshots

 .dpx/config and .dpx/current_snapshot are always preserved.
 DDEV snapshots can be restored with: ddev snapshot restore <name>
EOF
}

clean_project_path() {
    local requested
    requested="$(get_arg project_name '')"
    if [[ -n "$requested" ]]; then
        validate_project_name "$requested" || return 1
        source "${DPX_ROOT}/lib/projects.sh"
        projects_get_path "$requested"
        return 0
    fi

    local path="$PWD"
    while [[ "$path" != "/" ]]; do
        if [[ -d "$path/.dpx" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        path="${path%/*}"
    done
    printf '%s\n' "$PWD"
}

cmd_clean() {
    parse_args "$@" || return 1

    local project_path
    project_path="$(clean_project_path)" || return 1
    validate_directory "$project_path" "project directory" || return 1

    local dpx_dir="${project_path}/.dpx"
    local tmp_dir="${dpx_dir}/tmp"
    local removed=0

    if [[ -d "$tmp_dir" ]]; then
        if has_arg all; then
            while IFS= read -r file; do
                if rm -f "$file" 2>/dev/null; then
                    removed=$((removed + 1))
                    dpx_debug_trace "clean.remove" "$file"
                fi
            done < <(find "$tmp_dir" -type f -print 2>/dev/null)
        else
            while IFS= read -r file; do
                if rm -f "$file" 2>/dev/null; then
                    removed=$((removed + 1))
                    dpx_debug_trace "clean.remove" "$file"
                fi
            done < <(find "$tmp_dir" -type f -mtime +7 -print 2>/dev/null)
        fi
    fi

    if has_arg snapshots || has_arg all; then
        # [FIX D-3] The old code removed .dpx/snapshots — a directory
        # nothing in DPX ever creates. Real DDEV DB snapshots live in
        # <project>/.ddev-db-snapshots (bind-mounted into the db
        # container). Removing them frees disk space; the safety copy
        # recorded in .dpx/current_snapshot (if any) is preserved so
        # orphan recovery keeps working.
        local ddev_snap_dir="${project_path}/.ddev-db-snapshots"
        if [[ -d "$ddev_snap_dir" ]]; then
            if ! rm -rf "$ddev_snap_dir" 2>/dev/null; then
                print_error "Failed to remove DDEV DB snapshots: $ddev_snap_dir"
                return 1
            fi
            print_info "Removed DDEV DB snapshots: $ddev_snap_dir"
        fi
    fi

    print_success "Cleaned ${removed} temporary file(s) in ${dpx_dir}."
    return 0
}
