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
    Interactive wizard writes ~/.config/dpx/dpx.conf (managed keys are
    upserted, manual lines preserved). The same wizard starts
    automatically on first run when that file does not exist.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --show                 Print active values and config file path
    --projects-root PATH   Default directory for DDEV projects
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
        print_info "$(t cfg.show.file): $(config_user_file)"
        echo ""
        list_config
        return 0
    fi

    # ---------- non-interactive flag updates ----------
    local -a updates=()
    local v

    v="$(get_arg "projects_root" "")"
    [[ -n "$v" ]] && updates+=("ddev_projects_base_path" "$v")

    v="$(get_arg "provider" "")"
    if [[ -n "$v" ]]; then
        case "$v" in
            ngrok|cloudflare) : ;;
            cloudflared) v="cloudflare" ;;
            *) print_error "$(t cfg.err.provider)"; return 1 ;;
        esac
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
            echo "$(t cfg.apply.header)"
            local i
            for ((i = 0; i < ${#updates[@]}; i += 2)); do
                printf '  %s = %s\n' "${updates[i]}" "${updates[i + 1]}"
            done
            confirm "$(t cfg.apply.confirm)" || { print_info "Cancelled."; return 0; }
        fi
        local i
        for ((i = 0; i < ${#updates[@]}; i += 2)); do
            config_upsert_kv "${updates[i]}" "${updates[i + 1]}"
        done
        load_config
        dpx_detect_lang
        print_success "$(t cfg.saved): $(config_user_file)"
        return 0
    fi

    # ---------- default: interactive wizard ----------
    config_run_wizard force
}
