#!/usr/bin/env bash
# =================================================================
# DPX Test Runner - start all tests
# =================================================================

# =================================================================
# CHECK VERSIONS BASH (protect from macOS Bash 3.2)
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: DPX Test Runner requires Bash 4.0+" >&2
    echo "Current version: ${BASH_VERSION:-unknown}" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS: install brew install bash and update PATH" >&2
    fi
    exit 1
fi

# =================================================================
# INITIALIZATION
# =================================================================

# Determin director tests (where lies run_tests.sh)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Color
if command -v tput >/dev/null 2>&1; then
    GREEN=$(tput setaf 2); RED=$(tput setaf 1); YELLOW=$(tput setaf 3); CYAN=$(tput setaf 6); BOLD=$(tput bold); RESET=$(tput sgr0)
else
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
fi

# Counters
TOTAL_RUN=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

echo ""
echo "${BOLD}========================================${RESET}"
echo "${BOLD}        DPX Test Suite v1.3.0${RESET}"
echo "${BOLD}========================================${RESET}"
echo ""

# =================================================================
# AUTODISCOVERY TESTS
# =================================================================

# Searching all test_*.sh files
# Ifs run_tests.sh in root project - searching in tests/
# Ifs run_tests.sh in tests/ - searching in current directors
TEST_FILES=()

# Variant 1: tests in subfolder tests/ (run_tests.sh in root)
if [[ -d "$TESTS_DIR/tests" ]]; then
    for f in "$TESTS_DIR/tests"/test_*.sh; do
        [[ -e "$f" ]] && TEST_FILES+=("$f")
    done
fi

# Variant 2: tests row with run_tests.sh (both in tests/)
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    for f in "$TESTS_DIR"/test_*.sh; do
        [[ -e "$f" ]] && TEST_FILES+=("$f")
    done
fi

# Check presence tests
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "${RED}Tests not founds in directors: $TESTS_DIR${RESET}"
    echo "${YELLOW}Looks for files with named test_*.sh${RESET}"
    exit 1
fi

# =================================================================
# STATIC ANALYSIS (shellcheck gate)
#
# Area: files, supported data suite (runner + tests +
# tested modules from last refactoring).
# Legacy module (command/*.sh, devilbox.sh and etc.) not included —
# their cleanup extracted in separate task.
# Durings missings shellcheck — SKIP (gate not blocks CI without linter).
# =================================================================

SHELLCHECK_TARGETS=(
    "$TESTS_DIR/run_tests.sh"
    "$TESTS_DIR"/tests/test_*.sh
    "$TESTS_DIR/lib/args.sh"
)

run_shellcheck_gate() {
    local sc_output="" sc_rc=0 issues=0

    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "${YELLOW}>>> Static analysis: shellcheck not found - SKIPPED${RESET}"
        echo ""
        return 0
    fi

    echo "${CYAN}>>> Static analysis: shellcheck${RESET}"
    echo "----------------------------------------"

    # -x: trace constant-source (lib/*); -f gcc: findings in format
    # 'file:line:col: severity: msg [SCxxxx]' — reliable parsing counter
    sc_output="$(shellcheck -s bash -x -S style -f gcc "${SHELLCHECK_TARGETS[@]}")" || sc_rc=$?

    if [[ $sc_rc -ne 0 ]]; then
        echo "$sc_output"
        issues="$(grep -cE '\[SC[0-9]+\]' <<<"$sc_output")" || true
        issues="${issues// /}"
        issues="${issues:-0}"
        echo "${RED}shellcheck: $issues issue(s) found${RESET}"
        TOTAL_FAILED=$((TOTAL_FAILED + issues))
    else
        echo "${GREEN}shellcheck: all targets clean${RESET}"
    fi
    echo ""

    return 0
}

run_shellcheck_gate

# =================================================================
# FUNCTION START TEST
# =================================================================

run_test_file() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .sh)
    
    echo "${CYAN}>>> Running: ${test_name}${RESET}"
    echo "----------------------------------------"
    
    # Start test via that same interpreter Bash, that and runner
    # Important for macOS: use ${BASH}, and not system /bin/bash (3.2)
    local output
    local exit_code
    
    output=$("${BASH}" "$test_file" 2>&1)
    exit_code=$?
    
    echo "$output"
    
    # Pars results from output
    # Use grep -oE instead grep -oP for compatibilities with macOS/BSD
    local run passed failed skipped
    
    run=$(echo "$output" | grep -oE 'Total:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    passed=$(echo "$output" | grep -oE 'Passed:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    failed=$(echo "$output" | grep -oE 'Failed:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    skipped=$(echo "$output" | grep -oE 'Skipped:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    
    # Protect from empty value (use ${var:-0})
    # Prevents error "operand expected" durings complexes
    run=${run:-0}
    passed=${passed:-0}
    failed=${failed:-0}
    skipped=${skipped:-0}
    
    TOTAL_RUN=$((TOTAL_RUN + run))
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped))
    
    echo ""
    
    return $exit_code
}

# =================================================================
# START TESTS
# =================================================================

for test_file in "${TEST_FILES[@]}"; do
    run_test_file "$test_file"
done

# =================================================================
# FINAL REPORT
# =================================================================

echo "${BOLD}========================================${RESET}"
echo "${BOLD}         FINAL TEST REPORT${RESET}"
echo "${BOLD}========================================${RESET}"
echo ""
printf "Total Tests:   %d\n" "$TOTAL_RUN"
printf "${GREEN}Passed:        %d${RESET}\n" "$TOTAL_PASSED"
printf "${RED}Failed:        %d${RESET}\n" "$TOTAL_FAILED"
printf "${YELLOW}Skipped:       %d${RESET}\n" "$TOTAL_SKIPPED"
echo ""

if [[ $TOTAL_FAILED -gt 0 ]]; then
    echo "${RED}${BOLD}✗ SOME TESTS FAILED${RESET}"
    exit 1
else
    echo "${GREEN}${BOLD}✓ ALL TESTS PASSED${RESET}"
    exit 0
fi
