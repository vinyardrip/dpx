#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: Core Module (core.sh)
# =================================================================

# =================================================================
# CHECK VERSIONS BASH
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Tests require Bash 4.0+" >&2
    exit 1
fi

# =================================================================
# INITIALIZATION TEST ENVIRONMENTS
# =================================================================

# Determin DPX_ROOT (assumes, that test in tests/)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# Color
if command -v tput >/dev/null 2>&1; then
    GREEN=$(tput setaf 2); RED=$(tput setaf 1); YELLOW=$(tput setaf 3); CYAN=$(tput setaf 6); BOLD=$(tput bold); RESET=$(tput sgr0)
else
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
fi

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =================================================================
# FUNCTIONS TEST FRAMEWORK
# =================================================================

test_start() {
    local test_name="$1"
    echo -n "  Testing: ${test_name}... "
    ((TESTS_RUN++))
}

test_pass() {
    echo "${GREEN}PASS${RESET}"
    ((TESTS_PASSED++))
}

test_fail() {
    local reason="${1:-No reason provided}"
    echo "${RED}FAIL${RESET}"
    echo "    ${YELLOW}Reason: ${reason}${RESET}"
    ((TESTS_FAILED++))
}

# =================================================================
# DOWNLOAD MODULE
# =================================================================

echo ""
echo "${BOLD}========================================${RESET}"
echo "${BOLD}     Unit Tests: core.sh${RESET}"
echo "${BOLD}========================================${RESET}"
echo ""

# Load paths.sh (detects DPX_OS_TYPE, DPX_SED_INPLACE_EXT)
source "${DPX_ROOT}/lib/paths.sh"

# Load io.sh (functions output)
source "${DPX_ROOT}/lib/io.sh"

# Load utils.sh (ensure_directory, create_temp_file)
source "${DPX_ROOT}/lib/utils.sh"

# Load args.sh (parse_args, has_arg, get_arg)
source "${DPX_ROOT}/lib/args.sh"

# Load checks.sh (Docker/DDEV health checks)
source "${DPX_ROOT}/lib/checks.sh"

# =================================================================
# TESTS: VARIABLE ENVIRONMENT
# =================================================================

echo "${CYAN}=== Environment Variables ===${RESET}"

# [FIX] Fix check existence variable
# ${VAR:-default} returns default ifs variable empty ORS not exist
# ${VAR+x} returns "x" only ifs variable EXIST (even empty)
test_start "DPX_ROOT is set"
if [[ -n "${DPX_ROOT+x}" ]]; then
    test_pass
else
    test_fail "DPX_ROOT should be set"
fi

test_start "DPX_ROOT is valid directory"
if [[ -d "$DPX_ROOT" ]]; then
    test_pass
else
    test_fail "DPX_ROOT should point to existing directory"
fi

test_start "DPX_OS_TYPE is set"
if [[ -n "${DPX_OS_TYPE+x}" ]]; then
    test_pass
else
    test_fail "DPX_OS_TYPE should be set"
fi

test_start "DPX_OS_TYPE is valid (linux or macos)"
if [[ "$DPX_OS_TYPE" == "linux" || "$DPX_OS_TYPE" == "macos" ]]; then
    test_pass
else
    test_fail "DPX_OS_TYPE should be 'linux' or 'macos', got: ${DPX_OS_TYPE}"
fi

# [FIX] Critical fix: dummy test
# Was: ${DPX_SED_INPLACE_EXT:-+set} - ALWAYS true!
# Became: ${DPX_SED_INPLACE_EXT+x} - checks existence variable
test_start "DPX_SED_INPLACE_EXT is declared"
# ${VAR+x} returns "x" ifs variable declared (even empty)
# For Bash 4.2+ can use [[ -v DPX_SED_INPLACE_EXT ]]
if [[ -n "${DPX_SED_INPLACE_EXT+x}" ]]; then
    test_pass
else
    test_fail "DPX_SED_INPLACE_EXT should be declared"
fi

test_start "DPX_SED_INPLACE_EXT has correct value for OS"
if [[ "$DPX_OS_TYPE" == "macos" && "$DPX_SED_INPLACE_EXT" == ".bak" ]]; then
    test_pass
elif [[ "$DPX_OS_TYPE" == "linux" && "$DPX_SED_INPLACE_EXT" == "" ]]; then
    test_pass
else
    test_fail "DPX_SED_INPLACE_EXT='${DPX_SED_INPLACE_EXT}' for OS=${DPX_OS_TYPE}"
fi

# =================================================================
# TESTS: FUNCTIONS FILE SYSTEMS
# =================================================================

echo ""
echo "${CYAN}=== Filesystem Functions ===${RESET}"

