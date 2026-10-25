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
    # shellcheck disable=SC2012  # timestamp-in-filename sorting is the point
    # [FIX P-7] Filename-timestamp ordering (FULL_<proj>_<YYYY-MM-DD>_<HHMMSS>.tar.gz)
    # instead of mtime — newest first, immune to sync/touch mtime changes.
    # The awk+cut pairing anchors sort fields to the basename, so directory
    # prefixes containing underscores cannot shift the fields.
    mapfile -t files < <(ls -1 "${backup_dir}"/FULL_*.tar.gz 2>/dev/null \
        | awk -F/ '{print $NF "\t" $0}' | sort -t_ -k3,3r -k4,4r | cut -f2-)

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

# Lexically normalize a relative path without touching the filesystem.
# Used to decide whether a link target can escape the restore root.
_restore_normalize_relpath() {
    local path="$1"
    local -a parts=() out=()
    local part last

    IFS='/' read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        case "$part" in
            ""|.) ;;
            ..)
                if (( ${#out[@]} > 0 )); then
                    last=$(( ${#out[@]} - 1 ))
                    unset "out[$last]"
                else
                    out+=("..")
                fi
                ;;
            *) out+=("$part") ;;
        esac
    done

    local IFS='/'
    printf '%s\n' "${out[*]}"
}

# Resolve a SYMLINK target relative to the directory containing its
# archive member (tar symlink semantics).
_restore_symlink_target_path() {
    local member="$1" target="$2" dir=""
    [[ "$member" == */* ]] && dir="${member%/*}"
    _restore_normalize_relpath "${dir:+${dir}/}${target}"
}

# Tar-slip/scope guard. With a project name, every member must belong to
# ${project_name}/... or be the single ${project_name}_db.sql.gz dump;
# every symlink/hardlink target must resolve inside ${project_name}.
# STDOUT: nothing; rc 1 on unsafe members.
_restore_archive_is_safe() {
    local archive="$1"
    local project_name="${2:-}"
    local members links
    local -a member_list=() link_list=() unsafe=()
    local i m line target resolved

    # LC_ALL=C keeps the verbose link markers stable ("->", "link to")
    # across localized GNU/BSD tar installations.
    members="$(LC_ALL=C tar -tzf "$archive" 2>/dev/null)" || return 1
    links="$(LC_ALL=C tar -tvzf "$archive" 2>/dev/null)" || return 1

    if [[ -z "$members" ]]; then
        print_error "$(t cfg.err.archive.corrupt) $archive"
        return 1
    fi

    mapfile -t member_list <<< "$members"
    mapfile -t link_list <<< "$links"
    if (( ${#member_list[@]} != ${#link_list[@]} )); then
        print_error "Archive listing is inconsistent: $archive"
        return 1
    fi

    for i in "${!member_list[@]}"; do
        m="${member_list[$i]}"
        line="${link_list[$i]}"
        [[ -z "$m" ]] && continue

        # Absolute paths, traversal components, and dot components are
        # never valid inside a DPX full-backup archive.
        case "$m" in
            /*|..|../*|*/../*|*/..|./*|*/./*|*/.)
                unsafe+=("$m")
                continue
                ;;
        esac

        if [[ -n "$project_name" ]]; then
            case "$m" in
                "$project_name"|"$project_name/"*) ;;
                "${project_name}_db.sql.gz") ;;
                *)
                    unsafe+=("outside project scope: $m")
                    continue
                    ;;
            esac
        fi

        target=""
        case "$line" in
            c*|b*|p*|s*)
                unsafe+=("device/special member: $m")
                continue
                ;;
            l*" -> "*)      target="${line##* -> }" ;;
            h*" link to "*) target="${line##* link to }" ;;
            *) continue ;;
        esac

        case "$target" in
            ""|/*)
                unsafe+=("link target escapes: $m -> $target")
                continue
                ;;
        esac

        if [[ -n "$project_name" ]]; then
            if [[ "$line" == l* ]]; then
                resolved="$(_restore_symlink_target_path "$m" "$target")"
            else
                # Tar hardlink targets are relative to the archive root.
                resolved="$(_restore_normalize_relpath "$target")"
            fi
            case "$resolved" in
                "$project_name"|"$project_name/"*) ;;
                *) unsafe+=("link target escapes: $m -> $target") ;;
            esac
        else
            case "$target" in
                ..|../*|*/../*|*/..)
                    unsafe+=("link target escapes: $m -> $target")
                    ;;
            esac
        fi
    done

    if (( ${#unsafe[@]} > 0 )); then
        print_error "$(t cfg.err.archive.corrupt) $archive"
        print_error "Unsafe path members detected:"
        for m in "${unsafe[@]:0:10}"; do
            print_error "  $m"
        done
        return 1
    fi
    return 0
}

# Re-validate the extracted staging tree, not just the tar listing. This
# catches symlinks whose target only becomes dangerous after extraction.
_restore_staged_is_safe() {
    local staging="$1" project_name="$2"
    local project_root="${staging}/${project_name}"
    local dump_file="${staging}/${project_name}_db.sql.gz"
    local entry base link target rel dir resolved

    if [[ ! -d "$project_root" || -L "$project_root" ]]; then
        print_error "Archive does not contain a real '${project_name}/' directory."
        return 1
    fi

    if [[ -e "$dump_file" || -L "$dump_file" ]]; then
        if [[ ! -f "$dump_file" || -L "$dump_file" ]]; then
            print_error "Archive database dump is not a regular file: $dump_file"
            return 1
        fi
    fi

    # Defense in depth: the archive validator already enforces the two
    # allowed top-level names, but extraction can create implicit parents.
    while IFS= read -r -d '' entry; do
        [[ "$entry" == "$staging" ]] && continue
        [[ "${entry%/*}" == "$staging" ]] || continue
        base="${entry##*/}"
        case "$base" in
            "$project_name"|"${project_name}_db.sql.gz") ;;
            *)
                print_error "Unexpected staging entry: $base"
                return 1
                ;;
        esac
    done < <(find "$staging" -print0 2>/dev/null)

    while IFS= read -r -d '' link; do
        target="$(readlink "$link" 2>/dev/null)" || {
            print_error "Cannot read symlink target: $link"
            return 1
        }
        case "$target" in
            ""|/*)
                print_error "Symlink target escapes staging root: $link -> $target"
                return 1
                ;;
        esac
        rel="${link#"${staging}/"}"
        dir=""
        [[ "$rel" == */* ]] && dir="${rel%/*}"
        resolved="$(_restore_normalize_relpath "${dir:+${dir}/}${target}")"
        case "$resolved" in
            "$project_name"|"$project_name/"*) ;;
            *)
                print_error "Symlink target escapes project scope: $link -> $target"
                return 1
                ;;
        esac
    done < <(find "$project_root" -type l -print0 2>/dev/null)

    return 0
}

