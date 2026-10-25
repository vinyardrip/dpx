#!/usr/bin/env bash
# =================================================================
# DPX Command: clean - remove stale DPX temporary state
# =================================================================

source "${DPX_ROOT}/lib/core.sh"

show_clean_help() {
    cat << EOF
 Clean stale DPX temporary files.

 Usage:
    dpx clean                 Remove .dpx/tmp files older than 7 days
    dpx clean --snapshots     Also remove DDEV DB snapshots (.ddev-db-snapshots)
    dpx clean --all           Remove all .dpx/tmp files and DDEV DB snapshots

 Snapshot removal is destructive and requires confirmation. In a
 non-interactive session (no TTY) it requires -y/--yes:
    dpx clean --snapshots -y
    dpx clean --all -y

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
    local ddev_snap_dir="${project_path}/.ddev-db-snapshots"
    local removed=0
    local remove_snapshots=false

    # Snapshot deletion destroys critical restore points. Inventory the
    # directory and obtain explicit consent BEFORE touching any state —
    # including .dpx/tmp — so a non-interactive refusal is a no-op.
    if has_arg snapshots || has_arg all; then
        if [[ -d "$ddev_snap_dir" ]]; then
            local snap_count snap_size
            snap_count="$(ls -1A "$ddev_snap_dir" 2>/dev/null | wc -l | tr -d '[:space:]')"
            snap_size="$(du -sh "$ddev_snap_dir" 2>/dev/null | awk '{print $1}')"
            [[ -n "$snap_size" ]] || snap_size="unknown"
            print_info "DDEV DB snapshots: ${snap_count} item(s), ${snap_size}: ${ddev_snap_dir}"

            if (( snap_count > 0 )); then
                if has_arg yes; then
                    remove_snapshots=true
                elif [[ ! -t 0 ]]; then
                    print_error "Refusing to remove DDEV DB snapshots in non-interactive mode; use -y/--yes."
                    return 1
                elif confirm "Delete all ${snap_count} DDEV DB snapshot item(s) in ${ddev_snap_dir}?" "n"; then
                    remove_snapshots=true
                else
                    print_info "DDEV DB snapshots preserved."
                fi
            else
                # Empty directory: removing it cannot destroy a restore point.
                remove_snapshots=true
            fi
        fi
    fi

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

    # [FIX D-3] The old code removed .dpx/snapshots — a directory
    # nothing in DPX ever creates. Real DDEV DB snapshots live in
    # <project>/.ddev-db-snapshots (bind-mounted into the db container).
    # The safety copy recorded in .dpx/current_snapshot (if any) is
    # preserved so orphan recovery keeps working.
    if [[ "$remove_snapshots" == true && -d "$ddev_snap_dir" ]]; then
        if ! rm -rf "$ddev_snap_dir" 2>/dev/null; then
            print_error "Failed to remove DDEV DB snapshots: $ddev_snap_dir"
            return 1
        fi
        print_info "Removed DDEV DB snapshots: $ddev_snap_dir"
    fi

    print_success "Cleaned ${removed} temporary file(s) in ${dpx_dir}."
    return 0
}