test_start "ensure_directory creates directory"
test_dir="/tmp/test_ensure_dir_$$"
ensure_directory "$test_dir"

if [[ -d "$test_dir" ]]; then
    test_pass
else
    test_fail "Directory not created"
fi
# [FIX] Guaranteed cleanup - extracted from if/else
rm -rf "$test_dir" 2>/dev/null || true

test_start "ensure_directory handles existing directory"
test_dir="/tmp/test_ensure_dir_existing_$$"
mkdir -p "$test_dir"
ensure_directory "$test_dir"

if [[ -d "$test_dir" ]]; then
    test_pass
else
    test_fail "Directory should still exist"
fi
rm -rf "$test_dir" 2>/dev/null || true

test_start "ensure_directory handles nested path"
test_dir="/tmp/test_ensure_nested_$$/sub/dir"
ensure_directory "$test_dir"

if [[ -d "$test_dir" ]]; then
    test_pass
else
    test_fail "Nested directories not created"
fi
rm -rf "/tmp/test_ensure_nested_$$" 2>/dev/null || true

test_start "create_temp_file creates file"
test_file=""
test_file=$(create_temp_file)

if [[ -f "$test_file" ]]; then
    test_pass
else
    test_fail "Temp file not created"
fi
# [FIX] Guaranteed cleanup
rm -f "$test_file" 2>/dev/null || true

test_start "create_temp_file returns writable file"
test_file=""
test_file=$(create_temp_file)

if [[ -w "$test_file" ]]; then
    test_pass
else
    test_fail "Temp file not writable"
fi
rm -f "$test_file" 2>/dev/null || true

# =================================================================
# TESTS: PARSING ARGUMENTS
# =================================================================

echo ""
echo "${CYAN}=== Argument Parsing ===${RESET}"

# [FIX] CRITICALS IMPORTANT: cleanup DPX_ARGS before each test!
# In Bash 4.0-4.2 simple assignment DPX_ARGS=() may not clean array
# Use unset + declare for guarantees

test_start "parse_args handles --help"
unset DPX_ARGS; declare -gA DPX_ARGS  # [FIX] Cleanup environments before test
parse_args --help
if [[ "${DPX_ARGS[help]}" == "1" ]]; then
    test_pass
else
    test_fail "DPX_ARGS[help] should be '1', got: '${DPX_ARGS[help]}'"
fi

test_start "parse_args handles --yes"
unset DPX_ARGS; declare -gA DPX_ARGS  # [FIX] Cleanup environments before test
parse_args --yes
if [[ "${DPX_ARGS[yes]}" == "1" ]]; then
    test_pass
else
    test_fail "DPX_ARGS[yes] should be '1', got: '${DPX_ARGS[yes]}'"
fi

test_start "parse_args handles -y (short form)"
unset DPX_ARGS; declare -gA DPX_ARGS  # [FIX] Cleanup before test
parse_args -y
if [[ "${DPX_ARGS[yes]}" == "1" ]]; then
    test_pass
else
    test_fail "DPX_ARGS[yes] should be '1' for -y"
fi

test_start "parse_args handles --debug"
unset DPX_ARGS; declare -gA DPX_ARGS
DPX_DEBUG=0
parse_args --debug
if [[ "${DPX_ARGS[debug]}" == "1" && "$DPX_DEBUG" == "1" ]]; then
    test_pass
else
    test_fail "--debug did not enable DPX_DEBUG"
fi

test_start "parse_args rejects unsafe --db-name"
unset DPX_ARGS; declare -gA DPX_ARGS
if parse_args --db-name 'bad-name' >/dev/null 2>&1; then
    test_fail "unsafe database name accepted"
else
    test_pass
fi

test_start "debug trace includes timestamp and event"
DPX_DEBUG=1
debug_out="$(dpx_debug_trace command.call command=ddev argc=2 2>&1)"
if [[ "$debug_out" == *"[DPX_DEBUG] ts="* && "$debug_out" == *"event=command.call"* ]]; then
    test_pass
else
    test_fail "structured debug trace missing: $debug_out"
fi
DPX_DEBUG=0

echo ""
echo "${CYAN}=== DDEV Environment Health ===${RESET}"

test_start "Docker health check rejects an unresponsive daemon"
docker() {
    case "$1" in
        info) return 1 ;;
        *) return 0 ;;
    esac
}
if check_docker >/dev/null 2>&1; then
    test_fail "unresponsive Docker daemon accepted"
else
    test_pass
fi
unset -f docker

test_start "DDEV health check rejects empty version output"
ddev() { return 0; }
if check_ddev >/dev/null 2>&1; then
    test_fail "empty DDEV version accepted"
