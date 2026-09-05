#!/usr/bin/env bash
# =================================================================
# DPX Utils Module - general utilities
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_UTILS_LOADED:-}" ]] && return 0
readonly _DPX_UTILS_LOADED=1

# =================================================================
# TIME Ands DATE
# =================================================================

get_current_date() {
    date +%Y-%m-%d
}

get_timestamp() {
    date +%s
}

dpx_debug_timestamp() {
    local stamp
    stamp="$(date '+%Y-%m-%dT%H:%M:%S.%3N' 2>/dev/null)"
    if [[ "$stamp" == *N* ]]; then
        stamp="$(date '+%Y-%m-%dT%H:%M:%S').000"
    fi
    printf '%s\n' "$stamp"
}

dpx_debug_enabled() {
    [[ "${DPX_DEBUG:-0}" == "1" ]]
}

dpx_debug_trace() {
    dpx_debug_enabled || return 0
    local event="$1"
    shift || true
    printf '[DPX_DEBUG] ts=%s event=%s' "$(dpx_debug_timestamp)" "$event" >&2
    if (( $# )); then
        printf ' detail=' >&2
        printf '%q ' "$@" >&2
    fi
    printf '\n' >&2
}

dpx_debug_enable() {
    dpx_debug_enabled || return 0
    dpx_debug_trace "debug.enabled" "pid=$$"
}

# =================================================================
# TEMPORARY FILES
# =================================================================

create_temp_file() {
    mktemp "${TMPDIR:-/tmp}/dpx_XXXXXX"
}

create_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/dpx_XXXXXX"
}

# =================================================================
# FILE SYSTEM
# =================================================================

ensure_directory() {
    local path="$1"
    [[ -d "$path" ]] && return 0
    mkdir -p "$path"
}

ensure_parent_directory() {
    local file="$1"
    ensure_directory "$(dirname "$file")"
}

# =================================================================
# VALIDATION
# =================================================================

validate_directory() {
    local path="$1"
    local description="${2:-director}"

    if [[ -z "$path" ]]; then
        print_error "Path to $description not specified."
        return 1
    fi

    if [[ ! -d "$path" ]]; then
        print_error "$description not found: $path"
        return 1
    fi

    return 0
}

validate_file() {
    local path="$1"
    local description="${2:-file}"

    if [[ -z "$path" ]]; then
        print_error "Path to $description not specified."
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        print_error "$description not found: $path"
        return 1
    fi

    return 0
}

validate_non_empty() {
    local value="$1"
    local description="${2:-value}"

    if [[ -z "$value" ]]; then
        print_error "$description not may was empty."
        return 1
    fi

    return 0
}

validate_project_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Project name cannot be empty."
        return 1
    fi

    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
        print_error "Name project may contain only lowercase letters, digits and hyphens."
        return 1
    fi

    return 0
}

validate_safe_identifier() {
    local value="$1"
    local description="${2:-identifier}"

    if [[ -z "$value" || ! "$value" =~ ^[a-zA-Z0-9_]+$ ]]; then
        print_error "Invalid ${description} '${value}': only a-z, A-Z, 0-9 and underscore are allowed."
        return 1
    fi
    return 0
}

# =================================================================
# INTERACTIVITY
# =================================================================

confirm() {
    local prompt="${1:-Continue?}"
    # Default NO: most callers guard destructive work (DB overwrite, ddev
    # delete). An empty answer, or EOF in a piped/non-tty session, must
    # never be read as consent — callers opt in explicitly with "y".
    local default="${2:-n}"
    local full_prompt

    case "$default" in
        y|Y) full_prompt="$prompt [Y/n]: " ;;
        *)   full_prompt="$prompt [y/N]: " ;;
    esac

    # A failed read (EOF/closed stdin) falls through to the default.
    read -r -p "$full_prompt" response || response=""
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"
    local full_prompt

    if [[ -n "$default" ]]; then
        full_prompt="$prompt [$default]: "
    else
        full_prompt="$prompt: "
    fi

    read -r -p "$full_prompt" value
    value="${value:-$default}"

    if [[ -n "$var_name" ]]; then
        # printf -v safe writes value in variable without parsing
        # (protect from Bash Injection via eval)
        printf -v "$var_name" "%s" "$value"
    else
        echo "$value"
    fi
}

# Simple selection from list (without numberings)
prompt_choice() {
    local prompt="$1"
    shift
    local choices=("$@")
    local default="${choices[0]}"
    local choices_str=$(IFS=/; echo "${choices[*]}")

    read -r -p "$prompt ($choices_str) [$default]: " response

    if [[ -n "$response" ]]; then
        # Verify, consumes whethers entered value in list
        for choice in "${choices[@]}"; do
            [[ "$response" == "$choice" ]] && echo "$choice" && return
        done
        # Ifs not found, return default
        echo "$default"
    else
        echo "$default"
    fi
}

