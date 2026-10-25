#!/usr/bin/env bash
# =================================================================
# DPX Command: set-php - Dynamic switch PHP + Auto-Cleanup + Backup
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/meta.sh"

# =================================================================
# HELP
# =================================================================

show_set_php_help() {
    cat << EOF
 ${COLOR_BOLD}set-php${COLOR_RESET} - Switch versions PHP project

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} set-php [name_project]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Interactive switch versions PHP for DDEV project.
    After switches offers verify work site
    and save maximum working version.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    -h, --help     Show this help
    -y, --yes      Automatic confirmation

 ${COLOR_BOLD}Workflow:${COLOR_RESET}
    1. Selection project and versions PHP
    2. Automatic database backup
    3. Switch versions PHP + restart container
    4. Check works site user
    5. Saved php_max ifs all works

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} set-php
    ${TOOL_NAME} set-php mysite
EOF
}

# =================================================================
# HELPER FUNCTIONS
# =================================================================

# Get URL project from DDEV
_get_project_url() {
    local project_path="$1"
    local project_name
    project_name=$(basename "$project_path")

    # Probe get URL via ddev describe (ifs project run)
    local url
    url=$(cd "$project_path" 2>/dev/null && ddev describe 2>/dev/null | grep -oE 'https://[a-zA-Z0-9._-]+\.ddev\.site' | head -1)

    # Ifs not received — construct from nameds project + TLD from config
    if [[ -z "$url" ]]; then
        local tld
        tld=$(get_config "project_tld" "ddev.site")
        url="https://${project_name}.${tld}"
    fi

    echo "$url"
}

# Open URL in browser
_open_in_browser() {
    local url="$1"
    if [[ -n "$url" ]]; then
        print_info "Open in browser: $url"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            open "$url" 2>/dev/null </dev/null &
        else
            xdg-open "$url" 2>/dev/null </dev/null &
        fi
    fi
}

