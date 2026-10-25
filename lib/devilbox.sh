#!/usr/bin/env bash
# =================================================================
# DPX Devilbox Module - management Devilbox, export database, migration
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_DEVILBOX_LOADED:-}" ]] && return 0
readonly _DPX_DEVILBOX_LOADED=1

# Connect dependencies
source "${DPX_ROOT}/lib/core.sh"

# =================================================================
# DOCKER COMPOSE — cross-platform wrapper (v1 / v2)
# =================================================================

# Detects available command docker-compose
# v2: docker compose (plugin)
# v1: docker-compose (binary)
_dpx_docker_compose_cmd=""  # cache

dpx_docker_compose() {
    if [[ -z "$_dpx_docker_compose_cmd" ]]; then
        if docker compose version >/dev/null 2>&1; then
            _dpx_docker_compose_cmd="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            _dpx_docker_compose_cmd="docker-compose"
        else
            print_error "docker compose not found (neither the v2 plugin nor the v1 binary)."
            return 1
        fi
    fi

    $_dpx_docker_compose_cmd "$@"
}

# =================================================================
# PATHS To DEVILBOX
# =================================================================

get_devilbox_path() {
    echo "${DEFAULT_CONFIG[devilbox_path_root]}"
}

get_devilbox_data_path() {
    echo "${DEFAULT_CONFIG[devilbox_data_base_path]}"
}

# =================================================================
# CHECK STATE DEVILBOX
# =================================================================

# Check whether Devilbox is installed
devilbox_is_installed() {
    local devilbox_path
    devilbox_path=$(get_devilbox_path)
    [[ -d "$devilbox_path" ]]
}

# Check whether Devilbox is running
devilbox_is_running() {
    local devilbox_path
    devilbox_path=$(get_devilbox_path)

    if [[ ! -d "$devilbox_path" ]]; then
        return 1
    fi

    # Verify via docker compose (in subshell for isolations)
    if (cd "$devilbox_path" && dpx_docker_compose ps 2>/dev/null | grep -q "Up"); then
        return 0
    fi

    # Alternative check via docker ps
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "devilbox"; then
        return 0
    fi

    return 1
}

# =================================================================
# MANAGEMENT DEVILBOX
# =================================================================

# Stop Devilbox
devilbox_stop() {
    local devilbox_path
    devilbox_path=$(get_devilbox_path)

    if [[ ! -d "$devilbox_path" ]]; then
        print_info "Devilbox not found, skip stop."
        return 0
    fi

    if ! devilbox_is_running; then
        print_info "Devilbox already stopped."
        return 0
    fi

    print_header "Check state Devilbox"
    print_info "So that avoid conflict ports, Devilbox will stopped..."

    if (cd "$devilbox_path" && dpx_docker_compose down >/dev/null 2>&1); then
        print_success "Devilbox success stopped."
        return 0
    else
        print_warning "Failed to stop Devilbox (it may not be running)."
        return 0  # Not critical error
    fi
}

# Start Devilbox
devilbox_start() {
    local devilbox_path
    devilbox_path=$(get_devilbox_path)

    if [[ ! -d "$devilbox_path" ]]; then
        print_error "Devilbox not found: $devilbox_path"
        return 1
    fi

    if devilbox_is_running; then
        print_info "Devilbox already run."
        return 0
    fi

    print_step "auto" "Start Devilbox"

    if (cd "$devilbox_path" && dpx_docker_compose up -d >/dev/null 2>&1); then
        print_success "Devilbox success run."
        return 0
    else
        print_error "Failed to start Devilbox."
        return 1
    fi
}

# Start specific services Devilbox
# Important: cd in subshell, so that not "leak" in other director
devilbox_start_services() {
    local devilbox_path
    devilbox_path=$(get_devilbox_path)
    local php_version="$1"
    local services="${2:-httpd php mysql}"

    if [[ ! -d "$devilbox_path" ]]; then
        print_error "Devilbox not found: $devilbox_path"
        return 1
    fi

    print_step "auto" "Start Devilbox with PHP $php_version"

    (
        cd "$devilbox_path" || exit 1

        # Switch on need version PHP
        if [[ -f ".env" ]]; then
            mv .env env.bak 2>/dev/null || true
        fi

        if [[ -f ".env-${php_version}" ]]; then
            cp ".env-${php_version}" .env
            print_success "Configuration PHP $php_version activated."
        else
            print_warning "File .env-${php_version} not found"
        fi

        # Start services
        if dpx_docker_compose up -d $services 2>&1; then
            print_success "Services Devilbox runs: $services"
            exit 0
        else
            print_error "Failed to start services Devilbox"
            exit 1
        fi
    ) || return 1
}

