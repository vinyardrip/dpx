#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: --here flag (ddev / new commands)
#
# Covers: flag parsing in lib/args.sh, `dpx ddev ... --here`
# (current-folder execution + validation) and `dpx new ... --here`
# (cwd scaffolding, name fallback, protective checks, no deletion
# of the user's current directory on scaffold failure).
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Tests require Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: --here flag (ddev/new)" "1.0.0"
setup_temp_dir >/dev/null

source "$DPX_ROOT/lib/core.sh"
# Isolated projects root for this suite
# shellcheck disable=SC2034
DEFAULT_CONFIG["ddev_projects_base_path"]="$TEST_TEMP_DIR/ws"
PROJECTS_ROOT="$TEST_TEMP_DIR/ws"
mkdir -p "$PROJECTS_ROOT"

source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/args.sh"
source "$DPX_ROOT/lib/database.sh"
source "$DPX_ROOT/lib/projects.sh"

# shellcheck disable=SC1091
source "$DPX_ROOT/commands/ddev.sh"
# shellcheck disable=SC1091
source "$DPX_ROOT/commands/new.sh"

# =================================================================
# MOCK DDEV (records calls + cwd into a log file)
# =================================================================

HERE_MOCK_LOG="$TEST_TEMP_DIR/mock_ddev.log"
HERE_MOCK_BIN="$TEST_TEMP_DIR/mockbin"
mkdir -p "$HERE_MOCK_BIN"

build_mock_ddev() {
    # $1 = exit code for `ddev config` (0 = success path, 1 = failure path)
    local config_rc="${1:-0}"
    cat > "$HERE_MOCK_BIN/ddev" << EOF
#!/usr/bin/env bash
printf '%s\n' "ARGS:\$*" >> "$HERE_MOCK_LOG"
printf '%s\n' "CWD:\$PWD" >> "$HERE_MOCK_LOG"
if [[ "\$1" == "--version" ]]; then
    echo "ddev version v1.25.5"
    exit 0
fi
if [[ "\$1" == "config" ]]; then
    exit $config_rc
fi
exit 0
EOF
    chmod +x "$HERE_MOCK_BIN/ddev"
}

mock_calls() {
    if [[ -f "$HERE_MOCK_LOG" ]]; then
        grep -c "^ARGS:" "$HERE_MOCK_LOG" 2>/dev/null || true
    else
        echo 0
    fi
}

mock_last_args() {
    grep "^ARGS:" "$HERE_MOCK_LOG" 2>/dev/null | tail -1
}

mock_last_cwd() {
    grep "^CWD:" "$HERE_MOCK_LOG" 2>/dev/null | tail -1
}

# Assert some recorded call contains the given marker (calls are appended
# by the mock in order; the scaffold flow ends with `ddev launch`, so the
# config call is rarely the last one).
mock_args_contain() {
    [[ -f "$HERE_MOCK_LOG" ]] && grep -qF -- "$1" "$HERE_MOCK_LOG"
}

check_value() { # $1 expected, $2 actual
    if [[ "$1" == "$2" ]]; then
        test_pass
    else
        test_fail "expected '$1', got '$2'"
    fi
}

run_here_in_dir() {
    # run_here_in_dir <workdir> <ddev-config-rc> <cmd_ddev|cmd_new> args...
    # Executes the command in an isolated directory with the mocked ddev
    # on PATH; stdout/stderr are captured, rc is echoed as last line.
    local workdir="$1" config_rc="$2" func="$3"
    shift 3
    build_mock_ddev "$config_rc"
    rm -f "$HERE_MOCK_LOG"
    (
        export PATH="$HERE_MOCK_BIN:$PATH"
        cd "$workdir" || exit 97
        "$func" "$@" </dev/null
    ) 2>&1
    echo "rc=$?"
}

# =================================================================
# SECTION A: flag parsing (lib/args.sh)
# =================================================================

echo ""
echo "${TEST_CYAN}=== parse_args: --here flag ===${TEST_RESET}"

test_start "--here parsed as boolean flag"
parse_args --here 2>/dev/null
check_value "1" "$(get_arg here "")"

test_start "--here=1 value-form also sets the flag"
parse_args --here=1 2>/dev/null
check_value "1" "$(get_arg here "")"

test_start "--here absent -> flag empty"
parse_args --cms=php 2>/dev/null
check_value "" "$(get_arg here "")"

# =================================================================
# SECTION B: ddev --here
# =================================================================

echo ""
echo "${TEST_CYAN}=== cmd_ddev --here ===${TEST_RESET}"

test_start "help documents --here"
out="$(show_ddev_help 2>&1)"
if grep -qF -- "--here" <<<"$out"; then
    test_pass
else
    test_fail "--here missing from ddev help"
fi

test_start "--here inside a DDEV project: runs ddev in cwd, flag stripped"
fake_proj="$TEST_TEMP_DIR/hereproj"
create_fake_ddev_project "$fake_proj" hereproj >/dev/null
out="$(run_here_in_dir "$fake_proj" 0 cmd_ddev describe --here)"
last_args="$(mock_last_args)"
last_cwd="$(mock_last_cwd)"
if [[ "$last_args" == "ARGS:describe" ]] \
    && [[ "$last_cwd" == "CWD:$fake_proj" ]] \
    && [[ "$out" != *"--here"* ]]; then
    test_pass