else
    test_pass
fi
unset -f ddev

test_start "clean command does not require Docker or DDEV"
if command_requires_ddev clean; then
    test_fail "clean incorrectly requires DDEV"
else
    test_pass
fi

test_start "parse_args handles --project-name value"
unset DPX_ARGS; declare -gA DPX_ARGS  # [FIX] Cleanup environments before test
parse_args --project-name mysite
if [[ "${DPX_ARGS[project_name]}" == "mysite" ]]; then
    test_pass
else
    test_fail "DPX_ARGS[project_name] should be 'mysite', got: '${DPX_ARGS[project_name]}'"
fi

test_start "parse_args handles multiple arguments"
unset DPX_ARGS; declare -gA DPX_ARGS  # [FIX] Cleanup environments before test
parse_args --project-name mysite --php-version 8.1 --yes
if [[ "${DPX_ARGS[project_name]}" == "mysite" && \
      "${DPX_ARGS[php_version]}" == "8.1" && \
      "${DPX_ARGS[yes]}" == "1" ]]; then
    test_pass
else
    test_fail "Multiple arguments not parsed correctly"
fi

test_start "parse_args handles --key=value format"
unset DPX_ARGS; declare -gA DPX_ARGS  # [FIX] Cleanup environments before test
parse_args --project-name=tralala
if [[ "${DPX_ARGS[project_name]}" == "tralala" ]]; then
    test_pass
else
    test_fail "DPX_ARGS[project_name] should be 'tralala', got: '${DPX_ARGS[project_name]}'"
fi

# =================================================================
# TESTS: has_arg and get_arg
# =================================================================

echo ""
echo "${CYAN}=== has_arg / get_arg ===${RESET}"

test_start "has_arg returns true for set flag"
unset DPX_ARGS; declare -gA DPX_ARGS
parse_args --yes
if has_arg "yes"; then
    test_pass
else
    test_fail "has_arg should return true for 'yes'"
fi

test_start "has_arg returns false for unset flag"
unset DPX_ARGS; declare -gA DPX_ARGS
parse_args --yes
if ! has_arg "help"; then
    test_pass
else
    test_fail "has_arg should return false for 'help'"
fi

# [FIX] CRITICAL TEST: has_arg must work not only with flags!
# Old implementation checked == "1", that broke string value
test_start "has_arg returns true for string value (not just '1')"
unset DPX_ARGS; declare -gA DPX_ARGS
parse_args --php-version 8.1
# DPX_ARGS["php_version"] will "8.1", and not "1"
# Old has_arg returned false! New must back true
if has_arg "php_version"; then
    test_pass
else
    test_fail "has_arg should return true for 'php_version=8.1' (not just '1')"
fi

test_start "has_arg returns true for any non-empty value"
unset DPX_ARGS; declare -gA DPX_ARGS
parse_args --project-name mysite
if has_arg "project_name"; then
    test_pass
else
    test_fail "has_arg should return true for 'project_name=mysite'"
fi

test_start "get_arg returns correct value"
unset DPX_ARGS; declare -gA DPX_ARGS
parse_args --project-name mysite
result=$(get_arg "project_name" "default")
if [[ "$result" == "mysite" ]]; then
    test_pass
else
    test_fail "get_arg should return 'mysite', got: '$result'"
fi

test_start "get_arg returns default for missing key"
unset DPX_ARGS; declare -gA DPX_ARGS
parse_args --yes
result=$(get_arg "project_name" "default_value")
if [[ "$result" == "default_value" ]]; then
    test_pass
else
    test_fail "get_arg should return default, got: '$result'"
fi

# =================================================================
# [Stage 2] DATA SAFETY, TRAPS & STATE RECOVERY
# =================================================================

echo ""
echo "=== Stage 2: session log forensics (P-4) ==="

STAGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dpx_stage2_XXXXXX")"
mkdir -p "$STAGE_TMP/.dpx"
echo "CRASH TRACE from previous session" > "$STAGE_TMP/.dpx/debug.log"

(
    export DPX_SESSION_LOG_DIR="$STAGE_TMP"
    dpx_init_session_log "db snap"
) </dev/null >/dev/null 2>&1

test_start "session log rotation keeps previous log as .old"
if grep -qF "CRASH TRACE from previous session" "$STAGE_TMP/.dpx/debug.log.old" 2>/dev/null; then
    test_pass
else
    test_fail "debug.log.old missing or empty"
fi

test_start "fresh session header written to new debug.log"
if grep -qF "DPX Session Log: db snap" "$STAGE_TMP/.dpx/debug.log" 2>/dev/null; then
    test_pass
else
    test_fail "session header missing"
