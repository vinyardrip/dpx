#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: site restore transaction marker/recovery
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

print_test_header "Unit Tests: dpx site restore transactions" "1.0.0"
setup_temp_dir >/dev/null

BASE="$TEST_TEMP_DIR/ws"
PROJECT="$BASE/proj"
PAYLOAD="$TEST_TEMP_DIR/payload"
ARCHIVE="$TEST_TEMP_DIR/FULL_proj_2026-01-01_120000.tar.gz"
SCEN="$TEST_TEMP_DIR/restore_scenario.sh"
DDEV_LOG="$TEST_TEMP_DIR/ddev.log"
MARKER="$PROJECT/.dpx/current_snapshot"

mkdir -p "$PROJECT/.dpx" "$PAYLOAD/proj"
printf 'file\n' > "$PAYLOAD/proj/file.txt"
printf 'dump\n' > "$PAYLOAD/proj_db.sql.gz"
tar -czf "$ARCHIVE" -C "$PAYLOAD" proj proj_db.sql.gz

cat > "$SCEN" << 'SCENARIO'
#!/usr/bin/env bash
export DPX_ROOT="$1" DPX_LANG=en NO_COLOR=1
source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
source "$DPX_ROOT/commands/site/restore.sh" >/dev/null 2>&1

base="$2"
archive="$3"
import_rc="$4"
recovery_rc="$5"
ddev_log="$6"

get_config() {
    case "$1" in
        ddev_projects_base_path) printf '%s\n' "$base" ;;
        *) printf '\n' ;;
    esac
}
db_create_snapshot() { printf 'pre_restore_mock\n'; }
db_import() { return "$import_rc"; }
db_post_import_cms() { return 0; }
ddev_launch() { return 0; }
ddev() {
    printf '%s\n' "$*" >> "$ddev_log"
    if [[ "$1" == snapshot && "$2" == restore ]]; then
        return "$recovery_rc"
    fi
    return 0
}

cmd_restore -y "$archive" >/dev/null 2>&1
echo "CMD_RC=$?"
exit 0
SCENARIO
chmod +x "$SCEN"

run_case() {
    local import_rc="$1" recovery_rc="$2"
    rm -f "$DDEV_LOG" "$MARKER"
    CASE_OUT="$(bash "$SCEN" "$DPX_ROOT" "$BASE" "$ARCHIVE" "$import_rc" "$recovery_rc" "$DDEV_LOG" </dev/null 2>&1)"
}

test_start "successful restore clears the pre-restore marker"
run_case 0 0
if grep -qF "CMD_RC=0" <<<"$CASE_OUT" && [[ ! -e "$MARKER" ]] && [[ ! -e "$DDEV_LOG" ]]; then
    test_pass
else
    test_fail "marker/recovery state wrong: $CASE_OUT"
fi

test_start "import failure restores snapshot and clears marker on success"
run_case 1 0
if grep -qF "CMD_RC=1" <<<"$CASE_OUT" \
   && [[ ! -e "$MARKER" ]] \
   && grep -qF "snapshot restore pre_restore_mock" "$DDEV_LOG" 2>/dev/null; then
    test_pass
else
    test_fail "automatic recovery did not clear marker: $CASE_OUT"
fi

test_start "failed automatic recovery preserves marker for orphan recovery"
run_case 1 1
if grep -qF "CMD_RC=1" <<<"$CASE_OUT" \
   && [[ -f "$MARKER" ]] \
   && grep -qF "pre_restore_mock" "$MARKER"; then
    test_pass
else
    test_fail "marker not preserved after failed recovery: $CASE_OUT"
fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
