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
    ${TOOL_NAME} ddev <command_ddev> [arguments...] --here

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Seamless wrapper over DDEV. 
    - If you are inside a project folder, command execute as normally.
    - Ifs yous finds outside project, DPX show interactive menu selection 
      project, switch to in its folder and execute command for you.
    - --here pins the command to the CURRENT folder: ${TOOL_NAME} never
      consults DPX_PROJECTS_DIR and never shows the project menu. The
      current directory must be a DDEV project (contain .ddev/config.yaml),
      otherwise a clear error is printed instead of the menu.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --here    Run the DDEV command for the project in the current folder;
              the flag is consumed by ${TOOL_NAME} and is not passed to DDEV

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} ddev stop                   # Open menu (ifs outside folders), then stop project
    ${TOOL_NAME} ddev exec wp cache flush    # Execute command WP-CLI for selected project
    ${TOOL_NAME} ddev logs -f                # Show logs (with support any flags DDEV)
    ${TOOL_NAME} ddev describe --here        # Describe the project in the current folder
EOF
}

cmd_ddev() {
    # [v1.9.4] --here: execute against the project in the CURRENT folder.
    # The flag is extracted before dispatch — DDEV itself must never see it.
    local here_flag=false
    local -a ddev_args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            # Value-form accepted for consistency with --key=value parsing;
            # any variant is consumed here so DDEV never sees it.
            --here|--here=*) here_flag=true ;;
            *) ddev_args+=("$arg") ;;
        esac
    done

    # Ifs no command passed or help requested
    if [[ ${#ddev_args[@]} -eq 0 || "${ddev_args[0]:-}" == "--help" || "${ddev_args[0]:-}" == "-h" ]]; then
        show_ddev_help
        return 0
    fi

    # [v1.7.0] On `dpx ddev start`, if the target project is already in
    # `running` state but the local HTTPS probe reports a stale
    # ddev-router TLS cert, force a `ddev restart` to reissue/rebind
    # the certificate. Only applies to the start subcommand; restart
    # and other ddev ops keep their native fast path.
    local is_start_call=false
    [[ "${ddev_args[0]:-}" == "start" ]] && is_start_call=true

    # Scenario 0: --here — current folder ONLY. DPX_PROJECTS_DIR and the
    # interactive menu are ignored; validation happens here so the user
    # gets an explicit error instead of a project picker.
    if [[ "$here_flag" == true ]]; then
        if [[ ! -f ".ddev/config.yaml" ]]; then
            print_error "--here: current directory is not a DDEV project (no .ddev/config.yaml): $PWD"
            print_info "Run from a project folder or drop the --here flag to pick a project from the menu."
            return 1
        fi
        if [[ "$is_start_call" == true ]]; then
            ddev_probe_and_recover_if_running "$(basename "$PWD")" "$PWD"
        fi
        ddev "${ddev_args[@]}"
        return $?
    fi

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
