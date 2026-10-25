#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: to-prod project/CMS argument handling
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Tests require Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT DPX_LANG=en NO_COLOR=1

# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: dpx to-prod arguments" "1.0.0"
setup_temp_dir >/dev/null

source "$DPX_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$DPX_ROOT/commands/to-prod.sh"

PROJECT="$TEST_TEMP_DIR/sample-site"
PROD_DIR="$TEST_TEMP_DIR/prod"
PICKER_LOG="$TEST_TEMP_DIR/picker.log"
EXPORT_LOG="$TEST_TEMP_DIR/export.log"
mkdir -p "$PROJECT/.ddev" "$PROJECT/.dpx" "$PROD_DIR"

# Isolate the command from DDEV/Devilbox/interactive picks. All mocks are
# installed after the real modules are sourced so they override them.
projects_select_interactive() {
    printf 'picker-called\n' >> "$PICKER_LOG"
    return 1
}
projects_get_path() { printf '%s\n' "$PROJECT"; }
ddev_is_project_running() { return 0; }
get_db_prod_path() { printf '%s\n' "$PROD_DIR"; }
devilbox_stop() { return 0; }
core_rotate_backups() { return 0; }
db_wp_export_safe() {
    printf 'wp-export-called\n' >> "$EXPORT_LOG"
    return 0
}

test_start "--project-name skips the interactive project picker"
out="$(cmd_to_prod --project-name sample-site --cms-type wordpress \
    --prod-url https://prod.example.com --yes </dev/null 2>&1)"
rc=$?
if (( rc == 0 )) && [[ ! -e "$PICKER_LOG" ]] \
   && grep -qF "sample-site" <<<"$out"; then
    test_pass
else
    test_fail "project arg not honored (rc=$rc): $out"
fi

test_start "non-TTY CMS EOF announces the WordPress default"
rm -f "$PICKER_LOG" "$EXPORT_LOG"
out="$(cmd_to_prod --project-name sample-site \
    --prod-url https://prod.example.com --yes </dev/null 2>&1)"
rc=$?
if (( rc == 0 )) && [[ ! -e "$PICKER_LOG" ]] \
   && grep -qF "defaulting CMS type to WordPress" <<<"$out" \
   && grep -qF "wp-export-called" "$EXPORT_LOG"; then
    test_pass
else
    test_fail "non-TTY CMS default not explicit (rc=$rc): $out"
fi

test_start "invalid --project-name is rejected before scaffolding work"
rm -f "$PICKER_LOG" "$EXPORT_LOG"
out="$(cmd_to_prod --project-name Bad_Name --cms-type wordpress \
    --prod-url https://prod.example.com --yes </dev/null 2>&1)"
rc=$?
if (( rc != 0 )) && [[ ! -e "$PICKER_LOG" ]] && [[ ! -e "$EXPORT_LOG" ]]; then
    test_pass
else
    test_fail "invalid project name was not rejected (rc=$rc): $out"
fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
