#!/usr/bin/env bash
# =================================================================
# DPX Test Framework - lightweight framework for unit-tests
# =================================================================

# =================================================================
# CHECK VERSIONS BASH
# =================================================================

# Deterministic CLI language for all suites (i18n suite overrides per-case)
export DPX_LANG="${DPX_LANG:-en}"

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Test Framework requires Bash 4.0+" >&2
    exit 1
fi

# =================================================================
# GLOBAL VARIABLE
# =================================================================

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# [FIX] Flag state current test (protect from False Positives)
# Prevents double count when test_pass invokes after test_fail
CURRENT_TEST_FAILED=0

# Temporary director
TEST_TEMP_DIR=""

# Color (compatibility with terminal and fallback)
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    TEST_GREEN=$(tput setaf 2)
    TEST_RED=$(tput setaf 1)
    TEST_YELLOW=$(tput setaf 3)
    # TEST_CYAN enters in public palette framework (uses
    # externals suite-scripts), itself framework its not prints.
    # shellcheck disable=SC2034
    TEST_CYAN=$(tput setaf 6)
    TEST_BOLD=$(tput bold)
    TEST_RESET=$(tput sgr0)
else
    TEST_GREEN='\033[0;32m'
    TEST_RED='\033[0;31m'
    TEST_YELLOW='\033[1;33m'
    # shellcheck disable=SC2034
    TEST_CYAN='\033[0;36m'
    TEST_BOLD='\033[1m'
    TEST_RESET='\033[0m'
fi

# =================================================================
# MAIN FUNCTIONS TESTING
# =================================================================

# Start test (resets flag state)
# [FIX] "|| true" on increments: post-increment with zero returns
# status 1 and broke chains kind "assert && test_pass || test_fail"
test_start() {
    local name="$1"
    CURRENT_TEST_FAILED=0  # [FIX] Flush flag for each new test
    ((TESTS_RUN++)) || true
    printf "  Testing: %-50s " "$name"
}

# Success completion test
test_pass() {
    # [FIX] Counted success ONLY ifs not was calls test_fail
    # This makes framework "bulletproof" - test_pass after test_fail ignores
    if [[ $CURRENT_TEST_FAILED -eq 0 ]]; then
        printf '%s\n' "${TEST_GREEN}✓ PASS${TEST_RESET}"
        ((TESTS_PASSED++)) || true
    fi
}

# Failed completion test
test_fail() {
    local reason="${1:-}"

    # [FIX] Ifs test already was failed earlier, not plus counter twices
    if [[ $CURRENT_TEST_FAILED -eq 0 ]]; then
        printf '%s\n' "${TEST_RED}✗ FAIL${TEST_RESET}"
        ((TESTS_FAILED++)) || true
        CURRENT_TEST_FAILED=1
    fi

    if [[ -n "$reason" ]]; then
        printf '           %s\n' "${TEST_RED}Reason: ${reason}${TEST_RESET}"
    fi
}

# Skip test
test_skip() {
    local reason="${1:-No reason provided}"
    printf '%s\n' "${TEST_YELLOW}⊘ SKIP${TEST_RESET}"
    ((TESTS_SKIPPED++)) || true
    if [[ -n "$reason" ]]; then
        printf '           %s\n' "${TEST_YELLOW}Reason: ${reason}${TEST_RESET}"
    fi
}

# =================================================================
# ASSERT FUNCTIONS (Assertion Library)
# =================================================================

# Check equality line
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        test_fail "$message: expected '$expected', got '$actual'"
        return 1
    fi
}

# Check inequality line
assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"

    if [[ "$expected" != "$actual" ]]; then
        return 0
    else
        test_fail "$message: values should differ but both are '$expected'"
        return 1
    fi
}

# Check, that line contains substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        test_fail "$message: '$haystack' does not contain '$needle'"
        return 1
    fi
}

# Check, that line NOT contains substring
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    else
        test_fail "$message: '$haystack' contains '$needle'"
        return 1
    fi
}

# Check, that line empty
assert_empty() {
    local value="$1"
    local message="${2:-Value should be empty}"

    if [[ -z "$value" ]]; then
        return 0
    else
        test_fail "$message: expected empty, got '$value'"
        return 1
    fi
}

