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
# Covers the complete shell surface: entry points, installer, runner,
# every lib/ and commands/ module (including the nested site layout),
# and the test suite.
#
# Files are analyzed one at a time. A single multi-file shellcheck run
# triggers pathological cross-file analysis on this codebase (minutes
# instead of seconds), so the per-file loop is intentional.
# Missing shellcheck — SKIP (gate must not block CI without the linter).
# =================================================================

SHELLCHECK_TARGETS=(
    "$TESTS_DIR/dpx.sh"
    "$TESTS_DIR/install.sh"
    "$TESTS_DIR/run_tests.sh"
    "$TESTS_DIR"/lib/*.sh
    "$TESTS_DIR"/commands/*.sh
    "$TESTS_DIR"/commands/site/*.sh
    "$TESTS_DIR"/tests/test_*.sh
)

# Non-blocking ShellCheck codes are limited to checks that cannot be
# resolved statically in this codebase:
#   1091 - source file not followed (dynamic DPX_ROOT sources)
#   2329 - function is never invoked (commands are dispatched dynamically)
# Everything else, including SC2086 (reported as "info" by current
# ShellCheck releases), is actionable and fails the gate.
SHELLCHECK_NONBLOCKING_CODES=(1091 2329)

_shellcheck_actionable_filter() {
    local code
    local code_filter="true"
    for code in "${SHELLCHECK_NONBLOCKING_CODES[@]}"; do
        code_filter+=" and .code != $code"
    done

    # The allowlist applies regardless of severity: SC1091/SC2329 cannot
    # be resolved by this code structure, while every other finding
    # (including info-level SC2086) must fail the gate.
    printf '(%s)' "$code_filter"
}

_shellcheck_count_actionable() {
    local json="$1"
    local filter
    filter="$(_shellcheck_actionable_filter)"
    jq "[.[] | select($filter)] | length" <<<"$json"
}

_shellcheck_format_actionable() {
    local json="$1"
    local filter
    filter="$(_shellcheck_actionable_filter)"
    jq -r ".[] | select($filter) | \"\\(.file):\\(.line):\\(.column): \\(.level): \\(.message) [SC\\(.code)]\"" <<<"$json"
}

# Self-test: a seeded SC2086 must be reported. Current ShellCheck emits
# SC2086 at "info" level, which the old gcc/note filter silently dropped.
_shellcheck_gate_selftest() {
    local tmp_dir probe json file_rc=0 issues=0

    if ! tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dpx_shellcheck_probe.XXXXXX")"; then
        echo "${RED}shellcheck self-test: cannot create temporary directory${RESET}"
        return 1
    fi
    probe="${tmp_dir}/SC2086.sh"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        "value=\"\$1\"" \
        "printf \"%s\\n\" \$value" > "$probe"

    json="$(shellcheck -s bash -S style -f json "$probe" 2>&1)" || file_rc=$?
    if (( file_rc > 1 )); then
        echo "${RED}shellcheck self-test: shellcheck failed (rc=${file_rc})${RESET}"
        printf '%s\n' "$json"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! issues="$(_shellcheck_count_actionable "$json")"; then
        echo "${RED}shellcheck self-test: cannot parse JSON output${RESET}"
        printf '%s\n' "$json"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! jq -e 'any(.[]; .code == 2086)' <<<"$json" >/dev/null; then
        echo "${RED}shellcheck self-test: seeded SC2086 was not reported${RESET}"
        printf '%s\n' "$json"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    if (( issues < 1 )); then
        echo "${RED}shellcheck self-test: seeded SC2086 was filtered out${RESET}"
        return 1
    fi
    return 0
}

run_shellcheck_gate() {
    local target file_output file_rc issues total_issues=0
    local -a failing_output=()

    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "${YELLOW}>>> Static analysis: shellcheck not found - SKIPPED${RESET}"
        echo ""
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "${RED}shellcheck: jq not found - cannot verify findings honestly${RESET}"
        echo ""
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        return 0
    fi

    echo "${CYAN}>>> Static analysis: shellcheck${RESET}"
    echo "----------------------------------------"

    if ! _shellcheck_gate_selftest; then
        total_issues=$((total_issues + 1))
        failing_output+=("shellcheck self-test failed: the gate would report a false green")
    fi

    for target in "${SHELLCHECK_TARGETS[@]}"; do
        [[ -f "$target" ]] || continue

        # Parse JSON: severity labels and output layout are not stable
        # across ShellCheck versions. Count every finding except the two
        # explicitly non-blocking codes above.
        file_rc=0
        file_output="$(shellcheck -s bash -S style -f json "$target" 2>&1)" || file_rc=$?
        if (( file_rc > 1 )); then
            total_issues=$((total_issues + 1))
            failing_output+=("${target}: shellcheck failed (rc=${file_rc}):"$'\n'"$file_output")
            continue
        fi

        if ! issues="$(_shellcheck_count_actionable "$file_output")"; then
            total_issues=$((total_issues + 1))
            failing_output+=("${target}: invalid shellcheck JSON output:"$'\n'"$file_output")
            continue
        fi

        if (( issues > 0 )); then
            total_issues=$((total_issues + issues))
            failing_output+=("$(_shellcheck_format_actionable "$file_output")")
        fi
    done

    if (( total_issues > 0 )); then
        printf '%s\n' "${failing_output[@]}"
        echo "${RED}shellcheck: $total_issues issue(s) found${RESET}"
        TOTAL_FAILED=$((TOTAL_FAILED + total_issues))
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
