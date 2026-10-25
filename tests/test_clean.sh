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
# [D-3] Real DDEV DB snapshots live in <project>/.ddev-db-snapshots;
# .dpx/snapshots never existed in production code (dead feature).
mkdir -p "$PROJECT/.dpx/tmp" "$PROJECT/.dpx/config" "$PROJECT/.ddev-db-snapshots"
printf 'old\n' > "$PROJECT/.dpx/tmp/old.tmp"
printf 'new\n' > "$PROJECT/.dpx/tmp/new.tmp"
printf 'config\n' > "$PROJECT/.dpx/config/settings"
printf 'marker\n' > "$PROJECT/.dpx/current_snapshot"
printf 'snapshot\n' > "$PROJECT/.ddev-db-snapshots/snap.sql"
touch -t 202001010000 "$PROJECT/.dpx/tmp/old.tmp"

test_start "default clean removes only temp files older than 7 days"
(cd "$PROJECT" && cmd_clean </dev/null >/dev/null 2>&1)
if [[ ! -e "$PROJECT/.dpx/tmp/old.tmp" && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "default age policy incorrect"
fi

test_start "default clean preserves config, marker and DDEV snapshots"
if [[ -e "$PROJECT/.dpx/config/settings" && -e "$PROJECT/.dpx/current_snapshot" \
   && -e "$PROJECT/.ddev-db-snapshots/snap.sql" ]]; then
    test_pass
else
    test_fail "protected DPX state removed"
fi

test_start "non-TTY snapshot removal without --yes is refused atomically"
if (cd "$PROJECT" && cmd_clean --snapshots </dev/null >/dev/null 2>&1); then
    test_fail "cmd_clean --snapshots must fail without -y in non-TTY mode"
elif [[ -e "$PROJECT/.ddev-db-snapshots/snap.sql" && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "refusal mutated project state"
fi

test_start "--snapshots -y refuses while a recovery marker is live"
if (cd "$PROJECT" && cmd_clean --snapshots --yes </dev/null >/dev/null 2>&1); then
    test_fail "cmd_clean must require --force for a live recovery marker"
elif [[ -e "$PROJECT/.ddev-db-snapshots/snap.sql" \
     && -e "$PROJECT/.dpx/current_snapshot" && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "protected snapshot state was mutated"
fi

test_start "--snapshots -y --force removes snapshots and marker together"
(cd "$PROJECT" && cmd_clean --snapshots --yes --force </dev/null >/dev/null 2>&1)
if [[ ! -d "$PROJECT/.ddev-db-snapshots" && ! -e "$PROJECT/.dpx/current_snapshot" \
   && -e "$PROJECT/.dpx/config/settings" && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "--force snapshot policy incorrect"
fi

mkdir -p "$PROJECT/.ddev-db-snapshots"
printf 'snapshot\n' > "$PROJECT/.ddev-db-snapshots/snap.sql"
printf '%s\n' "$$" > "$PROJECT/.dpx/tunnel.pid"
test_start "--snapshots -y refuses while .dpx/tunnel.pid is active"
if (cd "$PROJECT" && cmd_clean --snapshots --yes </dev/null >/dev/null 2>&1); then
    test_fail "cmd_clean must require --force for an active tunnel"
elif [[ -e "$PROJECT/.ddev-db-snapshots/snap.sql" && -e "$PROJECT/.dpx/tunnel.pid" ]]; then
    test_pass
else
    test_fail "active-tunnel refusal mutated snapshot state"
fi

test_start "--snapshots -y --force removes snapshots during an active tunnel"
(cd "$PROJECT" && cmd_clean --snapshots --yes --force </dev/null >/dev/null 2>&1)
rm -f "$PROJECT/.dpx/tunnel.pid"
if [[ ! -d "$PROJECT/.ddev-db-snapshots" && -e "$PROJECT/.dpx/config/settings" \
   && -e "$PROJECT/.dpx/tmp/new.tmp" ]]; then
    test_pass
else
    test_fail "force removal during active tunnel failed"
fi

mkdir -p "$PROJECT/.ddev-db-snapshots"
printf 'snapshot\n' > "$PROJECT/.ddev-db-snapshots/snap.sql"
test_start "--all -y removes all temp files and DDEV snapshots but preserves config"
(cd "$PROJECT" && cmd_clean --all --yes </dev/null >/dev/null 2>&1)
if [[ ! -e "$PROJECT/.dpx/tmp/new.tmp" && ! -d "$PROJECT/.ddev-db-snapshots" \
   && -e "$PROJECT/.dpx/config/settings" && ! -e "$PROJECT/.dpx/current_snapshot" ]]; then
    test_pass
else
    test_fail "--all policy incorrect"
fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
