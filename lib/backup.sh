#!/usr/bin/env bash
# =================================================================
# DPX Backup Module — full backup project (files + base data)
#
# Architecture:
#   project_full_backup  — orchestrator: dump database + tar.gz files + rotation
#   backup_rotate        — rotation old archives (retention N)
#
# CONTRACT OUTPUT (as at db_backup_local):
#   STDOUT — path to created archive (one line);
#   STDERR — weight UI: steps, warning, errors.
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_BACKUP_LOADED:-}" ]] && return 0
readonly _DPX_BACKUP_LOADED=1

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/ddev.sh"

# =================================================================
# ROTATION BACKUPS
#
# Removes self old archives, leave last $3 piece.
# Consider only files with prefix $2 (isolation projects).
#
# ARGUMENTS:
#   $1 — director with archives
#   $2 — prefix nameds (e.g. "FULL_mysite_")
#   $3 — how many store (N)
# =================================================================

backup_rotate() {
    local backup_dir="$1"
    local prefix="$2"
    local keep="${3:-3}"

    [[ ! -d "$backup_dir" ]] && return 0

    local archives=()
    # -t sorting by mtime (new firsts); mapfile — safe for whitespaces
    mapfile -t archives < <(ls -1t "${backup_dir}/${prefix}"*.tar.gz 2>/dev/null)

    local total=${#archives[@]}
    (( total <= keep )) && return 0

    local removed=0 i
    for (( i = keep; i < total; i++ )); do
        if rm -f -- "${archives[$i]}"; then
            print_info "Rotation: delete old archive $(basename "${archives[$i]}")" >&2
            ((removed++))
        else
            print_warning "Not remove remove ${archives[$i]}" >&2
        fi
    done

    if (( removed > 0 )); then
        print_info "Rotation completion: delete ${removed}, holds ${keep}." >&2
    fi
    return 0
}

# =================================================================
# FULL BACKUP PROJECT (files + base data) [ISSUE 3]
#
# Composition archive:
#   <project_name>/          — files project (with excludes lower);
#   <project_name>_db.sql.gz — dump database via ddev export-db.
#
# EXCLUDE from file oftens:
#   .ddev/.importdb, .ddev-db-snapshots  — temporary data DDEV;
#   .ddev-backups, backups               — folders output backups;
#   node_modules, vendor                 — heavy dependencies;
#   .git                                 — VCS-history.
#
# Name archive: FULL_<project>_<YYYY-MM-DD>_<HHMMSS>.tar.gz
#
# ARGUMENTS:
#   $1 — project_name
#   $2 — project_path
#   $3 — backup_dir   (optional; by default full_backup_path from config)
#   $4 — keep_count   (optional; by default full_backup_keep from config)
#
# STDOUT: path to archive. RETURN: 0/1.
# =================================================================

project_full_backup() {
    local project_name="$1"
    local project_path="$2"
    local backup_dir="${3:-$(get_config "full_backup_path" "$(get_config 'workspace_root')/backups")}"
    local keep_count="${4:-$(get_config "full_backup_keep" "3")}"

    # --- Validation input ---
    validate_directory "$project_path" "Director project" || return 1
    validate_non_empty "$project_name" "Name project" || return 1

    if ! command -v tar >/dev/null 2>&1; then
        print_error "tar not found in PATH — create archive impossible."
        return 1
    fi

    ensure_directory "$backup_dir"

    # --- Preparation named ---
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H%M%S")
    local archive_file="${backup_dir}/FULL_${project_name}_${timestamp}.tar.gz"

    # Temporary director for dump database (removes by exit from functions)
    local tmpdir
    tmpdir=$(create_temp_dir) || { print_error "Not remove create temporary director."; return 1; }
    local db_dump="${tmpdir}/${project_name}_db.sql.gz"
    trap 'rm -rf "$tmpdir" 2>/dev/null' RETURN

    print_header "Full backup project '$project_name'"

    # --- Step 1: Dump bases data ---
    print_step "1/3" "Export bases data"
    if ! db_export "$db_dump" "$project_path" "true"; then
        print_warning "Dump database not create. Archive will contain ONLY files project."
        db_dump=""
    fi

    # --- Step 2: Archiving files project ---
    print_step "2/3" "Archiving files project"

    # Patterns without slash exclude directory with ANY level nestings
    # (GNU tar and BSD tar lead itself identical for so patterns).
    local -a excludes=(
        --exclude='.ddev/.importdb'
        --exclude='.ddev-db-snapshots'
        --exclude='.ddev-backups'
        --exclude='backups'
        --exclude='node_modules'
        --exclude='vendor'
        --exclude='.git'
    )

    # Assembly arguments tar:
    #   -C projects_base  -> internal archive puts folder <project_name>/
    #   -C tmpdir         -> row puts dump database
    local -a tar_args=()
    local exclude
    for exclude in "${excludes[@]}"; do
        tar_args+=("$exclude")
    done
    tar_args+=(-czf "$archive_file")

    local projects_base
    projects_base=$(dirname "$project_path")

    if [[ -n "$db_dump" ]]; then
        (
            cd "$projects_base" || exit 1
            tar "${tar_args[@]}" "$project_name" -C "$tmpdir" "$(basename "$db_dump")"
        ) >/dev/null 2>&1
    else
        (
            cd "$projects_base" || exit 1
            tar "${tar_args[@]}" "$project_name"
        ) >/dev/null 2>&1
    fi

    if [[ $? -ne 0 || ! -f "$archive_file" ]]; then
        print_error "Error create archive: $archive_file"
        rm -f "$archive_file" 2>/dev/null
        return 1
    fi

    # --- Step 3: Verification integrities ---
    print_step "3/3" "Check integrities archive"
    if ! tar -tzf "$archive_file" >/dev/null 2>&1; then
        print_error "Archive corrupt (tar -tzf returned error)."
        rm -f "$archive_file" 2>/dev/null
        return 1
    fi

    # --- Rotation ---
    backup_rotate "$backup_dir" "FULL_${project_name}_" "$keep_count"

    # --- Summary ---
    # [FIX] du instead stat: cross-platformness (GNU/BSD), awk instead cut
    local archive_size
    archive_size=$(du -h "$archive_file" 2>/dev/null | awk '{print $1}')

    print_success "Archive create: $archive_file ($archive_size)"
    echo "$archive_file"
    return 0
}

# =================================================================
# EXPORT FUNCTION
# =================================================================

export -f project_full_backup backup_rotate