fi

test_start "old crash trace NOT in the new debug.log"
if grep -qF "CRASH TRACE from previous session" "$STAGE_TMP/.dpx/debug.log" 2>/dev/null; then
    test_fail "truncate semantics regressed"
else
    test_pass
fi

echo ""
echo "=== Stage 2: tilde expansion (Finding 6) ==="

HOME_PROBE="$STAGE_TMP/fakehome"
mkdir -p "$HOME_PROBE"
tilde_probe() { # $1 = raw config value
    HOME="$HOME_PROBE" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'"
        source "$DPX_ROOT/lib/paths.sh" >/dev/null 2>&1
        source "$DPX_ROOT/lib/config.sh" >/dev/null 2>&1
        _expand_config_path "$1"
    ' _ "$1" </dev/null 2>/dev/null
}

test_start "leading-tilde path expands under \$HOME"
# shellcheck disable=SC2088  # quoted tilde is the literal test input
check_val="$(tilde_probe '~/projects')"
if [[ "$check_val" == "$HOME_PROBE/projects" ]]; then
    test_pass
else
    test_fail "got: $check_val"
fi

test_start "bare ~ expands to \$HOME"
check_val="$(tilde_probe '~')"
if [[ "$check_val" == "$HOME_PROBE" ]]; then
    test_pass
else
    test_fail "got: $check_val"
fi

test_start "~user path left literal (no silent mangling)"
check_val="$(tilde_probe '~other/projects')"
if [[ "$check_val" == "~other/projects" ]]; then
    test_pass
else
    test_fail "got: $check_val"
fi

echo ""
echo "=== Stage 2: wp-config stale backup triage (C-5) ==="

WP_PROJ="$STAGE_TMP/wpproj"
mkdir -p "$WP_PROJ"

PRISTINE_LIVE='<?php require_once ABSPATH . "wp-settings.php";'
PRISTINE_BAK='<?php require_once ABSPATH . "wp-settings.php";'
PATCHED_LIVE="<?php /** DPX_SMART_TUNNEL */ if (isset(\$_SERVER['HTTP_HOST'])) {} require_once ABSPATH . 'wp-settings.php';"

# Triage matrix helper: writes live+stale pair, runs snapshot, reports.
wp_triage_probe() { # $1 = live content, $2 = stale bak content; echoes events
    HOME="$HOME_PROBE" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        cfg="'"$WP_PROJ"'/wp-config.php"
        printf "%s" "$1" > "$cfg"
        bak="$(_dpx_wp_config_backup_path "$cfg")"
        printf "%s" "$2" > "$bak"
        dpx_wp_config_snapshot "$cfg" >/dev/null 2>&1
        echo "rc=$?"
        printf "LIVE:%s\n" "$(cat "$cfg")"
    ' _ "$1" "$2" </dev/null 2>/dev/null
}

test_start "pristine stale backup restored over pristine live config"
out="$(wp_triage_probe "$PRISTINE_LIVE" "$PRISTINE_BAK")"
if grep -qF "rc=0" <<<"$out" && grep -qF "LIVE:$PRISTINE_BAK" <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

test_start "stale pristine backup wins over patched live file"
out="$(wp_triage_probe "$PATCHED_LIVE" "$PRISTINE_BAK")"
if grep -qF "LIVE:$PRISTINE_BAK" <<<"$out" \
   && ! grep -qF "DPX_SMART_TUNNEL" <<<"$out"; then
    test_pass
else
    test_fail "live config not restored: $out"
fi

test_start "tainted stale backup (DPX markers) discarded, live untouched"
out="$(wp_triage_probe "$PRISTINE_LIVE" "$PATCHED_LIVE")"
if grep -qF "rc=0" <<<"$out" && grep -qF "LIVE:$PRISTINE_LIVE" <<<"$out"; then
    test_pass
else
    test_fail "tainted backup leaked into live: $out"
fi

echo ""
echo "=== Stage 2: smart replace marker + auto-restore (C-3) ==="

SR_PROJ="$STAGE_TMP/srproj"
mkdir -p "$SR_PROJ/.dpx"