# Check, that line NOT empty
assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"

    if [[ -n "$value" ]]; then
        return 0
    else
        test_fail "$message: value is empty"
        return 1
    fi
}

# Check truthiness (true/1)
# [FIX] Fix error typings - use string comparison instead -eq
# Operator -eq intended only for numbers and may called error durings string value
assert_true() {
    local condition="$1"
    local message="${2:-Condition should be true}"

    # [FIX] Safe string comparison instead numeric -eq
    if [[ "$condition" == "true" || "$condition" == "1" ]]; then
        return 0
    else
        test_fail "$message: expected true/1, got '$condition'"
        return 1
    fi
}

# Check falsiness (false/0/empty)
# [FIX] Fix error typings - use string comparison instead -eq
assert_false() {
    local condition="$1"
    local message="${2:-Condition should be false}"

    # [FIX] Safe string comparison instead numeric -eq
    if [[ "$condition" == "false" || "$condition" == "0" || -z "$condition" ]]; then
        return 0
    else
        test_fail "$message: expected false/0/empty, got '$condition'"
        return 1
    fi
}

# Check existence file
assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"

    if [[ -f "$file" ]]; then
        return 0
    else
        test_fail "$message: file '$file' does not exist"
        return 1
    fi
}

# Check missing file
assert_file_not_exists() {
    local file="$1"
    local message="${2:-File should not exist}"

    if [[ ! -f "$file" ]]; then
        return 0
    else
        test_fail "$message: file '$file' exists"
        return 1
    fi
}

# Check existence directors
assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory should exist}"

    if [[ -d "$dir" ]]; then
        return 0
    else
        test_fail "$message: directory '$dir' does not exist"
        return 1
    fi
}

# Check, that command success (exit code 0)
assert_success() {
    local exit_code=$1
    local message="${2:-Command should succeed}"

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        test_fail "$message: exit code $exit_code"
        return 1
    fi
}

# Check, that command falls (exit code != 0)
assert_failure() {
    local exit_code=$1
    local message="${2:-Command should fail}"

    if [[ $exit_code -ne 0 ]]; then
        return 0
    else
        test_fail "$message: expected failure but got exit code 0"
        return 1
    fi
}

# =================================================================
# MANAGEMENT TEMPORARY DIRECTOR
# =================================================================

# Create temporary directors
# [FIX] Add trap for guaranteed cleanups durings any completions
setup_temp_dir() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dpx_test_XXXXXX")

    # [FIX] Guaranteed cleanup durings any completions script
    # Will fire even durings exit 1 ors Ctrl+C
    trap 'cleanup_test_jobs; cleanup_temp_dir' EXIT

    echo "Test directory: $TEST_TEMP_DIR"
}

# Cleanup temporary directors
cleanup_temp_dir() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
        TEST_TEMP_DIR=""
    fi
}

