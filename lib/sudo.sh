#!/usr/bin/env bash
# =================================================================
# DPX Sudo Module - safe work with privilegeds and files
# Protocol Safe Sudo: backup → edit → check → rollback/cleanup
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_SUDO_LOADED:-}" ]] && return 0
readonly _DPX_SUDO_LOADED=1

# =================================================================
# CONSTANTS
# =================================================================

readonly DPX_SUDO_MAX_ATTEMPTS=3
readonly DPX_SUDO_TIMEOUT=60

# =================================================================
# SAFE SUDO — loop authentications with limited attempts
# =================================================================

dpx_sudo() {
    local attempt=1

    while (( attempt <= DPX_SUDO_MAX_ATTEMPTS )); do
        if (( attempt > 1 )); then
            print_warning "Attempt $attempt from $DPX_SUDO_MAX_ATTEMPTS..."
        fi

        if command -v timeout >/dev/null 2>&1; then
            timeout "$DPX_SUDO_TIMEOUT" sudo "$@" && return 0
        else
            if command -v gtimeout >/dev/null 2>&1; then
                gtimeout "$DPX_SUDO_TIMEOUT" sudo "$@" && return 0
            else
                sudo "$@" && return 0
            fi
        fi

        local rc=$?
        if (( rc == 124 )); then
            print_error "Timeout sudo (${DPX_SUDO_TIMEOUT}with). Try again."
        fi

        ((attempt++))
    done

    print_error "Not remove execute sudo after $DPX_SUDO_MAX_ATTEMPTS attempts."
    return 1
}

# =================================================================
# FILE SNAPSHOT — creat and management backups
# =================================================================

dpx_snapshot() {
    local file="$1"
    local backup_file="${file}.bak"

    if [[ ! -f "$file" ]]; then
        print_error "File not found for backup: $file"
        return 1
    fi

    if cp "$file" "$backup_file" 2>/dev/null; then
        print_info "Backup: $backup_file"
        echo "$backup_file"
        return 0
    else
        print_error "Not remove creat backup: $file"
        return 1
    fi
}

dpx_rollback() {
    local file="$1"
    local backup_file="${file}.bak"

    if [[ ! -f "$backup_file" ]]; then
        print_error "Backup not found: $backup_file"
        return 1
    fi

    if cp "$backup_file" "$file" 2>/dev/null; then
        print_success "Rollback: $file (from $backup_file)"
        rm -f "$backup_file"
        return 0
    else
        if dpx_sudo cp "$backup_file" "$file"; then
            print_success "Rollback (sudo): $file"
            dpx_sudo rm -f "$backup_file" 2>/dev/null
            return 0
        else
            print_error "Not remove restore from backup: $file"
            return 1
        fi
    fi
}

dpx_cleanup_snapshot() {
    local file="$1"
    local backup_file="${file}.bak"

    if [[ -f "$backup_file" ]]; then
        rm -f "$backup_file" 2>/dev/null || dpx_sudo rm -f "$backup_file" 2>/dev/null
        print_info "Backup delet: $backup_file"
    fi
}

# =================================================================
# /ETC/HOSTS — safe edit with check via ping
# =================================================================

dpx_hosts_add() {
    local hostname="$1"
    local ip="${2:-127.0.0.1}"

    validate_non_empty "$hostname" "hostname for /etc/hosts" || return 1

    if grep -qE "^[^#]*\\b${hostname}\\b" /etc/hosts 2>/dev/null; then
        print_info "Record for $hostname already consumes in /etc/hosts."
        return 0
    fi

    print_info "Add $hostname in /etc/hosts..."

    dpx_snapshot /etc/hosts || return 1

    if ! dpx_sudo bash -c "echo '${ip} ${hostname}' >> /etc/hosts"; then
        print_error "Not remove add record in /etc/hosts."
        dpx_rollback /etc/hosts || true
        return 1
    fi

    local ping_cmd="ping -c 1 -W 2"
    if [[ "$DPX_OS_TYPE" == "macos" ]]; then
        ping_cmd="ping -c 1 -t 2"
    fi

    if $ping_cmd "$hostname" >/dev/null 2>&1; then
        print_success "Record $hostname add and available."
        dpx_cleanup_snapshot /etc/hosts
        return 0
    else
        print_warning "Ping $hostname not passed. Verify DNS-resolve..."
        local resolved=false
        if command -v getent >/dev/null 2>&1; then
            getent hosts "$hostname" >/dev/null 2>&1 && resolved=true
        elif [[ "$DPX_OS_TYPE" == "macos" ]]; then
            dscacheutil -q host -a name "$hostname" >/dev/null 2>&1 && resolved=true
        fi

        if [[ "$resolved" == true ]]; then
            print_success "Record $hostname resolve. Ping blocked firewall — ok."
            dpx_cleanup_snapshot /etc/hosts
            return 0
        else
            print_error "Record $hostname not resolve. Rollback /etc/hosts..."
            dpx_rollback /etc/hosts || true
            return 1
        fi
    fi
}