smart_replace_probe() { # args: pass1 pass2 pass3 count_value count_rc restore_rc
    HOME="$HOME_PROBE" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
        proj="'"$SR_PROJ"'"
        pass1_rc="'"$1"'"
        pass2_rc="'"${2:-0}"'"
        pass3_rc="'"${3:-0}"'"
        count_value="'"${4:-0}"'"
        count_rc="'"${5:-0}"'"
        restore_rc="'"${6:-0}"'"
        exec_counter="$HOME/exec_calls"
        printf "0\n" > "$exec_counter"

        ddev() {
            case "$1" in
                snapshot)
                    if [[ "${2:-}" == "restore" ]]; then
                        return "$restore_rc"
                    fi
                    return 0
                    ;;
                exec)
                    local exec_calls
                    exec_calls="$(cat "$exec_counter" 2>/dev/null || printf "0")"
                    exec_calls=$((exec_calls + 1))
                    printf "%s\n" "$exec_calls" > "$exec_counter"
                    case "$exec_calls" in
                        1) return "$pass1_rc" ;;
                        2) return "$pass2_rc" ;;
                        3) return "$pass3_rc" ;;
                    esac
                    return 0
                    ;;
                *) return 0 ;;
            esac
        }
        db_sql_count_old_url() {
            printf "%s\n" "$count_value"
            return "$count_rc"
        }

        db_wp_smart_replace "https://old.lo" "https://new.example.com" "$proj" </dev/null
        sr_rc=$?
        echo "SR_RC=$sr_rc"
        echo "EXEC_CALLS=$(cat "$exec_counter" 2>/dev/null || printf "0")"
        if [[ -f "$proj/.dpx/current_snapshot" ]]; then
            echo "MARKER=$(tr -d "[:space:]" < "$proj/.dpx/current_snapshot")"
        else
            echo "MARKER=none"
        fi
    ' _ "$1" </dev/null 2>/dev/null
}

test_start "smart replace pass-1 failure restores snapshot, preserves marker"
out="$(smart_replace_probe 1 0 0 0 0 0)"
if grep -qF "SR_RC=1" <<<"$out" \
   && grep -qF "EXEC_CALLS=1" <<<"$out" \
   && grep -qF "MARKER=pre_replace_" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1, one pass, preserved marker, got: $out"
fi

test_start "smart replace pass-2 failure aborts and preserves marker"
out="$(smart_replace_probe 0 1 0 0 0 0)"
if grep -qF "SR_RC=1" <<<"$out" \
   && grep -qF "EXEC_CALLS=2" <<<"$out" \
   && grep -qF "MARKER=pre_replace_" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1 after pass 2, preserved marker, got: $out"
fi

test_start "smart replace pass-3 failure aborts and preserves marker"
out="$(smart_replace_probe 0 0 1 0 0 0)"
if grep -qF "SR_RC=1" <<<"$out" \
   && grep -qF "EXEC_CALLS=3" <<<"$out" \
   && grep -qF "MARKER=pre_replace_" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1 after pass 3, preserved marker, got: $out"
fi

test_start "smart replace final residual URL count is fatal"
out="$(smart_replace_probe 0 0 0 2 0 0)"
if grep -qF "SR_RC=1" <<<"$out" \
   && grep -qF "EXEC_CALLS=3" <<<"$out" \
   && grep -qF "MARKER=pre_replace_" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1 for residual rows, preserved marker, got: $out"
fi

test_start "smart replace residual-count failure is fatal"
out="$(smart_replace_probe 0 0 0 0 1 0)"
if grep -qF "SR_RC=1" <<<"$out" && grep -qF "MARKER=pre_replace_" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1 when count fails, got: $out"
fi

test_start "smart replace success keeps recovery marker registered"
out="$(smart_replace_probe 0 0 0 0 0 0)"
if grep -qF "SR_RC=0" <<<"$out" \
   && grep -qF "EXEC_CALLS=3" <<<"$out" \
   && grep -qF "MARKER=pre_replace_" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=0 with marker present, got: $out"
fi

test_start "smart replace blocks mutation when safety snapshot fails"
out="$(HOME="$HOME_PROBE" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
    proj="'"$SR_PROJ"'"
    rm -f "$proj/.dpx/current_snapshot"
    ddev() {
        case "$1" in
            snapshot) return 1 ;;
            exec)     echo "EXEC_CALLED"; return 0 ;;
            *)        return 0 ;;
        esac
    }
    db_wp_smart_replace "https://old.lo" "https://new.example.com" "$proj" </dev/null >/dev/null 2>&1
    echo "SR_RC=$?"
    if [[ -f "$proj/.dpx/current_snapshot" ]]; then
        echo "MARKER=$(tr -d "[:space:]" < "$proj/.dpx/current_snapshot")"
    else
        echo "MARKER=none"
    fi
' _ </dev/null 2>/dev/null)"
if grep -qF "SR_RC=1" <<<"$out" \
   && grep -qF "MARKER=none" <<<"$out" \
   && ! grep -qF "EXEC_CALLED" <<<"$out"; then
    test_pass
else
    test_fail "snapshot failure must abort before ddev exec, got: $out"
fi