# Do not leave child jobs attached to a test shell.  In particular, update
# checks and provider tests may create short-lived background processes.
cleanup_test_jobs() {
    local -a job_pids=()
    mapfile -t job_pids < <(jobs -pr 2>/dev/null)
    (( ${#job_pids[@]} == 0 )) || kill "${job_pids[@]}" 2>/dev/null || true
}

# =================================================================
# GENERATORS MOCK-OBJECTS
# =================================================================

# Create fake project WordPress
create_fake_wordpress_project() {
    local project_dir="$1"
    local project_name="${2:-testproject}"
    # site_url accessible calling suite-scripts via return
    # instead with path (contract generators mock-objects).
    # shellcheck disable=SC2034
    local site_url="${3:-https://${project_name}.ddev.site}"

    mkdir -p "$project_dir"
    mkdir -p "$project_dir/wp-content/themes"
    mkdir -p "$project_dir/.ddev"

    # wp-config.php
    cat > "$project_dir/wp-config.php" << 'PHPEOF'
<?php
define('DB_NAME', 'db');
define('DB_USER', 'db');
define('DB_PASSWORD', 'db');
define('DB_HOST', 'db');
define('WP_SITEURL', 'https://example.com');
 $table_prefix = 'wp_';
PHPEOF

    # DDEV config.yaml
    cat > "$project_dir/.ddev/config.yaml" << YAML
name: $project_name
type: wordpress
docroot: ""
php_version: "8.1"
webserver_type: nginx-fpm
YAML

    # Fake then
    mkdir -p "$project_dir/wp-content/themes/test-theme"
    echo "/* Theme */" > "$project_dir/wp-content/themes/test-theme/style.css"

    echo "$project_dir"
}

# Create fake project Joomla
create_fake_joomla_project() {
    local project_dir="$1"
    local project_name="${2:-joomlatest}"

    mkdir -p "$project_dir"
    mkdir -p "$project_dir/administrator"
    mkdir -p "$project_dir/components"
    mkdir -p "$project_dir/.ddev"

    # configuration.php
    cat > "$project_dir/configuration.php" << 'PHPEOF'
<?php
class JConfig {
    public $host = 'db';
    public $user = 'db';
    public $password = 'db';
    public $db = 'db';
    public $live_site = 'https://example.com';
}
PHPEOF

    # DDEV config.yaml
    cat > "$project_dir/.ddev/config.yaml" << YAML
name: $project_name
type: php
docroot: ""
php_version: "8.0"
webserver_type: apache-fpm
YAML

    echo "$project_dir"
}

# Create fake DDEV project (generic)
create_fake_ddev_project() {
    local project_dir="$1"
    local project_name="${2:-genericproject}"
    local project_type="${3:-php}"
    local php_version="${4:-8.1}"

    mkdir -p "$project_dir/.ddev"

    cat > "$project_dir/.ddev/config.yaml" << YAML
name: $project_name
type: $project_type
docroot: ""
php_version: "$php_version"
webserver_type: nginx-fpm
YAML

    # File structure
    mkdir -p "$project_dir/public"
    echo "<?php echo 'Hello';" > "$project_dir/public/index.php"

    echo "$project_dir"
}

# Create fake SQL-dump
create_fake_sql_dump() {
    local output_file="$1"
    local db_name="${2:-testdb}"

    cat > "$output_file" << SQLEOF
-- MySQL dump
-- Database: $db_name

CREATE TABLE wp_options (
    option_id bigint(20) NOT NULL,
    option_name varchar(191) NOT NULL,
    option_value longtext NOT NULL
);

INSERT INTO wp_options VALUES (1, 'siteurl', 'https://example.ddev.site');
INSERT INTO wp_options VALUES (2, 'home', 'https://example.ddev.site');
SQLEOF

    echo "$output_file"
}

# Create fake config DPX
create_fake_dpx_config() {
    local config_dir="$1"

    mkdir -p "$config_dir"

    cat > "$config_dir/config.sh" << 'BASH'
# DPX Config
DDEV_PROJECTS_BASE_PATH="$HOME/projects"
DB_PROD_PATH="$HOME/backups/prod"
DB_LOCAL_PATH="$HOME/backups/local"
DEFAULT_PHP_VERSION="8.1"
PROJECT_TLD="ddev.site"
DEFAULT_PROD_TLD="by"
BASH

    echo "$config_dir"
}

# =================================================================
# FINAL REPORTING
# =================================================================

print_test_summary() {
    echo ""
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo "${TEST_BOLD}         Test Results Summary${TEST_RESET}"
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo ""
    printf "Total:    %d\n" "$TESTS_RUN"
    printf "${TEST_GREEN}Passed:   %d${TEST_RESET}\n" "$TESTS_PASSED"
    printf "${TEST_RED}Failed:   %d${TEST_RESET}\n" "$TESTS_FAILED"
    printf "${TEST_YELLOW}Skipped:  %d${TEST_RESET}\n" "$TESTS_SKIPPED"
    echo ""

    # Check integrities statistics
    local calculated_total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    if [[ $calculated_total -ne $TESTS_RUN ]]; then
        echo "${TEST_RED}WARNING: Statistics mismatch!${TEST_RESET}"
        echo "  Expected: $TESTS_RUN, Got: $calculated_total"
    fi

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "${TEST_RED}${TEST_BOLD}✗ SOME TESTS FAILED${TEST_RESET}"
        return 1
    else
        echo "${TEST_GREEN}${TEST_BOLD}✓ ALL TESTS PASSED${TEST_RESET}"
        return 0
    fi
}

# =================================================================
# INITIALIZATION HEADER
# =================================================================

print_test_header() {
    local suite_name="${1:-Test Suite}"
    local version="${2:-1.0.0}"

    echo ""
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo "${TEST_BOLD}     $suite_name v$version${TEST_RESET}"
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo ""
}
