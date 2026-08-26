#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: clean command
# =================================================================

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT DPX_LANG=en

# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: dpx clean" "1.0.0"
setup_temp_dir >/dev/null

source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/commands/clean.sh"

PROJECT="$TEST_TEMP_DIR/project"
mkdir -p "$PROJECT/.dpx/tmp" "$PROJECT/.dpx/config" "$PROJECT/.dpx/snapshots"
printf 'old\n' > "$PROJECT/.dpx/tmp/old.tmp"
printf 'new\n' > "$PROJECT/.dpx/tmp/new.tmp"
printf 'config\n' > "$PROJECT/.dpx/config/settings"
printf 'snapshot\n' > "$PROJECT/.dpx/snapshots/snap.sql"
touch -t 202001010000 "$PROJECT/.dpx/tmp/old.tmp"

test_start "default clean removes only temp files older than 7 days"
(cd "$PROJECT" && cmd_clean >/dev/null 2>&1)
if [[ ! -e "$PROJECT/.dpx/tmp/old.tmp" && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "default age policy incorrect"
fi

test_start "default clean preserves config and snapshots"
if [[ -e "$PROJECT/.dpx/config/settings" && -e "$PROJECT/.dpx/snapshots/snap.sql" ]]; then
    test_pass
else
    test_fail "protected DPX state removed"
fi

test_start "--snapshots removes snapshots but preserves config and fresh temp"
(cd "$PROJECT" && cmd_clean --snapshots >/dev/null 2>&1)
if [[ ! -d "$PROJECT/.dpx/snapshots" && -e "$PROJECT/.dpx/config/settings" \
   && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "--snapshots policy incorrect"
fi

mkdir -p "$PROJECT/.dpx/snapshots"
printf 'snapshot\n' > "$PROJECT/.dpx/snapshots/snap.sql"
test_start "--all removes all temp files and snapshots but preserves config"
(cd "$PROJECT" && cmd_clean --all >/dev/null 2>&1)
if [[ ! -e "$PROJECT/.dpx/tmp/new.tmp" && ! -d "$PROJECT/.dpx/snapshots" \
   && -e "$PROJECT/.dpx/config/settings" ]]; then
    test_pass
else
    test_fail "--all policy incorrect"
fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