test_start "db_wp_export_safe preserves marker when rollback reverse fails"
out="$(HOME="$HOME_PROBE" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
    proj="'"$SR_PROJ"'"
    rm -f "$proj/.dpx/current_snapshot"
    db_wp_smart_replace() {
        if [[ "$1" == "https://local.test" ]]; then
            printf "pre_replace_original\n" > "$proj/.dpx/current_snapshot"
            return 0
        fi
        return 1
    }
    db_wp_clear_cache() { return 0; }
    ddev() { [[ "$1" == "export-db" ]] && return 1; return 0; }
    db_wp_export_safe "$proj/export.sql" "https://local.test" "https://prod.test" "$proj" >/dev/null 2>&1
    echo "EXPORT_RC=$?"
    if [[ -f "$proj/.dpx/current_snapshot" ]]; then
        echo "MARKER=$(tr -d "[:space:]" < "$proj/.dpx/current_snapshot")"
    else
        echo "MARKER=none"
    fi
' _ </dev/null 2>/dev/null)"
if grep -qF "EXPORT_RC=1" <<<"$out" \
   && grep -qF "MARKER=pre_replace_original" <<<"$out"; then
    test_pass
else
    test_fail "failed rollback must preserve marker, got: $out"
fi

# The real count helper must not turn a failed mysql call into a
# successful zero; the final smart-replace validation depends on it.
cat > "$SR_PROJ/wp-config.php" <<'WPCONF'
<?php
$table_prefix = 'wp_';
WPCONF

count_probe() { # mode: fail | empty | zero
    HOME="$HOME_PROBE" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
        proj="$1"; mode="$2"
        ddev() {
            case "$mode" in
                fail)  return 1 ;;
                empty) return 0 ;;
                zero)  printf "0\n"; return 0 ;;
            esac
            return 1
        }
        count_value="$(db_sql_count_old_url "$proj" "https://old.lo" 2>/dev/null)"
        echo "COUNT_RC=$?"
        echo "COUNT=${count_value:-empty}"
    ' _ "$SR_PROJ" "$1" </dev/null 2>/dev/null
}

test_start "db_sql_count_old_url fails closed when mysql fails"
out="$(count_probe fail)"
if grep -qF "COUNT_RC=1" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1, got: $out"
fi

test_start "db_sql_count_old_url rejects empty mysql output"
out="$(count_probe empty)"
if grep -qF "COUNT_RC=1" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=1 for empty output, got: $out"
fi

test_start "db_sql_count_old_url returns a valid zero count"
out="$(count_probe zero)"
if grep -qF "COUNT_RC=0" <<<"$out" && grep -qF "COUNT=0" <<<"$out"; then
    test_pass
else
    test_fail "expected rc=0 count=0, got: $out"
fi

rm -rf "$STAGE_TMP"

# =================================================================
# [Stage 3] LOGIC, ISOLATION & RETENTION RULES
# =================================================================

echo ""
echo "=== Stage 3: config precedence (P-3) ==="

S3_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dpx_stage3_XXXXXX")"
mkdir -p "$S3_TMP/.config/dpx"
printf 'db_user = USR_WIN\ndefault_tunnel_provider = cloudflare\n' \
    > "$S3_TMP/.config/dpx/dpx.conf"

s3_config_probe() { # echoes resolved values under isolated HOME
    HOME="$S3_TMP" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'"
        # core.sh defines TOOL_NAME before config.sh — required for the
        # user config path (~/.config/dpx/dpx.conf) to resolve.
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        load_config
        echo "db_user=$(get_config db_user)"
        echo "provider=$(get_config default_tunnel_provider)"
        echo "php=$(get_config default_php_version)"
    ' </dev/null 2>/dev/null
}

out="$(s3_config_probe)"
test_start "user config beats repo-local defaults"
if grep -qF "db_user=USR_WIN" <<<"$out" \
   && grep -qF "provider=cloudflare" <<<"$out"; then
    test_pass
else
    test_fail "user values lost: $out"
fi

test_start "repo-local defaults still seed unset keys"
if grep -qF "php=7.4" <<<"$out"; then
    test_pass
else
    test_fail "repo seed missing: $out"
fi

echo ""
echo "=== Stage 3: LOCAL_BACKUP rotation + name-timestamp order (P-7) ==="

ROT_DIR="$S3_TMP/db"
mkdir -p "$ROT_DIR"
# 5 dumps with EMBEDDED timestamps; mtimes deliberately inverted so a
# mtime-based rotation would delete the newest.
for ts in 260901_120000 260902_120000 260903_120000 260904_120000 260905_120000; do
    echo dump > "$ROT_DIR/shop_LOCAL_BACKUP_${ts}.sql"