# =================================================================
# SESSION LOG BOOTSTRAP
#
# dpx_init_session_log — starts a new session entry in .dpx/debug.log.
#
# [FIX P-4] FORENSIC PRESERVATION: previous versions truncated the log
# with `cat >` on every session, destroying the exact crash trail the
# user needs on the very next (diagnostic) run. The log is now kept
# across sessions:
#   * the previous log survives as .dpx/debug.log.old (one generation);
#   * the new session header is appended to a fresh debug.log;
#   * every later write in the same session appends with '>>'.
#
# The log lives in the local (cwd) .dpx/ directory, which is the project
# directory for all project-scoped commands. Override with
# DPX_SESSION_LOG_DIR when a different anchor is needed.
#
# Secret-bearing flag values are redacted: the log file is world-readable
# (0644) and must never carry credentials passed on the command line.
#
# ARGUMENTS: full command line of the session (optional)
# =================================================================

# Flags whose VALUE must never reach the log.
_DPX_LOG_SECRET_FLAGS=(
    "--db-password" "--admin-pass" "--dbpass" "--password" "--token"
)

# Rebuild a command line with secret values masked.
dpx_redact_command_line() {
    local -a out=()
    local arg flag redact_next=false

    for arg in "$@"; do
        if [[ "$redact_next" == true ]]; then
            out+=("***")
            redact_next=false
            continue
        fi

        for flag in "${_DPX_LOG_SECRET_FLAGS[@]}"; do
            # --flag=value form: mask in place.
            if [[ "$arg" == "${flag}="* ]]; then
                arg="${flag}=***"
                break
            fi
            # --flag value form: mask the next argument.
            if [[ "$arg" == "$flag" ]]; then
                redact_next=true
                break
            fi
        done

        out+=("$arg")
    done

    printf '%s\n' "${out[*]}"
}

dpx_init_session_log() {
    [[ -n "${_DPX_SESSION_LOG_INITIALIZED:-}" ]] && return 0

    # Informational commands touch no project: creating .dpx/ in whatever
    # directory the user happens to stand in would be litter.
    case "${1:-}" in
        ""|help|-h|--help|version|-v|--version|commands) return 0 ;;
    esac

    local session
    session="$(dpx_redact_command_line "$@")"

    local log_dir="${DPX_SESSION_LOG_DIR:-$PWD}/.dpx"
    local log_file="${log_dir}/debug.log"

    mkdir -p "$log_dir" 2>/dev/null || return 0

    # [FIX P-4] Rotate instead of truncate: keep one generation of the
    # previous session log so crash forensics survive the next command
    # (including the orphan-recovery run itself).
    if [[ -f "$log_file" ]]; then
        rm -f "${log_file}.old" 2>/dev/null
        mv -f "$log_file" "${log_file}.old" 2>/dev/null
    fi

    # Fresh session header; append semantics for the rest of the session.
    cat > "$log_file" <<EOF 2>/dev/null || return 0
================================================================
DPX Session Log: ${session:-dpx}
Started at: $(date '+%Y-%m-%d %H:%M:%S')
================================================================
EOF

    _DPX_SESSION_LOG_INITIALIZED=1
    export _DPX_SESSION_LOG_INITIALIZED
    DPX_SESSION_LOG_FILE="$log_file"
    export DPX_SESSION_LOG_FILE
    return 0
}

# =================================================================
# DEEP LOGGING (v1.4.14)
#
# dpx_exec_and_log — wrapper for execut command with logging.
#
# Performs command in context directors project (cd "$project_path"),
# shows output user (stdout/stderr) and guaranteed writes
# full line start + result in file .dpx/debug.log internals project.
#
# v1.4.22: COMMAND PERFORMS In PROJECT CONTEXT.
# All ddev-command (snapshot, mysql, exec) require start from
# directors project. Wrapper automatics makes cd before
# execut, therefore callers NOT shoulds itself cd.
#
# APPLIED:
#   dpx_exec_and_log "$project_path" ddev exec wp cache flush --allow-root
#   dpx_exec_and_log "$project_path" ddev snapshot --name="$snap" --cleanup
#
# ARGUMENTS:
#   $1       — project_path (for cd + defin paths to .dpx/debug.log)
#   $2, ...  — command and its arguments
#
# RETURN: exit code first process in pipeline (PIPESTATUS[0])
# =================================================================
dpx_exec_and_log() {
    local project_path="$1"
    shift

    local log_dir="${project_path}/.dpx"
    local log_file="${log_dir}/debug.log"
    mkdir -p "$log_dir" 2>/dev/null

    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    dpx_debug_trace "command.call" "cwd=$project_path" "command=${1:-unknown}" "argc=$#"

    # Writ self command in log
    echo -e "\n[$timestamp] EXEC (cd ${project_path}): $*" >> "$log_file"

    # Execute command in context project (subshell for isolations cd)
    # Save code return first process in pipeline
    (cd "$project_path" && "$@") 2>&1 | tee -a "$log_file"
    return ${PIPESTATUS[0]}
}

# =================================================================
# SAFE SED
# =================================================================

safe_sed_inplace() {
    local pattern="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    if [[ "$DPX_OS_TYPE" == "macos" ]]; then
        sed -i "${DPX_SED_INPLACE_EXT}" "$pattern" "$file"
        # Auto-cleanup .bak on macOS (sed -i .bak creates reserve cop)
        rm -f "${file}${DPX_SED_INPLACE_EXT}" 2>/dev/null || true
    else
        sed -i "$pattern" "$file"
    fi
}

safe_sed_stream() {
    local pattern="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    sed "$pattern" "$file"
}

# =================================================================
# EXPORT
# =================================================================
# Note: export -f not requires durings usages source
export -f dpx_exec_and_log
export -f dpx_init_session_log
