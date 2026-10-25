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

 Live recovery state is protected. If .dpx/current_snapshot exists or
 .dpx/tunnel.pid points at a running tunnel, snapshot removal is refused
 unless --force is also supplied. With --force, the recovery marker and
 the snapshots are removed together; a dead marker is never left behind:
    dpx clean --snapshots -y --force

 .dpx/config is always preserved.
 DDEV snapshots can be restored with: ddev snapshot restore <name>
EOF
}

# True when .dpx/tunnel.pid identifies a live tunnel process. A stale or
# malformed PID file is treated as active (fail closed); only a valid PID
# that is no longer running is considered stale.
_clean_tunnel_is_active() {
    local project_path="$1"
    local pid_file="${project_path}/.dpx/tunnel.pid"
    local pid=""

    [[ -f "$pid_file" ]] || return 1
    IFS= read -r pid < "$pid_file" || pid=""
    # Trim outer whitespace only. Internal junk stays malformed and is
    # treated as active rather than being compacted into an unrelated PID.
    pid="${pid#"${pid%%[![:space:]]*}"}"
    pid="${pid%"${pid##*[![:space:]]}"}"
    [[ -n "$pid" ]] || return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null
}

# Remove the snapshot directory and the recovery marker as one logical
# transaction. The marker is renamed aside first so a failed rm restores
# it; on success the hidden copy is discarded, never leaving a marker that
# points at a deleted snapshot.
_clean_remove_snapshots() {
    local snap_dir="$1"
    local marker_file="$2"
    local marker_backup=""

    if [[ -e "$marker_file" || -L "$marker_file" ]]; then
        marker_backup="${marker_file}.clean.$$"
        rm -rf "$marker_backup" 2>/dev/null
        if ! mv -f "$marker_file" "$marker_backup" 2>/dev/null; then
            print_error "Failed to detach recovery marker: $marker_file"
            return 1
        fi
    fi

    if ! rm -rf "$snap_dir" 2>/dev/null; then
        if [[ -n "$marker_backup" && ( -e "$marker_backup" || -L "$marker_backup" ) ]]; then
            mv -f "$marker_backup" "$marker_file" 2>/dev/null \
                || print_warning "Failed to restore recovery marker: $marker_file"
        fi
        print_error "Failed to remove DDEV DB snapshots: $snap_dir"
        return 1
    fi

    if [[ -n "$marker_backup" ]]; then
        rm -rf "$marker_backup" 2>/dev/null \
            || print_warning "Snapshot marker backup could not be removed: $marker_backup"
    fi
    return 0
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
    local marker_file="${dpx_dir}/current_snapshot"
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

            # [R-04] Never destroy a live recovery point silently. A
            # marker is enough to require --force even if its named
            # snapshot is already missing (that would already be a dead
            # marker, not a reason to delete more state).
            local protect_reason=""
            if [[ -e "$marker_file" || -L "$marker_file" ]]; then
                protect_reason=".dpx/current_snapshot recovery marker"
            fi
            if _clean_tunnel_is_active "$project_path"; then
                if [[ -n "$protect_reason" ]]; then
                    protect_reason="${protect_reason} and active tunnel"
                else
                    protect_reason="active tunnel (.dpx/tunnel.pid)"
                fi
            fi
            if [[ -n "$protect_reason" ]] && ! has_arg force; then
                print_error "Refusing to remove DDEV DB snapshots: ${protect_reason} is live."
                print_info "Re-run with --force to delete the snapshots and the recovery marker together."
                return 1
            fi
            if [[ -n "$protect_reason" ]]; then
                print_warning "Force enabled: removing protected DB snapshots (${protect_reason})."
            fi

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
    # [R-04] Deletion now also detaches .dpx/current_snapshot first, so
    # an interrupted rm can never leave a marker pointing at a snapshot
    # that was already deleted.
    if [[ "$remove_snapshots" == true && -d "$ddev_snap_dir" ]]; then
        if ! _clean_remove_snapshots "$ddev_snap_dir" "$marker_file"; then
            return 1
        fi
        print_info "Removed DDEV DB snapshots: $ddev_snap_dir"
    fi

    print_success "Cleaned ${removed} temporary file(s) in ${dpx_dir}."
    return 0
}