# Restore the previous PHP version from inside the project directory.
# Used by the automatic rollback paths; reports a failed rollback instead
# of hiding it behind `|| true`.
_set_php_rollback() {
    local php_version="$1"

    if ! ddev config --php-version="$php_version" >/dev/null 2>&1; then
        print_warning "Rollback: failed to restore PHP ${php_version} in DDEV config." >&2
        return 1
    fi
    if ! ddev restart >/dev/null 2>&1; then
        print_warning "Rollback: DDEV restart failed after restoring PHP ${php_version}." >&2
        return 1
    fi
    return 0
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_set_php() {
    print_header "DDEV PHP Manager"

    parse_args "$@" || return 1

    if has_arg "help"; then
        show_set_php_help
        return 0
    fi

    # --- 1. SELECTION PROJECT ---
    local project_name
    project_name=$(get_positional_arg 1)

    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "Select project for switches PHP")
    fi
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")
    local config_file="${project_path}/.ddev/config.yaml"

    # --- 2. DYNAMIC LOGIC VERSION ---
    local current_php="unknown"
    [[ -f "$config_file" ]] && current_php=$(grep -E "^php_version:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")

    local saved_php_max
    saved_php_max=$(dpx_get_php_max "$project_name")

    local raw_versions=""
    raw_versions="$(ddev debug capabilities 2>/dev/null \
        | grep -m1 "Supported PHP versions" \
        | cut -d: -f2 | tr ',' ' ' | tr -d '[]' || true)"

    # Parse defensively: only x.y tokens become selectable versions.
    local -a versions=()
    local -a raw_tokens=()
    local token
    read -r -a raw_tokens <<< "$raw_versions" || true
    for token in "${raw_tokens[@]}"; do
        [[ "$token" =~ ^[0-9]+\.[0-9]+$ ]] && versions+=("$token")
    done

    if [[ ${#versions[@]} -eq 0 ]]; then
        versions=("5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
    fi

    printf '\nProject: %s%s%s\n' "$COLOR_GREEN" "$project_name" "$COLOR_RESET"
    printf 'Current version: %s%s%s' "$COLOR_CYAN" "$current_php" "$COLOR_RESET"

    if [[ "$saved_php_max" != "-" ]]; then
        printf ' (max. tested: %s%s%s)' "$COLOR_GREEN" "$saved_php_max" "$COLOR_RESET"
    fi
    printf '\n\n'

    local i=1
    for v in "${versions[@]}"; do
        local marker=""
        [[ "$v" == "$current_php" ]] && marker=" ${COLOR_CYAN}(current)${COLOR_RESET}"
        [[ "$v" == "$saved_php_max" ]] && marker="${marker:-(tested)}"
        printf "%2d. %s%b\n" "$i" "$v" "$marker"
        ((i++))
    done
    echo ""

    read -r -p "Select a number or version: " v_choice
    local new_php=""
    if [[ "$v_choice" =~ ^[0-9]+$ ]] && (( v_choice > 0 && v_choice <= ${#versions[@]} )); then
        new_php="${versions[$((v_choice-1))]}"
    else
        new_php="$v_choice"
    fi

    [[ -z "$new_php" ]] && return 1

    # Reject unsupported input BEFORE ddev touches the project config.
    local supported=false v_opt
    for v_opt in "${versions[@]}"; do
        if [[ "$v_opt" == "$new_php" ]]; then
            supported=true
            break
        fi
    done
    if [[ "$supported" != true ]]; then
        print_error "PHP ${new_php} is not in the supported version list for this DDEV installation."
        return 1
    fi

    if [[ "$new_php" == "$current_php" ]]; then
        print_warning "Project already uses PHP $new_php"
        return 0
    fi

    if [[ "$saved_php_max" != "-" ]] && [[ $(echo "$new_php $saved_php_max" | awk '{if ($1 > $2) print 1; else print 0}') -eq 1 ]]; then
        print_warning "Warning: the selected version is above the tested maximum ($saved_php_max)"
        if ! confirm "Continue?"; then
            return 0
        fi
    fi

    # --- 3. EXECUT ---
    local backup_dir=""
    local snap_name=""
    local marker_file=""
    marker_file="$(mktemp "${TMPDIR:-/tmp}/dpx_setphp_snap.XXXXXX" 2>/dev/null)" || marker_file=""

    if confirm "Switch ${project_name} on PHP ${new_php}?"; then
        (
            umask 077
            cd "$project_path" 2>/dev/null || exit 1

            # --- [BACKUP] ---
            backup_dir=$(get_config "db_local_path")
            mkdir -p "$backup_dir" || exit 1
            chmod 700 "$backup_dir" 2>/dev/null || {
                print_error "Failed to secure permissions on backup directory: $backup_dir"
                exit 1
            }

            local ts rand_suffix type_tag snap_path
            ts=$(date +"%y%m%d_%H%M%S")
            rand_suffix="$(printf '%s' "$RANDOM$RANDOM" | tr -d '[:space:]')"
            type_tag="BEFORE_PHP"
            snap_name="${project_name}_${type_tag}_${ts}_${rand_suffix}.sql"
            snap_path="${backup_dir}/${snap_name}"

            # Subshell assignments never reach the parent scope: persist
            # the snapshot pointer so the rollback UI can report it.
            if [[ -n "$marker_file" ]]; then
                printf '%s\n%s\n' "$backup_dir" "$snap_name" > "$marker_file"
            fi

            print_info "Create backup: ${snap_name}"

            if ddev export-db --gzip=false --file="$snap_path" >/dev/null 2>&1; then
                if ! chmod 600 "$snap_path" 2>/dev/null; then
                    print_error "Failed to secure permissions on backup: $snap_path"
                    rm -f "$snap_path" "$marker_file"
                    exit 1
                fi
                print_success "Backup create: $(du -h "$snap_path" | awk '{print $1}')"
            else
                print_warning "Failed to create backup (possible base empty)"
                rm -f "$snap_path" "$marker_file"
            fi

            core_rotate_backups "$project_name" "$backup_dir" "$type_tag"

            # --- [ACTION] ---
            print_info "Install PHP $new_php..."
            ddev config --php-version="$new_php" 2>&1 | grep -v "^Project config"
            local config_rc=${PIPESTATUS[0]}

            if [[ $config_rc -ne 0 ]]; then
                print_error "ddev config failed (rc=$config_rc); rolling back to PHP ${current_php}..."
                _set_php_rollback "$current_php"
                exit 1
            fi

            # --- [RESTART] ---
            print_info "Restart container..."
            ddev restart 2>&1 | tail -5
            local restart_rc=${PIPESTATUS[0]}

            if [[ $restart_rc -ne 0 ]]; then
                print_error "ddev restart failed (rc=$restart_rc); rolling back to PHP ${current_php}..."
                _set_php_rollback "$current_php"
                exit 1
            fi

            # --- [CACHE] ---
            if ddev exec wp core is-installed >/dev/null 2>&1; then
                print_info "Flush cache WordPress..."
                ddev exec wp cache flush >/dev/null 2>&1
            fi

            print_success "PHP $new_php applied"

        ) || {
            rm -f "$marker_file"
            print_error "Error: $project_path"
            return 1
        }
    else
        rm -f "$marker_file"
        return 0
    fi

    # Pull the snapshot pointer written inside the subshell.
    if [[ -n "$marker_file" && -f "$marker_file" ]]; then
        {
            IFS= read -r backup_dir || true
            IFS= read -r snap_name || true
        } < "$marker_file"
        rm -f "$marker_file"
    fi

    # --- 4. CHECK OPERABILITIES ---
    echo ""
    print_header "Check operabilities"

    local works="" save_it="" rollback_choice=""

    local project_url
    project_url=$(_get_project_url "$project_path")

    if [[ -n "$project_url" ]]; then
        printf '\n%sProject:%s %s%s%s\n' "$COLOR_BOLD" "$COLOR_RESET" "$COLOR_GREEN" "$project_name" "$COLOR_RESET"
        printf '%sURL:%s %s%s%s\n\n' "$COLOR_BOLD" "$COLOR_RESET" "$COLOR_CYAN" "$project_url" "$COLOR_RESET"

        if confirm "Open site in browser?"; then
            _open_in_browser "$project_url"
        fi
    else
        print_warning "Failed to determine URL project"
    fi

    echo ""
    print_info "Verify the site works in the browser"
    echo ""
    # [FIX I-4] Unified confirm() wrapper: default-No, EOF-safe (raw
    # read -r inherited piped stdin and could misread empty as consent).
    if confirm "Does the site work correctly?"; then
        works="y"
    else
        works="n"
    fi

    case "$works" in
        y|Y|yes)
            echo ""
            local current_saved
            current_saved=$(dpx_get_php_max "$project_name")

            if [[ "$current_saved" == "-" ]] || [[ "$new_php" != "$current_saved" ]]; then
                if [[ "$current_saved" == "-" ]]; then
                    if confirm "Save PHP ${new_php} as the maximum working version?"; then
                        save_it="y"
                    fi
                else
                    if confirm "Update php_max: ${current_saved} → ${new_php}?"; then
                        save_it="y"
                    fi
                fi

                if [[ "$save_it" =~ ^[yY] ]]; then
                    local project_type
                    project_type=$(grep -E "^type:" "${project_path}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")

                    # One atomic write instead of three sequential rewrites.
                    if dpx_meta_set_many "$project_name" \
                        "type" "$project_type" \
                        "php_max" "$new_php" \
                        "tested" "$(date +%Y-%m-%d)"; then
                        print_success "php_max = $new_php saved"
                        echo ""
                        print_info "Storage: $(dpx_meta_file)"
                    else
                        print_error "Failed to save metadata for $project_name"
                    fi
                fi
            else
                print_success "This version already written as php_max"
            fi
            ;;

        n|N|no)
            echo ""
            print_warning "The site does not work on PHP $new_php"
            echo ""
            echo "Action:"
            echo "  1. Roll back to the previous version ($current_php)"
            echo "  2. Try another version"
            echo "  0. Leave as consumes"
            echo ""
            read -r -p "Selection: " rollback_choice

            case "$rollback_choice" in
                1)
                    print_info "Rollback on PHP $current_php..."
                    local rollback_rc=0
                    (
                        cd "$project_path" 2>/dev/null || exit 1
                        ddev config --php-version="$current_php" >/dev/null 2>&1 || exit 1
                        ddev restart >/dev/null 2>&1 || exit 1
                    ) || rollback_rc=1

                    if [[ $rollback_rc -eq 0 ]]; then
                        print_success "Rollback completed on PHP $current_php"
                    else
                        print_error "Rollback failed; switch PHP ${current_php} manually."
                    fi
                    ;;
                2)
                    print_info "Start dpx set-php again for selection other versions"
                    ;;
                0|*)
                    print_info "PHP version $new_php left unchanged"
                    if [[ -n "$snap_name" && -f "${backup_dir}/${snap_name}" ]]; then
                        print_info "Backup accessible: ${backup_dir}/${snap_name}"
                    fi
                    ;;
            esac
            ;;

        *)
            print_info "Skip saved result"
            ;;
    esac

    echo ""
    print_info "Ready!"
}