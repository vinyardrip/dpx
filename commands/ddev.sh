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
    # Ifs command not passed ors requested help
    if [[ -z "$1" || "$1" == "--help" || "$1" == "-h" ]]; then
        show_ddev_help
        return 0
    fi

    # Scenario 1: Wes ALREADY find internals folders project DDEV
    if [[ -f ".ddev/config.yaml" ]]; then
        # Simple transparent before all arguments in original DDEV
        ddev "$@"
        return $?
    fi

    # Scenario 2: Wes find OUTSIDE folders project (need show menu)
    local project_name
    project_name=$(projects_select_interactive "Yous outside directors project. Select project for 'ddev $*'")
    
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    if [[ ! -d "$project_path" ]]; then
        print_error "Director project not found: $project_path"
        return 1
    fi

    print_info "Transition in project [$project_name] and execut: ddev $*"
    echo ""
    
    # Execute in isolated subshell
    (
        cd "$project_path" || exit 1
        ddev "$@"
    )
}