# Restore .env Devilbox
# Important: cd in subshell, so that not "leak" in other director
devilbox_restore_env() {
    local devilbox_path
    devilbox_path=$(get_devilbox_path)
    local php_version="$1"

    (
        cd "$devilbox_path" || exit 1

        if [[ -f "env.bak" ]]; then
            # Save current .env reverse
            if [[ -n "$php_version" ]] && [[ -f ".env" ]]; then
                cp .env ".env-${php_version}" 2>/dev/null || true
            fi
            mv env.bak .env
            print_success "Configuration Devilbox restore."
        fi
    )
}

# Restart Devilbox
devilbox_restart() {
    devilbox_stop
    sleep 2
    devilbox_start
}

# =================================================================
# EXPORT database FROM DEVILBOX
# =================================================================

# Export the database from Devilbox
# Important: cd in subshell, and NOT redirect stderr in file dump!
devilbox_export_db() {
    local devilbox_path="$1"
    local db_name="$2"
    local output_file="$3"
    local db_user="${4:-root}"
    local db_pass="${5:-}"

    validate_safe_identifier "$db_name" "database name" || return 1

    print_step "auto" "Export the database from Devilbox"

    # Make sure, that director for output exist
    ensure_directory "$(dirname "$output_file")" || return 1
    chmod 700 "$(dirname "$output_file")" 2>/dev/null || {
        print_error "Failed to secure permissions on export directory: $(dirname "$output_file")"
        return 1
    }

    # Weight code in subshell for isolations cd
    (
        umask 077
        cd "$devilbox_path" || exit 1

        # Export via docker-compose
        # IMPORTANT: stderr NOT must hits in file dump!
        if ! dpx_docker_compose exec -T mysql mysqldump -u "$db_user" ${db_pass:+-p"$db_pass"} "$db_name" > "$output_file"; then
            print_error "Error exporting the database '$db_name'"
            rm -f "$output_file"  # Remove bit file
            exit 1
        fi
        if ! chmod 600 "$output_file" 2>/dev/null; then
            print_error "Failed to secure permissions on database export: $output_file"
            rm -f "$output_file"
            exit 1
        fi

        print_success "Base data '$db_name' export in: $output_file"
        exit 0
    ) || return 1
}

# =================================================================
# WORK With PROJECTS
# =================================================================

# Check existence project in Devilbox data
devilbox_project_exists() {
    local project_folder="$1"
    local data_path
    data_path=$(get_devilbox_data_path)
    local project_path="${data_path}/${project_folder}"

    [[ -d "$project_path" ]]
}

# Get path to project Devilbox
get_devilbox_project_path() {
    local project_folder="$1"
    local data_path
    data_path=$(get_devilbox_data_path)
    echo "${data_path}/${project_folder}"
}

# List projects in Devilbox data
devilbox_list_projects() {
    local data_path
    data_path=$(get_devilbox_data_path)

    if [[ ! -d "$data_path" ]]; then
        return 1
    fi

    for dir in "$data_path"/*/; do
        if [[ -d "$dir" ]]; then
            basename "$dir"
        fi
    done
}

# =================================================================
# CHECK CONFLICTS PORTS
# =================================================================

# Check, busies whethers ports (cross-platform: lsof or ss)
check_port_conflicts() {
    local ports=(80 443 8025 8036)
    local conflicts=()

    for port in "${ports[@]}"; do
        if command -v lsof >/dev/null 2>&1 && lsof -i ":$port" >/dev/null 2>&1; then
            conflicts+=("$port")
        elif command -v ss >/dev/null 2>&1 && ss -tuln | grep -q ":$port "; then
            conflicts+=("$port")
        fi
    done

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        print_warning "Detecteds busy ports: ${conflicts[*]}"
        return 1
    fi

    return 0
}

# Automatic permission conflicts ports (stop Devilbox)
# Important: first verify REAL conflict ports via check_port_conflicts
resolve_port_conflicts() {
    # First verify, run whethers generally Devilbox
    if devilbox_is_running; then
        # Then verify real conflict ports
        if ! check_port_conflicts; then
            print_header "Detected conflict ports"
            print_info "Devilbox uses those same ports, that and DDEV."

            if confirm "Stop Devilbox for released ports?"; then
                devilbox_stop
                sleep 2  # Waiting released ports
                return 0
            else
                print_error "Impossible continue without released ports."
                return 1
            fi
        fi
    fi

    return 0
}

# =================================================================
# STOP DDEV FOR WORKS DEVILBOX
# =================================================================

# Stop DDEV for released resources
ddev_poweroff_for_devilbox() {
    print_header "Preparation environment"
    print_info "Stopping DDEV, so that release resources for Devilbox..."

    if ddev poweroff 2>&1; then
        print_success "DDEV stopped."
        return 0
    else
        print_warning "Failed to stop DDEV."
        return 1
    fi
}