dpx_hosts_remove() {
    local hostname="$1"

    if ! grep -qE "^[^#]*\\b${hostname}\\b" /etc/hosts 2>/dev/null; then
        return 0
    fi

    print_info "Delet $hostname from /etc/hosts..."

    dpx_snapshot /etc/hosts || return 1

    if [[ "$DPX_OS_TYPE" == "macos" ]]; then
        if ! dpx_sudo sed -i '' "/${hostname}/d" /etc/hosts; then
            dpx_rollback /etc/hosts || true
            return 1
        fi
    else
        if ! dpx_sudo sed -i "/${hostname}/d" /etc/hosts; then
            dpx_rollback /etc/hosts || true
            return 1
        fi
    fi

    print_success "Record $hostname delet from /etc/hosts."
    dpx_cleanup_snapshot /etc/hosts
    return 0
}

# =================================================================
# WP-CONFIG.PHP — Snapshot-Rollback Protocol (v1.4.5)
#
# Name backup: .wp-config.php.dpx_bak  (hidden file, With POINT)
# Path: ROW with wp-config.php, in root project
# Rollback: mv -f (atomic replace on that same FS)
#
# ARCHITECTURAL RULE v1.4.5:
#   1. Functions, returning data via echo, NOT shoulds
#      invoke print_* in volume same stream. All print_* → stderr.
#   2. diff -q validation after cp: ifs file changed between
#      reading and copi (RSSSL and etc.) — ABORT.
#   3. Post-Rollback Verification: after mv -f verify,
#      that DPX_SMART_TUNNEL disappear from file.
# =================================================================

# Computes path to backup for wp-config.php.
# Format: /path/to/project/.wp-config.php.dpx_bak
_dpx_wp_config_backup_path() {
    local config_file="$1"
    local config_dir
    config_dir=$(dirname "$config_file")
    local config_base
    config_base=$(basename "$config_file")
    echo "${config_dir}/.${config_base}.dpx_bak"
}

# Checks presence «hung» backup from previous sessions.
# Ifs found — restores original via mv -f.
dpx_wp_config_stale_check() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ -f "$backup_file" ]]; then
        print_warning "Detected backup from previous sessions: $backup_file"
        print_info "Restor wp-config.php from hung backup..."

        if mv -f "$backup_file" "$config_file" 2>/dev/null; then
            print_success "Original wp-config.php restor from hung backup."
        else
            if dpx_sudo mv -f "$backup_file" "$config_file"; then
                print_success "Original wp-config.php restor from hung backup (sudo)."
            else
                print_error "Not remove restore wp-config.php from hung backup!"
                print_error "Manual restor: mv -f '$backup_file' '$config_file'"
                return 1
            fi
        fi
    fi

    return 0
}

