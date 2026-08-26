#!/usr/bin/env bash
# =================================================================
# DPX Command: update - check and install updat
# =================================================================

source "${DPX_ROOT}/lib/core.sh"

# =================================================================
# HELP
# =================================================================

show_update_help() {
    cat << EOF
 ${COLOR_BOLD}update${COLOR_RESET} - Check and install updat DPX

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} update [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Checks presence updat in repositories https://github.com/vinyardrip/dpx
    and pulls fresh code. Ifs DPX installed from Git-repository,
    performs git pull; otherwise offers updat manual.

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --check         Only verify presence updat (without installs)
    -y, --yes       Automatics confirm action
    -h, --help      Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} update              # Check and install updat
    ${TOOL_NAME} update --check      # Only verify
    ${TOOL_NAME} update -y           # Updat without confirmation
EOF
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_update() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_update_help
        return 0
    fi

    local check_only=false
    has_arg "check" && check_only=true

    print_header "Updat ${TOOL_NAME^^}"

    # Verify, that DPX_ROOT — this Git-repository
    if [[ ! -d "${DPX_ROOT}/.git" ]]; then
        print_warning "DPX not installed from Git-repository."
        print_info "For updat download fresh version:"
        print_info "  git clone https://github.com/vinyardrip/dpx.git"
        print_info "  cd dpx && ./install.sh"
        return 1
    fi

    # Current version
    local current_version="$DPX_VERSION"
    print_info "Current version: v${current_version}"

    # Get information about remote
    local remote_url
    remote_url=$(git -C "$DPX_ROOT" config --get remote.origin.url 2>/dev/null || echo "")

    if [[ -n "$remote_url" ]]; then
        print_info "Repository: $remote_url"
    else
        print_warning "Remote origin not configured."
        return 1
    fi

    # Fetch for checks updat
    print_info "Check updat..."
    if ! git -C "$DPX_ROOT" fetch origin 2>/dev/null; then
        print_error "Not remove get information about updat."
        print_info "Verify connected to internet and access to repository."
        return 1
    fi

    # Compare local and deleted branches
    local current_branch
    current_branch=$(git -C "$DPX_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    local local_hash remote_hash
    local_hash=$(git -C "$DPX_ROOT" rev-parse HEAD 2>/dev/null)
    remote_hash=$(git -C "$DPX_ROOT" rev-parse "origin/${current_branch}" 2>/dev/null)

    if [[ "$local_hash" == "$remote_hash" ]]; then
        print_success "Installed last version (v${current_version})."
        return 0
    fi

    # Consumes updat
    local commits_behind
    commits_behind=$(git -C "$DPX_ROOT" rev-list --count "HEAD..origin/${current_branch}" 2>/dev/null || echo "?")

    print_info "Available updat: ${commits_behind} commits behinds."

    # Show list chang
    print_info "Chang:"
    git -C "$DPX_ROOT" log --oneline "HEAD..origin/${current_branch}" 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    if [[ "$check_only" == true ]]; then
        print_info "For installs execute: ${TOOL_NAME} update"
        return 0
    fi

    # Confirmation
    if ! has_arg "yes"; then
        if ! confirm "Install updat?"; then
            print_info "Updat cancel."
            return 0
        fi
    fi

    # Execute git pull
    print_info "Download updat..."
    if git -C "$DPX_ROOT" pull origin "$current_branch" 2>/dev/null; then
        # Read new version
        local new_version
        if [[ -f "${DPX_ROOT}/.version" ]]; then
            new_version=$(head -1 "${DPX_ROOT}/.version" | tr -d '[:space:]')
        else
            new_version="unknown"
        fi

        print_success "Updat installed: v${current_version} → v${new_version}"

        # Reinstall symlink
        if [[ -f "${DPX_ROOT}/install.sh" ]]; then
            print_info "Updat symlink..."
            bash "${DPX_ROOT}/install.sh" install 2>/dev/null || true
        fi
    else
        print_error "Not remove install updat."
        print_info "Possible, consumes local chang. Verify: git -C ${DPX_ROOT} status"
        return 1
    fi
}