# Ensure every existing ancestor of a merge destination is a real
# directory. This prevents the staging merge from writing through a
# pre-existing symlink in the target project.
_restore_merge_parent_safe() {
    local root="$1" rel="$2"
    local parent="${rel%/*}"
    local cursor="$root" part
    local -a parts=()

    [[ "$parent" == "$rel" ]] && return 0
    IFS='/' read -r -a parts <<< "$parent"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        cursor="${cursor}/${part}"
        if [[ -L "$cursor" ]]; then
            print_error "Refusing to merge through symlinked directory: $cursor"
            return 1
        fi
        if [[ ! -e "$cursor" ]]; then
            mkdir "$cursor" || return 1
        fi
        if [[ ! -d "$cursor" ]]; then
            print_error "Cannot create directory over non-directory: $cursor"
            return 1
        fi
    done
    return 0
}

# Merge the validated staging payload into the live project. Regular files
# and links are moved atomically (staging is created on the project's
# filesystem); directories are merged so existing extra files survive.
_restore_merge_staged_tree() {
    local source="$1" destination="$2"
    local entry rel target

    while IFS= read -r -d '' entry; do
        [[ "$entry" == "$source" ]] && continue
        rel="${entry#"${source}/"}"
        # Runtime recovery state belongs to the live project, not to the
        # archive being restored. Never let an old backup overwrite the
        # pre-restore marker or an active tunnel PID.
        case "$rel" in
            .dpx/current_snapshot|.dpx/tunnel.pid) continue ;;
        esac
        _restore_merge_parent_safe "$destination" "$rel" || return 1
        target="${destination}/${rel}"

        if [[ -d "$entry" && ! -L "$entry" ]]; then
            if [[ -L "$target" || ( -e "$target" && ! -d "$target" ) ]]; then
                rm -rf "$target" || return 1
            fi
            [[ -d "$target" ]] || mkdir "$target" || return 1
        else
            if [[ -d "$target" && ! -L "$target" ]]; then
                print_error "Refusing to replace a directory with a file: $target"
                return 1
            fi
            if [[ -e "$target" || -L "$target" ]]; then
                rm -f "$target" || return 1
            fi
            mv -f "$entry" "$target" || return 1
        fi
    done < <(find "$source" -print0 2>/dev/null)

    return 0
}