# Creates snapshot wp-config.php → .wp-config.php.dpx_bak
# CRITICAL RULE: invoke FIRST operation, UNTIL any modification.
#
# VALIDATION (Zero-Trust v1.4.5):
#   1. cp exit code (permissions, disk)
#   2. [ -f "$backup_file" ] — physicals exist
#   3. [ -s "$backup_file" ] — not empty
#   4. diff -q — byte-for-byte identity (catches RSSSL and etc.)
#
# Returns path to backup via echo (stdout).
# print_* write in stderr — NOT pollute return value.
dpx_wp_config_snapshot() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ ! -f "$config_file" ]]; then
        print_error "wp-config.php not found: $config_file"
        return 1
    fi

    # Ifs backup already exist — this hung artifact.
    # Zero-Trust: NOT restor (content unknown), simple remove.
    if [[ -f "$backup_file" ]]; then
        print_warning "Detected hung snapshot: $backup_file"
        print_info "Zero-Trust: delet before creat new..."
        rm -f "$backup_file" 2>/dev/null || dpx_sudo rm -f "$backup_file" 2>/dev/null || {
            print_error "Not remove remove hung snapshot!"
            return 1
        }
    fi

    # cp with check exit code
    local cp_error
    cp_error=$(cp "$config_file" "$backup_file" 2>&1)
    local cp_rc=$?

    if [[ $cp_rc -ne 0 ]]; then
        print_error "Sb creat snapshot wp-config.php (exit code: $cp_rc)!"
        print_error "Reason: $cp_error"
        print_error "Patch CANCEL — original file not will chang."
        return 1
    fi

    # Check: backup physicals exist on disk
    if [[ ! -f "$backup_file" ]]; then
        print_error "Snapshot not created! File missing: $backup_file"
        print_error "Patch CANCEL — original file not will chang."
        return 1
    fi

    # Check: backup not empty
    if [[ ! -s "$backup_file" ]]; then
        print_error "Snapshot creat, but empty! File: $backup_file"
        rm -f "$backup_file" 2>/dev/null
        print_error "Patch CANCEL — original file not will chang."
        return 1
    fi

    # Check: backup BYTE-FOR-BYTE identical original (diff -q)
    # Catches modifications from plugins (RSSSL and etc.) between reading and cp.
    if ! diff -q "$config_file" "$backup_file" >/dev/null 2>&1; then
        print_error "Snapshot NOT identical original! File chang between cp and check."
        print_error "Possible, plugin (RSSSL and etc.) modified wp-config.php."
        rm -f "$backup_file" 2>/dev/null
        print_error "Patch CANCEL — original file not will chang."
        return 1
    fi

    print_info "Snapshot wp-config.php: $backup_file (diff -q OK)"
    # echo — SINGLE output in stdout. Return value clean.
    echo "$backup_file"
    return 0
}

# Restores wp-config.php from .wp-config.php.dpx_bak via mv -f.
# mv -f on that same FS — atomic operation.
# After success mv backup stops exist (became config).
#
# Post-Rollback Verification (v1.4.5):
#   After mv -f verify, that DPX_SMART_TUNNEL disappear from file.
#   Ifs block on place — rollback not triggered, CRITICAL ERROR.
dpx_wp_config_rollback() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ ! -f "$backup_file" ]]; then
        print_error "Backup wp-config.php not found: $backup_file"
        return 1
    fi

    # mv -f: forced rewrite, even ifs config corrupt
    if mv -f "$backup_file" "$config_file" 2>/dev/null; then
        # Post-Rollback Verification: patch must disappear
        if grep -q "DPX_SMART_TUNNEL" "$config_file" 2>/dev/null; then
            print_error "CRITICAL ERROR: after mv -f block DPX_SMART_TUNNEL all yet in file!"
            print_error "Snapshot could contain blocks from previous sessions."
            print_error "Verify manual: $config_file"
            return 1
        fi
        print_success "wp-config.php restor from snapshot (mv -f). Post-verify OK."
        return 0
    else
        if dpx_sudo mv -f "$backup_file" "$config_file"; then
            # Post-Rollback Verification (sudo path)
            if grep -q "DPX_SMART_TUNNEL" "$config_file" 2>/dev/null; then
                print_error "CRITICAL ERROR: after sudo mv -f block DPX_SMART_TUNNEL all yet in file!"
                print_error "Verify manual: $config_file"
                return 1
            fi
            print_success "wp-config.php restor from snapshot (sudo mv -f). Post-verify OK."
            return 0
        else
            print_error "Not remove restore wp-config.php from snapshot!"
            print_error "Manual restor: mv -f '$backup_file' '$config_file'"
            return 1
        fi
    fi
}

# Syntax check wp-config.php via php -l in DDEV-container.
dpx_wp_config_syntax_check() {
    local project_path="$1"
    local config_file="$2"

    print_info "Syntax check wp-config.php (php -l)..."

    local php_l_result
    php_l_result=$(
        cd "$project_path" 2>/dev/null && \
        ddev exec "php -l /var/www/html/wp-config.php" 2>&1
    )

    if echo "$php_l_result" | grep -q "No syntax errors detected" 2>/dev/null; then
        print_success "php -l: syntax wp-config.php valid."
        return 0
    else
        print_error "php -l: detected syntax error in wp-config.php!"
        print_error "$php_l_result"
        return 1
    fi
}

# Removes .wp-config.php.dpx_bak. Insurance cleanup.
dpx_wp_config_cleanup() {
    local config_file="$1"
    local backup_file
    backup_file=$(_dpx_wp_config_backup_path "$config_file")

    if [[ -f "$backup_file" ]]; then
        rm -f "$backup_file" 2>/dev/null || dpx_sudo rm -f "$backup_file" 2>/dev/null
        print_info "Snapshot delet: $backup_file"
    fi
}

# =================================================================
# EXPORT
# =================================================================

export DPX_SUDO_MAX_ATTEMPTS DPX_SUDO_TIMEOUT
