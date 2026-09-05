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
    Automatics creates reserve cop in folder dumps.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    Name project DDEV
    --cms-type TYPE        Type CMS (wordpress, joomla, opencart, php)
    --prod-url URL         Full URL production
    --prod-tld TLD         Domain zone production (by default: by)
    -y, --yes              Skipp confirmation
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
    
    print_header "Preparation database for production v1.6.0"

    # --- Step 1: Selection project ---
    local project_name
    project_name=$(projects_select_interactive "Select project for export on cont")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # --- Step 2: Type CMS ---
    local cms_type
    cms_type=$(get_arg "cms_type" "")
    
    if [[ -z "$cms_type" ]]; then
        print_header "Type CMS for [$project_name]"
        echo "1. WordPress | 2. Joomla | 3. OpenCart | 4. PHP"
        local choice
        read -r -p "Select [1]: " choice
        case "${choice:-1}" in
            1) cms_type="wordpress" ;;
            2) cms_type="joomla" ;;
            3) cms_type="opencart" ;;
            *) cms_type="php" ;;
        esac
    fi
    print_success "Chosen type: $(get_cms_name "$cms_type")"

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

        protocol_choice=$(prompt_choice "    Protocol production" "https" "http")

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
        if confirm "Project '$project_name' not run. Start?"; then
            safe_start_ddev_project "$project_name" "$project_path" || return 1
        else
            print_error "Project must was run for export database."
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
        confirm "Start export?" || return 1
    fi

    devilbox_stop

    ensure_directory "$(get_db_prod_path)"

    # Isolate switch directors in subshell
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
    ) || return 1

    # Rotation backups
    core_rotate_backups "$project_name" "$(get_db_prod_path)" "TO_PROD"

    print_celebration "Ready! File in folder dumps."
}
