#!/usr/bin/env bash
# =================================================================
# DPX - DDEV Project eXtend
# Minimum point input (Entry Point / Router)
# =================================================================

# =================================================================
# CHECK ENVIRONMENT (until any code)
# =================================================================

# Reliable check versions Bash (works on macOS and Linux)
# BASH_VERSINFO - built-in array with numerics components versions
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: This script requires Bash 4.0 ors above." >&2
    echo "Current version: ${BASH_VERSION:-unknown}" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "" >&2
        echo "Hint for macOS:" >&2
        echo "  1. Install modern Bash: brew install bash" >&2
        echo "  2. Add in ~/.zshrc ors ~/.bash_profile:" >&2
        echo "     export PATH=\"/opt/homebrew/bin:\$PATH\"" >&2
        echo "     # ors for Intel Mac:" >&2
        echo "     export PATH=\"/usr/local/bin:\$PATH\"" >&2
        echo "  3. Restart terminal ors execute: source ~/.zshrc" >&2
    fi
    exit 1
fi

# Reset cache path command shell
hash -r 2>/dev/null

# =================================================================
# DEFIN DPX_ROOT (cross-platform)
# =================================================================

dpx_get_root() {
    local source="${BASH_SOURCE[0]:-$0}"

    while [[ -h "$source" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || exit 1
        source="$(readlink "$source")" || exit 1
        [[ "$source" != /* ]] && source="${dir}/${source}"
    done

    local root
    root="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || exit 1

    case "$(basename "$root")" in
        lib|command|tests) root="$(dirname "$root")" ;;
    esac

    echo "$root"
}

DPX_ROOT="$(dpx_get_root)" || exit 1
export DPX_ROOT

# =================================================================
# DOWNLOAD CORE
# =================================================================

if [[ -f "${DPX_ROOT}/lib/core.sh" ]]; then
    source "${DPX_ROOT}/lib/core.sh"
else
    echo "ERROR: Core systems not found in ${DPX_ROOT}/lib/core.sh" >&2
    exit 1
fi

# =================================================================
# HELP
# =================================================================

show_help() {
    local bold="$COLOR_BOLD"
    local reset="$COLOR_RESET"
    local green="$COLOR_GREEN"

    printf '\n'
    print_header "${TOOL_NAME^^} - DDEV Project eXtend"
    print_info "Universal CLI for managing DDEV projects"
    echo ""

    printf '%sUSAGE:%s\n' "$bold" "$reset"
    printf '    %s <command> [options]\n\n' "$TOOL_NAME"

    printf '%sCOMMANDS:%s\n' "$bold" "$reset"
    printf '    %s%-12s%s %s\n' "$green" "list" "$reset" "List DDEV projects"
    printf '    %s%-12s%s %s\n' "$green" "edit" "$reset" "Edit project metadata"
    printf '    %s%-12s%s %s\n' "$green" "set-php" "$reset" "Change project PHP version"
    printf '    %s%-12s%s %s\n' "$green" "deploy" "$reset" "Deploy existing project on DDEV"
    printf '    %s%-12s%s %s\n' "$green" "new" "$reset" "Scaffold a project (WordPress/Joomla/OpenCart/ocStore/Laravel/PHP)"
    printf '    %s%-12s%s %s\n' "$green" "new-wp" "$reset" "New WordPress (= new --cms=wordpress, kept for compatibility)"
    printf '    %s%-12s%s %s\n' "$green" "config" "$reset" "Interactive configuration wizard / --show"
    printf '    %s%-12s%s %s\n' "$green" "ddev" "$reset" "Run any DDEV command for a project"
    printf '    %s%-12s%s %s\n' "$green" "refresh" "$reset" "Refresh local DB from production data"
    printf '    %s%-12s%s %s\n' "$green" "migrate" "$reset" "Migrate a project from Devilbox to DDEV"
    printf '    %s%-12s%s %s\n' "$green" "db-snap" "$reset" "Fast snapshot (backup) local database"
    printf '    %s%-12s%s %s\n' "$green" "db-restore" "$reset" "Restore database from local backup"
    printf '    %s%-12s%s %s\n' "$green" "backup" "$reset" "Full backup project (files + database)"
    printf '    %s%-12s%s %s\n' "$green" "to-prod" "$reset" "Preparation local database to unload on cont"
    printf '    %s%-12s%s %s\n' "$green" "tunnel" "$reset" "Forwarding tunnel for show project"
    printf '    %s%-12s%s %s\n' "$green" "update" "$reset" "Check and install update"
    printf '    %s%-12s%s %s\n\n' "$green" "info" "$reset" "Configuration and versions environment"

    printf '%sOPTIONS:%s\n' "$bold" "$reset"
    printf '    -h, --help        Show help\n'
    printf '    -v, --version     Show version\n'
    printf '    -y, --yes         Automatics confirm action\n\n'

    printf '%sEXAMPLES:%s\n' "$bold" "$reset"
    printf '    %s list\n' "$TOOL_NAME"
    printf '    %s edit mysite --php-max 8.2\n' "$TOOL_NAME"
    printf '    %s set-php\n' "$TOOL_NAME"
    printf '    %s db-snap\n' "$TOOL_NAME"
    printf '    %s to-prod --project-name mysite --prod-url https://mysite.by\n' "$TOOL_NAME"
    printf '    %s tunnel --project-name mysite\n' "$TOOL_NAME"
    printf '    %s update\n' "$TOOL_NAME"
    printf '    %s info\n\n' "$TOOL_NAME"

    printf '%sREQUIREMENT:%s\n' "$bold" "$reset"
    printf '    • Bash >= %s\n' "${MIN_BASH_VERSION:-4.0}"
    printf '    • DDEV >= %s\n' "${MIN_DDEV_VERSION:-1.21.0}"
    printf '    • Docker\n'
}

show_version() {
    print_info "${TOOL_NAME} v${DPX_VERSION}"
    print_info "OS: ${DPX_OS_TYPE} | Bash: ${BASH_VERSION%% *}"
}

show_commands() {
    local bold="$COLOR_BOLD"
    local reset="$COLOR_RESET"
    local green="$COLOR_GREEN"

    printf '%sAvailable command:%s\n' "$bold" "$reset"
    printf '  %s%-12s%s %s\n' "$green" "list" "$reset" "List projects"
    printf '  %s%-12s%s %s\n' "$green" "edit" "$reset" "Editing metadata"
    printf '  %s%-12s%s %s\n' "$green" "set-php" "$reset" "Switch versions PHP"
    printf '  %s%-12s%s %s\n' "$green" "deploy" "$reset" "Deploy project"
    printf '  %s%-12s%s %s\n' "$green" "new" "$reset" "Create project (all types)"
    printf '  %s%-12s%s %s\n' "$green" "new-wp" "$reset" "New WordPress (alias new --cms=wordpress)"
    printf '  %s%-12s%s %s\n' "$green" "config" "$reset" "Configuration wizard / --show"
    printf '  %s%-12s%s %s\n' "$green" "ddev" "$reset" "Wrapper command DDEV"
    printf '  %s%-12s%s %s\n' "$green" "refresh" "$reset" "Update database"
    printf '  %s%-12s%s %s\n' "$green" "migrate" "$reset" "Migration with Devilbox"
    printf '  %s%-12s%s %s\n' "$green" "db-snap" "$reset" "Snapshot local database"
    printf '  %s%-12s%s %s\n' "$green" "db-restore" "$reset" "Restore database"
    printf '  %s%-12s%s %s\n' "$green" "backup" "$reset" "Full backup project"
    printf '  %s%-12s%s %s\n' "$green" "to-prod" "$reset" "Export database on cont"
    printf '  %s%-12s%s %s\n' "$green" "tunnel" "$reset" "Forwarding tunnel"
    printf '  %s%-12s%s %s\n' "$green" "update" "$reset" "Update DPX"
    printf '  %s%-12s%s %s\n' "$green" "info" "$reset" "Configuration and versions"
    printf '\nUse: %s <command> --help\n' "$TOOL_NAME"
}

# =================================================================
# ROUTING COMMAND
# =================================================================

run_command() {
    local command="$1"
    shift || true

    # Two-level namespace: dpx db <sub> / dpx site <sub>
    case "$command" in
        db|site)
            local sub="${1:-}"
            [[ $# -gt 0 ]] && shift
            command="$(domain_resolve "$command" "$sub")" || {
                domain_usage "$command"
                exit 1
            }
            ;;
    esac

    case "$command" in
        ""|help|-h|--help)
            show_help
            ;;
        version|-v|--version)
            show_version
            ;;
        commands)
            show_commands
            ;;
        list|edit|set-php|deploy|to-prod|db-snap|db-restore|new-wp|new|refresh|migrate|ddev|tunnel|update|info|backup|config|restore)
            local cmd_file="${DPX_ROOT}/commands/${command}.sh"
            [[ -f "$cmd_file" ]] || cmd_file="$(domain_command_file "$command")"
            if [[ -f "$cmd_file" ]]; then
                # Protect from errors syntax in files command
                if ! bash -n "$cmd_file" 2>/dev/null; then
                    print_error "Error syntax in file command: $cmd_file"
                    print_error "Verify script on presence typos"
                    exit 1
                fi
                # Dynamic download command — architecture DPX (plugin router)
                # shellcheck disable=SC1090
                source "$cmd_file"
                # Replace hyphens on underscore for named function
                local func_name="cmd_${command//-/_}"
                func_name="${func_name//\//_}"
                if declare -f "$func_name" >/dev/null; then
                    $func_name "$@"
                else
                    print_error "Function $func_name not found in $cmd_file"
                    exit 1
                fi
            else
                print_error "File command not found: $cmd_file"
                exit 1
            fi
            ;;
        *)
            print_error "Unknown command: $command"
            show_commands
            exit 1
            ;;
    esac
}

# =================================================================
# POINT INPUT
# =================================================================

main() {
    local command="${1:-help}"
    shift || true

    # Domain groups: resolve to the canonical command BEFORE global
    # --help stripping so subcommand help texts work as expected.
    case "$command" in
        db|site)
            local _dsub="${1:-}"
            local _mapped=""
            _mapped="$(domain_resolve "$command" "$_dsub" 2>/dev/null)" \
                && command="$_mapped" && shift
            ;;
    esac

    # Processing call helps for specific command: dpx <cmd> --help
    # Verify --help ors -h in ANY positions arguments
    local help_requested=false
    local clean_args=()

    for arg in "$@"; do
        if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]]; then
            help_requested=true
        else
            clean_args+=("$arg")
        fi
    done

    if [[ "$help_requested" == true ]]; then
        case "$command" in
            list|edit|set-php|deploy|to-prod|db-snap|db-restore|new-wp|new|refresh|migrate|tunnel|update|info|backup|config|restore)
                local cmd_file="${DPX_ROOT}/commands/${command}.sh"
                [[ -f "$cmd_file" ]] || cmd_file="$(domain_command_file "$command")"
                if [[ -f "$cmd_file" ]]; then
                    # Safe source with check syntax
                    if bash -n "$cmd_file" 2>/dev/null; then
                        # Dynamic download helps — architecture DPX
                        # shellcheck disable=SC1090
                        source "$cmd_file"
                        local help_func="show_${command//-/_}_help"
                        if declare -f "$help_func" >/dev/null; then
                            $help_func
                            exit 0
                        fi
                    fi
                fi
                ;;
        esac
    fi

    # First-run wizard: fires once when the user config file is absent
    # (interactive terminals only; CI/non-tty sessions get a hint).
    if [[ "$command" != "config" ]]; then
        config_first_run_hook
    fi

    # Check dependency only for functional command
    case "$command" in
        ""|help|-h|--help|version|-v|--version|commands)
            :
            ;;
        *)
            check_dependencies || exit 1
            # Recover an interrupted tunnel before dispatching the next
            # command. A failed restore is non-fatal here and keeps the
            # marker for a later retry.
            check_orphaned_snapshot || true
            ;;
    esac

    run_command "$command" "${clean_args[@]}"

    # Non-blocking 24h update notice (respects auto_update_check=false)
    update_check_daily || true
}

main "$@"
