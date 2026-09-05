#!/usr/bin/env bash
# =================================================================
# DPX Command: ddev - Interactive wrapper for DDEV commands
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/projects.sh"

show_ddev_help() {
    cat << EOF
 ${COLOR_BOLD}ddev${COLOR_RESET} - Interactive wrapper for DDEV commands

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} ddev <command_ddev> [arguments...]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Seamless wrapper over DDEV. 
    - If you are inside a project folder, command execute as normally.
    - Ifs yous finds outside project, DPX show interactive menu selection 
      project, switch to in its folder and execute command for you.

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} ddev stop                   # Open menu (ifs outside folders), then stop project
    ${TOOL_NAME} ddev exec wp cache flush    # Execute command WP-CLI for selected project
    ${TOOL_NAME} ddev logs -f                # Show logs (with support any flags DDEV)
EOF
}

cmd_ddev() {
    # Ifs no command passed or help requested
    if [[ -z "$1" || "$1" == "--help" || "$1" == "-h" ]]; then
        show_ddev_help
        return 0
    fi

    # [v1.7.0] On `dpx ddev start`, if the target project is already in
    # `running` state but the local HTTPS probe reports a stale
    # ddev-router TLS cert, force a `ddev restart` to reissue/rebind
    # the certificate. Only applies to the start subcommand; restart
    # and other ddev ops keep their native fast path.
    local is_start_call=false
    [[ "$1" == "start" ]] && is_start_call=true

    # Scenario 1: Wes ALREADY find internals folders project DDEV
    if [[ -f ".ddev/config.yaml" ]]; then
        if [[ "$is_start_call" == true ]]; then
            ddev_probe_and_recover_if_running "$(basename "$PWD")" "$PWD"
        fi
        # Simple transparent before all arguments in original DDEV
        ddev "$@"
        return $?
    fi

    # Scenario 2: Wes find OUTSIDE folders project (need show menu)
    local project_name
    project_name=$(projects_select_interactive "$(t sel.project.outside "ddev $*")")
    
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    if [[ ! -d "$project_path" ]]; then
        print_error "Project directory not found: $project_path"
        return 1
    fi

    if [[ "$is_start_call" == true ]]; then
        ddev_probe_and_recover_if_running "$project_name" "$project_path"
    fi

    print_info "Transition in project [$project_name] and execut: ddev $*"
    echo ""
    
    # Execute in isolated subshell
    (
        cd "$project_path" || exit 1
        ddev "$@"
    )
}