done
touch -d "2020-01-01" "$ROT_DIR/shop_LOCAL_BACKUP_260905_120000.sql"
touch -d "2030-01-01" "$ROT_DIR/shop_LOCAL_BACKUP_260901_120000.sql"
# Foreign project file must survive untouched.
echo dump > "$ROT_DIR/mall_LOCAL_BACKUP_260901_120000.sql"

s3_rotate() { # $1 = keep arg
    HOME="$S3_TMP" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'"
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        core_rotate_backups shop "'"$ROT_DIR"'" LOCAL_BACKUP '"$1"'
    ' </dev/null >/dev/null 2>&1
}

s3_rotate 3

test_start "rotation keeps newest 3 by filename timestamp despite inverted mtimes"
remaining="$(command ls -1 "$ROT_DIR"/shop_LOCAL_BACKUP_*.sql 2>/dev/null | tr '\n' ' ')"
if [[ "$remaining" == *260903* && "$remaining" == *260904* && "$remaining" == *260905* \
   && "$remaining" != *260901* && "$remaining" != *260902* ]]; then
    test_pass
else
    test_fail "wrong survivors: $remaining"
fi

test_start "rotation scoped to project prefix (foreign dumps survive)"
if [[ -f "$ROT_DIR/mall_LOCAL_BACKUP_260901_120000.sql" ]]; then
    test_pass
else
    test_fail "foreign project dump deleted"
fi

test_start "local_backup_keep config honored"
printf 'local_backup_keep = 2\n' >> "$S3_TMP/.config/dpx/dpx.conf"
for ts in 260906_120000 260907_120000; do
    echo dump > "$ROT_DIR/shop_LOCAL_BACKUP_${ts}.sql"
done
s3_rotate default
remaining="$(command ls -1 "$ROT_DIR"/shop_LOCAL_BACKUP_*.sql 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$remaining" == "2" ]]; then
    test_pass
else
    test_fail "expected 2 survivors, got $remaining"
fi

test_start "backup_rotate rejects invalid keep counts without deleting"
BAD_ROT="$S3_TMP/bad_rotate"
mkdir -p "$BAD_ROT"
for ts in 2026-01-01_000001 2026-01-02_000002 2026-01-03_000003; do
    echo old > "$BAD_ROT/FULL_shop_${ts}.tar.gz"
done
bad_out="$(HOME="$S3_TMP" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/backup.sh" >/dev/null 2>&1
    backup_rotate "$1" "FULL_shop_" "abc"
    echo "BAD_RC=$?"
' _ "$BAD_ROT" </dev/null 2>&1)"
bad_count="$(command ls -1 "$BAD_ROT"/FULL_shop_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
if grep -qF "BAD_RC=1" <<<"$bad_out" && [[ "$bad_count" == "3" ]]; then
    test_pass
else
    test_fail "invalid keep must fail without deleting, rc/count: $bad_out / $bad_count"
fi

test_start "backup_rotate sorts by basename timestamp in underscored paths"
UND_ROT="$S3_TMP/full_backup_dir_with_underscores"
mkdir -p "$UND_ROT"
for ts in 2026-01-01_000001 2026-01-03_000003 2026-01-02_000002; do
    echo old > "$UND_ROT/FULL_my_site_${ts}.tar.gz"
done
HOME="$S3_TMP" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/backup.sh" >/dev/null 2>&1
    backup_rotate "$1" "FULL_my_site_" 1
' _ "$UND_ROT" </dev/null >/dev/null 2>&1
if [[ -f "$UND_ROT/FULL_my_site_2026-01-03_000003.tar.gz" ]] \
   && [[ ! -e "$UND_ROT/FULL_my_site_2026-01-01_000001.tar.gz" ]] \
   && [[ ! -e "$UND_ROT/FULL_my_site_2026-01-02_000002.tar.gz" ]]; then
    test_pass
else
    test_fail "newest underscored archive was not retained"
fi

echo ""
echo "=== Stage 3: prefix-safe dump picking (P-8) ==="

PICK_DIR="$S3_TMP/pick"
mkdir -p "$PICK_DIR"
echo a > "$PICK_DIR/shop_SNAP_260905_120000.sql"
echo b > "$PICK_DIR/shop_SNAP_260904_120000.sql"
echo c > "$PICK_DIR/shop2_SNAP_260905_120001.sql"

# Feed the pick via a pipe (deterministic in $() contexts) and select "1".
picked="$(printf '1\n' | HOME="$S3_TMP" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
    db_pick_dump_file "'"$PICK_DIR"'" "shop_"
' 2>/dev/null)"
test_start "picker matches prefix exactly (shop_ != shop2_)"
if [[ "$(basename "$picked")" == "shop_SNAP_260905_120000.sql" ]]; then
    test_pass
