#!/usr/bin/env bash
# =================================================================
# DPX Command: config - view & manage DPX configuration
#
#   dpx config            interactive wizard (same as first-run)
#   dpx config --show     active values + file path
#   dpx config KEY=VALUE flags for non-interactive updates:
#     --projects-root PATH | --provider ngrok|cloudflare |
#     --db-user USER      | --db-password PASS  | --lang auto|en|ru
#     (-y skips the confirmation summary)
# =================================================================

source "${DPX_ROOT}/lib/core.sh"

show_config_help() {
    cat << EOF
 ${COLOR_BOLD}config${COLOR_RESET} - Manage DPX configuration

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} config [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
     Interactive wizard writes ~/.config/dpx/config (global DPX_* paths) and
     ~/.config/dpx/dpx.conf (legacy/application keys); managed keys are
     upserted and manual lines preserved. The same wizard starts
    automatically on first run when that file does not exist.

 ${COLOR_BOLD}Options:${COLOR_RESET}
     --show                 Print active values and config file path
     --projects-root PATH   Default directory for DDEV projects
     --db-local-dir PATH    Central directory for local database dumps
     --db-prod-dir PATH     Central directory for production database dumps
     --backup-dir PATH      Central directory for full project backups
    --provider NAME        Preferred tunnel provider: ngrok | cloudflare
    --db-user USER         MySQL/MariaDB username used by scaffolders
    --db-password PASS     MySQL/MariaDB password
    --lang LANG            CLI output language: auto | en | ru
    -y, --yes              Apply flag-based changes without confirmation
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} config
    ${TOOL_NAME} config --show
    ${TOOL_NAME} config --projects-root ~/work/php --provider cloudflare -y
EOF
}

cmd_config() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_config_help
        return 0
    fi

    # ---------- --show ----------
    if has_arg "show"; then
        print_header "$(t cfg.show.title)"
        print_info "$(t cfg.show.file): $(config_global_file)"
        print_info "Compatibility config: $(config_user_file)"
        echo ""
        list_config
        return 0
    fi

    # ---------- non-interactive flag updates ----------
    local -a updates=()
    local v

    v="$(get_arg "projects_root" "")"
    if [[ -n "$v" ]]; then
        updates+=("ddev_projects_base_path" "$v")
    fi

    v="$(get_arg "db_local_dir" "")"
    if [[ -n "$v" ]]; then
        updates+=("db_local_path" "$v")
    fi

    v="$(get_arg "db_prod_dir" "")"
    if [[ -n "$v" ]]; then
        updates+=("db_prod_path" "$v")
    fi

    v="$(get_arg "backup_dir" "")"
    if [[ -n "$v" ]]; then
        updates+=("full_backup_path" "$v")
    fi

    v="$(get_arg "provider" "")"
    if [[ -n "$v" ]]; then
        if ! config_provider_is_valid "$v"; then
            print_error "$(t cfg.err.provider)"
            return 1
        fi
        v="$(config_normalize_provider "$v")"
        updates+=("default_tunnel_provider" "$v")
    fi

    v="$(get_arg "db_user" "")"
    [[ -n "$v" ]] && updates+=("db_user" "$v")

    v="$(get_arg "db_password" "")"
    [[ -n "$v" ]] && updates+=("db_password" "$v")

    v="$(get_arg "lang" "")"
    if [[ -n "$v" ]]; then
        case "$v" in
            auto|en|ru) : ;;
            *) print_error "$(t cfg.err.lang)"; return 1 ;;
        esac
        updates+=("cli_lang" "$v")
    fi

    if (( ${#updates[@]} > 0 )); then
        if ! has_arg "yes"; then
            t cfg.apply.header
            local i shown
            for ((i = 0; i < ${#updates[@]}; i += 2)); do
                shown="${updates[i + 1]}"
                if [[ -n "$shown" ]] && _is_secret_config_key "${updates[i]}"; then
                    shown="********"
                fi
                printf '  %s = %s\n' "${updates[i]}" "$shown"
            done
            confirm "$(t cfg.apply.confirm)" || { print_info "Cancelled."; return 0; }
        fi
        local i
        for ((i = 0; i < ${#updates[@]}; i += 2)); do
            config_upsert_kv "${updates[i]}" "${updates[i + 1]}" \
                || { print_error "Failed to write '${updates[i]}' to $(config_user_file)"; return 1; }
            case "${updates[i]}" in
                ddev_projects_base_path) config_upsert_global_kv "DPX_PROJECTS_DIR" "${updates[i + 1]}" \
                    || { print_error "Failed to write DPX_PROJECTS_DIR to $(config_global_file)"; return 1; } ;;
                db_local_path) config_upsert_global_kv "DPX_DB_LOCAL_DIR" "${updates[i + 1]}" \
                    || { print_error "Failed to write DPX_DB_LOCAL_DIR to $(config_global_file)"; return 1; } ;;
                db_prod_path) config_upsert_global_kv "DPX_DB_PROD_DIR" "${updates[i + 1]}" \
                    || { print_error "Failed to write DPX_DB_PROD_DIR to $(config_global_file)"; return 1; } ;;
                full_backup_path) config_upsert_global_kv "DPX_BACKUP_DIR" "${updates[i + 1]}" \
                    || { print_error "Failed to write DPX_BACKUP_DIR to $(config_global_file)"; return 1; } ;;
            esac
        done
        load_config
        dpx_detect_lang
        print_success "$(t cfg.saved): $(config_user_file)"
        return 0
    fi

    # ---------- default: interactive wizard ----------
    config_run_wizard force
}