cmd_site_restore() {
    cmd_restore "$@"
}

# Staging path must survive cmd_restore's local-scope teardown because
# the EXIT/INT/TERM trap can run after the function frame is gone.
_DPX_RESTORE_STAGING=""
_restore_cleanup_staging() {
    local staging="${_DPX_RESTORE_STAGING:-}"
    [[ -n "$staging" ]] || return 0
    rm -rf "$staging" 2>/dev/null
    _DPX_RESTORE_STAGING=""
    return 0
}

# Router contract: dpx.sh derives the handler as cmd_${command//_/-},
# so the canonical `restore` command dispatches to cmd_restore().
# Keep the real implementation here and expose it under both names
# (dpx restore / dpx site restore).
cmd_restore() {
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

    # [R-01] Scope every archive member to this exact project. This check
    # runs BEFORE the safety snapshot or any extraction work.
    _restore_archive_is_safe "$archive" "$project_name" || return 1

    # --- Safety snapshot BEFORE touching anything ---
    print_step "2" "$(t restore.snapshot)"
    local pre_restore
    pre_restore=$(db_create_snapshot "$project_path" "pre_restore") || {
        print_error "$(t restore.snapshot) failed."
        return 1
    }

    # Register the rollback point immediately: a kill -9 / reboot during
    # unpack/import leaves this marker for boot-time orphan recovery.
    mkdir -p "${project_path}/.dpx" 2>/dev/null
    if ! printf '%s\n' "$pre_restore" > "${project_path}/.dpx/current_snapshot" 2>/dev/null; then
        print_error "Failed to register pre-restore snapshot marker."
        return 1
    fi

    # Globals (not locals): the EXIT trap fires after cmd_restore's local
    # scope has been unwound, so the recovery handler must not rely on
    # dynamically scoped local variables.
    _DPX_RESTORE_PROJECT_PATH="$project_path"
    _DPX_RESTORE_RECOVERING=0
    _restore_clear_marker() {
        _restore_cleanup_staging
        rm -f "${_DPX_RESTORE_PROJECT_PATH}/.dpx/current_snapshot" 2>/dev/null
        trap - INT TERM EXIT
    }
    _restore_interrupted() {
        local sig="$1"
        # The EXIT trap fires after an INT/TERM handler calls exit; do
        # not attempt a second restore in that nested invocation.
        [[ "${_DPX_RESTORE_RECOVERING:-0}" == "1" ]] && return 0
        _DPX_RESTORE_RECOVERING=1

        local project_path="${_DPX_RESTORE_PROJECT_PATH:-}"
        echo "" >&2
        if [[ -z "$project_path" ]]; then
            print_error "Interrupted (${sig}); restore target path is unavailable." >&2
        else
            print_warning "Interrupted (${sig}) — restoring pre-restore database snapshot..." >&2
            local snap_name
            snap_name="$(head -1 "${project_path}/.dpx/current_snapshot" 2>/dev/null | tr -d '[:space:]')"
            if [[ -n "$snap_name" ]] \
               && (cd "$project_path" && ddev snapshot restore "$snap_name" 2>&1); then
                print_success "Database restored from snapshot: $snap_name" >&2
                _restore_clear_marker
            else
                print_error "Snapshot restore failed; marker preserved for orphan recovery." >&2
            fi
        fi

        _restore_cleanup_staging
        if [[ "$sig" != "EXIT" ]]; then
            exit 130
        fi
    }
    trap '_restore_interrupted INT' INT
    trap '_restore_interrupted TERM' TERM
    trap '_restore_interrupted EXIT' EXIT

    # --- Confirmation ---
    echo "$(t restore.target):      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "$(t restore.dump.found): $(tar -tzf "$archive" | grep -E '\.sql(\.gz)?$' | head -1)"
    print_warning "$(t restore.overwrite.warn)"
    if ! has_arg "yes"; then
        confirm "$(t q.proceed)" || {
            _restore_clear_marker
            print_info "Cancelled."
            return 0
        }
    fi

    # --- Unpack into a private staging tree, validate, then merge ---
    # [R-01] Never extract an untrusted archive directly over $projects_base
    # or the live project. Staging on the project's filesystem keeps the
    # subsequent per-file moves atomic.
    print_step "3" "$(t restore.unpack)"
    local staging_dir
    staging_dir="$(mktemp -d "${projects_base}/.dpx_restore_XXXXXX")" || {
        print_error "Failed to create secure restore staging directory."
        return 1
    }
    _DPX_RESTORE_STAGING="$staging_dir"
    if ! chmod 700 "$staging_dir" 2>/dev/null; then
        print_error "Failed to secure restore staging directory: $staging_dir"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$staging_dir"; then
        print_error "$(t restore.unpack) failed."
        return 1
    fi
    if ! _restore_staged_is_safe "$staging_dir" "$project_name"; then
        print_error "Restore aborted: staged archive contents are unsafe."
        return 1
    fi
    if ! _restore_merge_staged_tree "${staging_dir}/${project_name}" "$project_path"; then
        print_error "$(t restore.unpack) failed while merging staged files."
        return 1
    fi

    # --- Database import ---
    local dump_file="${projects_base}/${project_name}_db.sql.gz"
    local staged_dump="${staging_dir}/${project_name}_db.sql.gz"
    if [[ -f "$staged_dump" ]]; then
        # Never follow a pre-existing sibling symlink or replace a
        # directory via mv; both could redirect the dump outside the
        # project namespace.
        if [[ -L "$dump_file" || ( -e "$dump_file" && ! -f "$dump_file" ) ]]; then
            print_error "Refusing unsafe database dump destination: $dump_file"
            return 1
        fi
        if ! rm -f "$dump_file" 2>/dev/null || ! mv -f "$staged_dump" "$dump_file"; then
            print_error "Failed to move the embedded database dump into place."
            return 1
        fi
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

    # Restore completed: drop the rollback marker so orphan recovery does
    # not offer to roll back a successful restore on the next boot.
    _restore_clear_marker

    print_celebration "$(t restore.done)"
    print_highlight "$(t restore.target): ${project_path}"
    print_highlight "$(t restore.snapshot): $pre_restore"

    ddev_launch "$project_name"
    return 0
}

show_restore_help() { show_site_restore_help; }
