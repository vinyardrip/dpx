#!/usr/bin/env bash
# =================================================================
# DPX Command: to-prod - Preparation database to production
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/devilbox.sh"
source "${DPX_ROOT}/lib/projects.sh"

# =================================================================
# HELP
# =================================================================

show_to_prod_help() {
    cat << EOF
 ${COLOR_BOLD}to-prod${COLOR_RESET} - Preparation local database for production

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} to-prod [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Exports local database with replace URL on production.
    Automatically creates a safety backup in the dumps folder.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project DDEV
    --cms-type TYPE        Type CMS (wordpress, joomla, opencart, php)
    --prod-url URL         Full URL production
    --prod-tld TLD         Domain zone production (by default: by)
    -y, --yes              Skip confirmations
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} to-prod
    ${TOOL_NAME} to-prod --project-name mysite --prod-tld com -y
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_to_prod() {
    parse_args "$@" || return 1
    
    # Show help
    if has_arg "help"; then
        show_to_prod_help
        return 0
    fi
    
    print_header "$(t toprod.title)"

    # --- Step 1: Selection project ---
    local project_name
    project_name="$(get_arg "project_name" "")"
    [[ -z "$project_name" ]] && project_name="$(get_positional_arg 1 "")"
    if [[ -z "$project_name" ]]; then
        project_name=$(projects_select_interactive "$(t toprod.select.project)")
    fi
    [[ -z "$project_name" ]] && return 1
    validate_project_name "$project_name" || return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # --- Step 2: Type CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")
    
    if [[ -z "$cms_type" ]]; then
        print_header "$(t toprod.cms.header "$project_name")"
        echo "1. WordPress | 2. Joomla | 3. OpenCart | 4. PHP"
        local choice=""
        if ! read -r -p "Select [1]: " choice; then
            # TTY EOF is an aborted prompt; do not silently mutate the DB.
            if [[ -t 0 ]]; then
                print_error "CMS selection aborted. Use --cms-type wordpress|joomla|opencart|php."
                return 1
            fi
            # Non-TTY without input: preserve the historical WordPress
            # default, but announce it instead of hiding the decision.
            print_info "Non-interactive input: defaulting CMS type to WordPress (use --cms-type to override)."
            choice="1"
        fi
        choice="${choice:-1}"
        case "$choice" in
            1) cms_type="wordpress" ;;
            2) cms_type="joomla" ;;
            3) cms_type="opencart" ;;
            4) cms_type="php" ;;
            *)
                print_error "Invalid CMS selection: $choice"
                return 1
                ;;
        esac
    fi
    print_success "$(t refresh.chosen.type "$(get_cms_name "$cms_type")")"

    # --- Step 3: Setup URL ---
    local prod_tld prod_url protocol_choice
    prod_tld=$(get_arg "prod_tld" "$(get_config 'default_prod_tld')")
    prod_url=$(get_arg "prod_url" "")
    protocol_choice=""

    if [[ -z "$prod_url" ]]; then
        if ! has_arg "prod_tld"; then
            prompt_input "    Domain zone production (.by, .com, etc)" "$prod_tld" prod_tld
        fi

        local raw_domain="${project_name}.${prod_tld}"

        # [FIX] Cleanup from protocols ifs user inserted full URL
        raw_domain="${raw_domain#*//}"     # Removes all until // inclusive
        raw_domain="${raw_domain%%/*}"     # Removes all after first slash
        raw_domain="${raw_domain%/}"       # Removes trailing slash

        protocol_choice=$(prompt_choice "$(t toprod.protocol)" "https" "http")

        case "$protocol_choice" in
            https) prod_url="https://${raw_domain}" ;;
            http)  prod_url="http://${raw_domain}" ;;
        esac
    else
        # --prod-url supplied: remember its scheme BEFORE any stripping,
        # so the final normalization below can restore it.
        case "$prod_url" in
            https://*) protocol_choice="https" ;;
            http://*)  protocol_choice="http" ;;
        esac
    fi

    # [FIX] Normalize prod_url exactly once. When no scheme was detected
    # (bare domain via --prod-url), keep the production-safe default https.
    prod_url="${prod_url#*//}"
    prod_url="${prod_url%%/*}"
    prod_url="${prod_url%/}"
    case "${protocol_choice:-https}" in
        http)  prod_url="http://${prod_url}" ;;
        *)     prod_url="https://${prod_url}" ;;
    esac

    local local_url="https://${project_name}.$(get_config 'project_tld')"

    # --- Step 4: Check status DDEV ---
    if ! ddev_is_project_running "$project_name"; then
        if confirm "Project '$project_name' is not running. Start it now?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "$(t toprod.not.running)"
            return 1
        fi
    fi

    # --- Step 5: Preparation nameds file ---
    local out_file
    out_file="$(get_db_prod_path)/$(db_generate_export_filename "$project_name" "TO_PROD")"

    # --- Confirmation ---
    print_header "Verify parameters"
    echo "Project:          ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Type CMS:         ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "Local URL:   ${COLOR_YELLOW}${local_url}${COLOR_RESET}"
    echo "Production URL:   ${COLOR_GREEN}${prod_url}${COLOR_RESET}"
    echo "File export:   ${COLOR_GREEN}$(basename "$out_file")${COLOR_RESET}"
    print_separator
    
    if ! has_arg "yes"; then
        confirm "$(t toprod.start)" || return 1
    fi

    devilbox_stop

    ensure_directory "$(get_db_prod_path)"

    # =================================================================
    #  [C-3] INTERRUPT SAFETY: trap + snapshot marker
    #
    # db_wp_export_safe performs a local→prod URL replace, an export and
    # a reverse replace back. Between the first and last pass the local
    # DB holds production URLs. db_wp_smart_replace registers its own
    # pre_replace_<ts> marker; the traps below attempt an immediate
    # snapshot restore on Ctrl+C/TERM, and the marker stays for orphan
    # recovery when the in-process restore cannot complete.
    # =================================================================

    to_prod_interrupted() {
        local sig="$1"
        echo "" >&2
        print_warning "Interrupted (${sig}) — restoring pre-mutation database snapshot..." >&2
        local snap_name
        snap_name="$(head -1 "${project_path}/.dpx/current_snapshot" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$snap_name" ]]; then
            if (cd "$project_path" && ddev snapshot restore "$snap_name" 2>&1); then
                print_success "Database restored from snapshot: $snap_name" >&2
                rm -f "${project_path}/.dpx/current_snapshot" 2>/dev/null
            else
                print_error "Snapshot restore failed; marker preserved for orphan recovery." >&2
            fi
        else
            print_error "No snapshot marker found; manual recovery may be required (dpx db restore)." >&2
        fi
        exit 130
    }

    trap 'to_prod_interrupted INT' INT
    trap 'to_prod_interrupted TERM' TERM

    # Isolate the directory switch in a subshell
    (
        cd "$project_path" || exit 1

        if [[ "$cms_type" == "wordpress" ]]; then
            db_wp_export_safe "$out_file" "$local_url" "$prod_url" "$project_path"
        else
            # [FIX] stderr remains visible for diagnostics (only >/dev/null)
            if ddev export-db --file="$out_file" >/dev/null; then
                print_success "Base export: $(basename "$out_file")"
            else
                print_error "Error export bases."
                exit 1
            fi
        fi
    )
    local to_prod_rc=$?
    trap - INT TERM

    # [C-3] db_wp_export_safe clears the marker on its own success paths;
    # on failure it deliberately leaves it for orphan recovery. Non-WP
    # flows never mutate URLs, so any leftover marker is stale — drop it.
    if [[ "$cms_type" != "wordpress" ]]; then
        rm -f "${project_path}/.dpx/current_snapshot" 2>/dev/null
    fi

    if [[ $to_prod_rc -ne 0 ]]; then
        return 1
    fi

    # Rotation backups
    core_rotate_backups "$project_name" "$(get_db_prod_path)" "TO_PROD"

    print_celebration "$(t toprod.exported)"
}