else
    test_fail "picked: $picked"
fi

# Non-tty with a NON-matching prefix must refuse (no widened defaulting).
picked_rc=0
HOME="$S3_TMP" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
    db_pick_dump_file "'"$PICK_DIR"'" "nosuchproject_" </dev/null >/dev/null 2>&1
' || picked_rc=$?
test_start "non-tty picker refuses unmatched prefix"
if [[ $picked_rc -ne 0 ]]; then
    test_pass
else
    test_fail "picker accepted unmatched prefix headlessly"
fi

echo ""
echo "=== Stage 3: unique filenames (P-9) ==="

s3_gen_name() {
    HOME="$S3_TMP" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'"
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
        db_generate_export_filename shop SNAP
    ' </dev/null 2>/dev/null
}

test_start "two consecutive export filenames never collide"
name1="$(s3_gen_name)"
name2="$(s3_gen_name)"
if [[ "$name1" != "$name2" && "$name1" == shop_SNAP_* && "$name1" == *.sql ]]; then
    test_pass
else
    test_fail "collision: [$name1] vs [$name2]"
fi

test_start "filename still parses as <proj>_<TYPE>_<date>_<time>_<rand>"
if [[ "$name1" =~ ^shop_SNAP_[0-9]{6}_[0-9]{6}_[0-9]+\.sql$ ]]; then
    test_pass
else
    test_fail "bad format: $name1"
fi

echo ""
echo "=== Stage 3: db_import/db_export CWD isolation (P-10) ==="

ISO_DIR="$S3_TMP/iso"
mkdir -p "$ISO_DIR/proj"
echo "-- dump" > "$ISO_DIR/in.sql"
iso_probe() { # $1 = func args string; echoes PWD-preserved verdict
    HOME="$S3_TMP" bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
        ddev() {
            case "$1" in
                export-db|import-db) return 0 ;;
                *) return 0 ;;
            esac
        }
        ddev_soft_restart() { return 0; }
        cd "'"$ISO_DIR"'" || exit 1
        before="$PWD"
        '"$1"' >/dev/null 2>&1
        [[ "$PWD" == "$before" ]] && echo PRESERVED || echo LEAKED
    ' </dev/null 2>/dev/null
}

test_start "db_import preserves caller CWD"
check_val="$(iso_probe 'db_import "'"$ISO_DIR"'/in.sql" "'"$ISO_DIR"'/proj"')"
if [[ "$check_val" == "PRESERVED" ]]; then test_pass; else test_fail "$check_val"; fi

test_start "db_export preserves caller CWD"
check_val="$(iso_probe 'db_export "'"$ISO_DIR"'/out.sql" "'"$ISO_DIR"'/proj"')"
if [[ "$check_val" == "PRESERVED" ]]; then test_pass; else test_fail "$check_val"; fi

test_start "db_wp_export_safe validates path without touching CWD"
check_val="$(iso_probe 'db_wp_export_safe "'"$ISO_DIR"'/x.sql" "https://a.lo" "https://b.com" "'"$ISO_DIR"'/nonexistent"')"
if [[ "$check_val" == "PRESERVED" ]]; then test_pass; else test_fail "$check_val"; fi

echo ""
echo "=== Stage 3: update check noise suppressed (P-11) ==="

test_start "update_touch_cache silent on read-only cache dir"
ro="$S3_TMP/readonly"
mkdir -p "$ro/.config/dpx"
chmod -w "$ro/.config/dpx"
err="$(HOME="$ro" bash -c '
    export DPX_ROOT="'"$DPX_ROOT"'"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/checks.sh" >/dev/null 2>&1
    update_touch_cache "$ro/.config/dpx/.update_cache" 0
' 2>&1 </dev/null)"
chmod +w "$ro/.config/dpx"
if [[ -z "$err" ]]; then
    test_pass
else
    test_fail "stderr noise: $err"
fi

rm -rf "$S3_TMP"

# =================================================================
# FINAL REPORT
# =================================================================

echo ""
echo "${BOLD}========================================${RESET}"
echo "${BOLD}         Test Results Summary${RESET}"
echo "${BOLD}========================================${RESET}"
echo ""
printf "Total:   %d\n" "$TESTS_RUN"
printf "${GREEN}Passed:  %d${RESET}\n" "$TESTS_PASSED"
printf "${RED}Failed:  %d${RESET}\n" "$TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "${RED}${BOLD}✗ SOME TESTS FAILED${RESET}"
    exit 1
else
    echo "${GREEN}${BOLD}✓ ALL TESTS PASSED${RESET}"
    exit 0
fi