else
    test_fail "args='$last_args' cwd='$last_cwd' out='$out'"
fi

test_start "--here=1 value-form behaves the same"
out="$(run_here_in_dir "$fake_proj" 0 cmd_ddev describe --here=1)"
last_args="$(mock_last_args)"
if [[ "$last_args" == "ARGS:describe" ]]; then
    test_pass
else
    test_fail "args='$last_args'"
fi

test_start "--here outside a DDEV project: clean error, ddev never called"
plain_dir="$TEST_TEMP_DIR/plain"
mkdir -p "$plain_dir"
out="$(run_here_in_dir "$plain_dir" 0 cmd_ddev describe --here)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "1" ]] && grep -qiF "not a DDEV project" <<<"$out" && [[ "$(mock_calls)" == "0" ]]; then
    test_pass
else
    test_fail "rc='$rc' calls='$(mock_calls)' out='$out'"
fi

test_start "--here does NOT fall back to the interactive project menu"
# The menu would block on stdin; </dev/null makes any read return EOF.
# A correct implementation must error out before ever reaching it.
out="$(run_here_in_dir "$plain_dir" 0 cmd_ddev exec wp cache flush --here)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "1" ]] && ! grep -qF "Project" <<<"$out"; then
    test_pass
else
    test_fail "rc='$rc' menu output leaked: '$out'"
fi

test_start "regression: without --here inside a project stays transparent"
out="$(run_here_in_dir "$fake_proj" 0 cmd_ddev exec wp cache flush)"
last_args="$(mock_last_args)"
last_cwd="$(mock_last_cwd)"
if [[ "$last_args" == "ARGS:exec wp cache flush" ]] && [[ "$last_cwd" == "CWD:$fake_proj" ]]; then
    test_pass
else
    test_fail "args='$last_args' cwd='$last_cwd'"
fi

test_start "regression: --here with no subcommand still shows help (rc 0)"
out="$(run_here_in_dir "$plain_dir" 0 cmd_ddev --here)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "0" ]] && grep -qF -- "--here" <<<"$out"; then
    test_pass
else
    test_fail "rc='$rc'"
fi

# =================================================================
# SECTION C: new --here
# =================================================================

echo ""
echo "${TEST_CYAN}=== cmd_new --here ===${TEST_RESET}"

test_start "help documents --here"
out="$(show_new_help 2>&1)"
if grep -qF -- "--here" <<<"$out"; then
    test_pass
else
    test_fail "--here missing from new help"
fi

test_start "--here scaffolds in current folder, name falls back to folder name"
empty_dir="$TEST_TEMP_DIR/brandnewsite"
mkdir -p "$empty_dir"
out="$(run_here_in_dir "$empty_dir" 0 cmd_new --here --cms=php -y)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "0" ]] \
    && [[ -f "$empty_dir/index.php" ]] \
    && mock_args_contain "--project-name brandnewsite" \
    && grep -qF "CWD:$empty_dir" "$HERE_MOCK_LOG"; then
    test_pass
else
    test_fail "rc='$rc' calls='$(mock_calls)' out='$out'"
fi

test_start "--here with explicit project name keeps the given name"
named_dir="$TEST_TEMP_DIR/nameddir"
mkdir -p "$named_dir"
out="$(run_here_in_dir "$named_dir" 0 cmd_new mysurface --here --cms=php -y)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "0" ]] && mock_args_contain "--project-name mysurface"; then
    test_pass
else
    test_fail "rc='$rc' calls='$(mock_calls)' out='$out'"
fi

test_start "--here refuses to scaffold over an existing DDEV project"
out="$(run_here_in_dir "$fake_proj" 0 cmd_new --here --cms=php -y)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "1" ]] && grep -qiF "already a DDEV project" <<<"$out" && [[ "$(mock_calls)" == "0" ]]; then
    test_pass
else
    test_fail "rc='$rc' calls='$(mock_calls)' out='$out'"
fi

test_start "--here invalid project name rejected before scaffolding"
bad_dir="$TEST_TEMP_DIR/baddir"
mkdir -p "$bad_dir"
out="$(run_here_in_dir "$bad_dir" 0 cmd_new "Bad_Name!" --here --cms=php -y)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "1" ]] && [[ ! -f "$bad_dir/index.php" ]]; then
    test_pass
else
    test_fail "rc='$rc' out='$out'"
fi

test_start "[SAFETY] failed --here scaffold must NOT delete the current folder"
# `ddev config` fails -> scaffold aborts -> the pre-run contents of the
# user's directory must survive untouched.
victim_dir="$TEST_TEMP_DIR/victimdir"
mkdir -p "$victim_dir"
echo "precious" > "$victim_dir/precious.txt"
out="$(run_here_in_dir "$victim_dir" 1 cmd_new --here --cms=php -y)"
rc="${out##*$'\n'rc=}"
if [[ "$rc" == "1" ]] \
    && [[ -d "$victim_dir" ]] \
    && [[ -f "$victim_dir/precious.txt" ]] \
    && grep -qiF "left as-is" <<<"$out"; then
    test_pass
else
    test_fail "rc='$rc' dir=$( [[ -d "$victim_dir" ]] && echo exists || echo DELETED ) out='$out'"
fi

# =================================================================
# SUMMARIES
# =================================================================

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
