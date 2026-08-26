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