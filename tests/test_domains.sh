#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: site/db domain routing, legacy aliases,
# 24h update-check TTL & banner.
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: tests require Bash 4.0+">&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: domain routing + update check" "1.0.0"
setup_temp_dir >/dev/null
PROBE_HOME="$TEST_TEMP_DIR/probehome"
mkdir -p "$PROBE_HOME/.config/dpx"

export DPX_LANG="en"
source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/lib/domain_map.sh"

CACHE="$TEST_TEMP_DIR/.update_cache"
ts_fresh="$(date +%s)"
ts_old="$(date -d '2 days ago' +%s)"

check_value() {
    if [[ "$1" == "$2" ]]; then test_pass; else test_fail "expected '$1', got '$2'"; fi
}

check_marker() {
    if grep -qF -- "$1" <<<"$2"; then test_pass; else test_fail "marker '$1' missing"; fi
}

# =================================================================
# Domain resolution table
# =================================================================

echo ""
echo "${TEST_CYAN}=== domain_resolve ===${TEST_RESET}"

test_start "db domain maps to canonical commands"
all_ok=true
[[ "$(domain_resolve db pull)" == "refresh" ]]       || all_ok=false
[[ "$(domain_resolve db push)" == "to-prod" ]]       || all_ok=false
[[ "$(domain_resolve db snap)" == "db-snap" ]]       || all_ok=false
[[ "$(domain_resolve db restore)" == "db-restore" ]] || all_ok=false
if [[ "$all_ok" == true ]]; then
    test_pass
else
    test_fail "db mapping broken"
fi

test_start "site domain maps to canonical commands"
all_ok=true
[[ "$(domain_resolve site new)" == "new" ]]         || all_ok=false
[[ "$(domain_resolve site backup)" == "backup" ]]   || all_ok=false
[[ "$(domain_resolve site restore)" == "restore" ]] || all_ok=false
[[ "$(domain_resolve site migrate)" == "migrate" ]] || all_ok=false
[[ "$(domain_resolve site deploy)" == "deploy" ]]   || all_ok=false
if [[ "$all_ok" == true ]]; then
    test_pass
else
    test_fail "site mapping broken"
fi

test_start "unknown domain/subcommand rejected"
if domain_resolve db frobnicate >/dev/null 2>&1; then
    test_fail "unknown pair accepted"
else
    test_pass
fi

# =================================================================
# [Stage 3 / P-2] Unknown subcommands must print usage, not die silently
# =================================================================

echo ""
echo "${TEST_CYAN}=== unknown subcommand usage output (P-2) ===${TEST_RESET}"

test_start "dpx db <unknown> prints error + db usage"
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" db import </dev/null 2>&1)"
rc=$?
if [[ $rc -ne 0 ]] \
   && grep -qF "Unknown db subcommand: import" <<<"$out" \
   && grep -qF "pull" <<<"$out" && grep -qF "snap" <<<"$out"; then
    test_pass
else
    test_fail "rc=$rc out=$out"
fi

test_start "dpx site <unknown> prints error + site usage"
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" site frobnicate </dev/null 2>&1)"
rc=$?
if [[ $rc -ne 0 ]] \
   && grep -qF "Unknown site subcommand: frobnicate" <<<"$out" \
   && grep -qF "backup" <<<"$out" && grep -qF "migrate" <<<"$out"; then
    test_pass
else
    test_fail "rc=$rc out=$out"
fi

test_start "dpx db (no sub) prints usage"
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" db </dev/null 2>&1)"
if grep -qF "pull" <<<"$out" && grep -qF "push" <<<"$out"; then
    test_pass
else
    test_fail "no usage: $out"
fi

test_start "valid subcommands still resolve (db pull)"
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" db pull --help </dev/null 2>&1 | head -1)"
if [[ -n "$out" ]]; then
    test_pass
else
    test_fail "db pull --help empty"
fi

test_start "file-path override points site/restore at nested layout"
out="$(domain_command_file restore)"
if [[ "$out" == *"/commands/site/restore.sh" ]]; then
    test_pass
else
    test_fail "got: $out"
fi

# =================================================================
# Legacy alias e2e: --help output identical to canonical command
# =================================================================

echo ""
echo "${TEST_CYAN}=== legacy alias e2e (--help) ===${TEST_RESET}"

# shellcheck disable=SC2048,SC2086  # word splitting of "db pull" is the intent
first_help_line() {
    # word splitting intentional
# shellcheck disable=SC2086
    timeout 20 bash "$DPX_ROOT/dpx.sh" ${*} --help </dev/null 2>/dev/null \
        | grep -m1 -F ' - '
}

for pair in "db pull:refresh" "db push:to-prod" "db snap:db-snap" \
            "db restore:db-restore" "site new:new" "site backup:backup" \
            "site migrate:migrate" "site deploy:deploy"; do
    new_cmd="${pair%%:*}"
    old_cmd="${pair##*:}"
    test_start "alias parity: dpx ${new_cmd} == dpx ${old_cmd}"
    # word splitting intentional: "db pull" -> two CLI words
    # shellcheck disable=SC2086
    if [[ "$(first_help_line ${new_cmd})" == "$(first_help_line ${old_cmd})" ]] \
       && [[ -n "$(first_help_line ${new_cmd})" ]]; then
        test_pass
    else
        # shellcheck disable=SC2086
        test_fail "'$(first_help_line ${new_cmd})' vs '$(first_help_line ${old_cmd})'"
    fi
done

test_start "legacy dpx restore -> site restore help"
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" restore --help </dev/null 2>/dev/null | grep -m1 -F 'Restore project from a full backup')"
if [[ -n "$out" ]]; then test_pass; else test_fail "no help output"; fi

# =================================================================
# E2E dispatch: dpx restore must reach the handler, not "not found"
# =================================================================

echo ""
echo "${TEST_CYAN}=== restore execution dispatch (e2e) ===${TEST_RESET}"

# The router resolves cmd_restore in commands/site/restore.sh. Prove the
# full chain (domain_resolve -> file override -> source -> declare -f)
# without touching any real project: verify inside an isolated bash that
# sources exactly what dpx.sh sources, in the same order.
restore_dispatch_probe() {
    bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        cmd_file="$DPX_ROOT/commands/restore.sh"
        [[ -f "$cmd_file" ]] || cmd_file="$(domain_command_file restore)"
        if [[ ! -f "$cmd_file" ]]; then
            echo "NO_FILE"; exit 1
        fi
        if ! bash -n "$cmd_file" 2>/dev/null; then
            echo "SYNTAX_FAIL"; exit 1
        fi
        # shellcheck disable=SC1090
        source "$cmd_file" >/dev/null 2>&1
        if declare -f cmd_restore >/dev/null; then
            echo "CMD_RESTORE_OK"
        else
            echo "MISSING_cmd_restore"
        fi
    ' </dev/null 2>/dev/null
}

restore_dispatch_probe_alias() {
    bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        cmd_file="$DPX_ROOT/commands/restore.sh"
        [[ -f "$cmd_file" ]] || cmd_file="$(domain_command_file restore)"
        # shellcheck disable=SC1090
        source "$cmd_file" >/dev/null 2>&1
        if declare -f cmd_site_restore >/dev/null; then
            echo "CMD_SITE_RESTORE_OK"
        else
            echo "MISSING_cmd_site_restore"
        fi
    ' </dev/null 2>/dev/null
}

test_start "dpx restore dispatch resolves cmd_restore (router contract)"
out="$(restore_dispatch_probe)"
check_value "CMD_RESTORE_OK" "$out"

test_start "dpx restore dispatch resolves cmd_site_restore (alias intact)"
out="$(restore_dispatch_probe_alias)"
check_value "CMD_SITE_RESTORE_OK" "$out"

test_start "live dpx restore dispatches (no 'not found' error)"
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" restore </dev/null 2>&1 | grep -cF 'Function cmd_restore not found')"
check_value "0" "$out"

# --- tar-slip guard: unsafe members must be rejected ---
tar_slip_probe() { # $1 = archive; echoes SAFE/UNSAFE
    local archive="$1"
    bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        source "$DPX_ROOT/commands/site/restore.sh" >/dev/null 2>&1
        if _restore_archive_is_safe "$1" >/dev/null 2>&1; then
            echo SAFE
        else
            echo UNSAFE
        fi
    ' _ "$archive" </dev/null 2>/dev/null
}

SLIP_DIR="$TEST_TEMP_DIR/tarslip"
mkdir -p "$SLIP_DIR/good"
echo ok > "$SLIP_DIR/good/ok.txt"
tar -czf "$SLIP_DIR/good.tar.gz" -C "$SLIP_DIR/good" ok.txt

python3 - "$SLIP_DIR" << 'PYEOF' 2>/dev/null || true
import tarfile, sys, io
tmp = sys.argv[1]
with tarfile.open(tmp + "/slip.tar.gz", "w:gz") as tf:
    data = b"pwned"
    ti = tarfile.TarInfo("../../../dpx_slip_target/pwned.txt")
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))

# Link NAME is harmless; TARGET escapes the extraction root.
with tarfile.open(tmp + "/symlink-escape.tar.gz", "w:gz") as tf:
    ti = tarfile.TarInfo("project/link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "../../etc/passwd"
    tf.addfile(ti)

# Internal symlink must remain accepted.
with tarfile.open(tmp + "/symlink-safe.tar.gz", "w:gz") as tf:
    ti = tarfile.TarInfo("project/uploads/file.txt")
    data = b"ok"
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
    link = tarfile.TarInfo("project/link")
    link.type = tarfile.SYMTYPE
    link.linkname = "uploads/file.txt"
    tf.addfile(link)
PYEOF

test_start "tar-slip guard rejects ../ members"
if [[ -f "$SLIP_DIR/slip.tar.gz" ]]; then
    check_value "UNSAFE" "$(tar_slip_probe "$SLIP_DIR/slip.tar.gz")"
else
    test_fail "python3 unavailable to craft slip archive"
fi

test_start "tar-slip guard rejects symlink targets outside root"
if [[ -f "$SLIP_DIR/symlink-escape.tar.gz" ]]; then
    check_value "UNSAFE" "$(tar_slip_probe "$SLIP_DIR/symlink-escape.tar.gz")"
else
    test_fail "python3 unavailable to craft symlink archive"
fi

test_start "tar-slip guard accepts internal symlinks"
if [[ -f "$SLIP_DIR/symlink-safe.tar.gz" ]]; then
    check_value "SAFE" "$(tar_slip_probe "$SLIP_DIR/symlink-safe.tar.gz")"
else
    test_fail "python3 unavailable to craft symlink archive"
fi

test_start "tar-slip guard accepts clean archives"
check_value "SAFE" "$(tar_slip_probe "$SLIP_DIR/good.tar.gz")"

# =================================================================
# [Stage 4 / D-5] E2E dispatch: every routed command must expose its
# router-derived entry function (cmd_<name>) AND its help function.
# The router executes cmd_${command//-/_}; a missing entry is the class
# of regression that once broke `dpx restore` entirely.
# =================================================================

echo ""
echo "${TEST_CYAN}=== e2e dispatch matrix (all routed commands) ===${TEST_RESET}"

ROUTED_COMMANDS=(
    list edit set-php deploy to-prod db-snap db-restore new-wp
    new refresh migrate ddev tunnel update info backup config
    restore clean
)

dispatch_probe() { # $1 = canonical command; echoes verdict
    local command="$1"
    bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        command="'"$command"'"
        cmd_file="$DPX_ROOT/commands/${command}.sh"
        [[ -f "$cmd_file" ]] || cmd_file="$(domain_command_file "$command")"
        if [[ ! -f "$cmd_file" ]]; then
            echo "NO_FILE"; exit 1
        fi
        if ! bash -n "$cmd_file" 2>/dev/null; then
            echo "SYNTAX_FAIL"; exit 1
        fi
        # shellcheck disable=SC1090
        source "$cmd_file" >/dev/null 2>&1
        func_name="cmd_${command//-/_}"
        help_func="show_${command//-/_}_help"
        have_cmd=0; have_help=0
        declare -f "$func_name" >/dev/null && have_cmd=1
        declare -f "$help_func" >/dev/null && have_help=1
        echo "CMD=$have_cmd HELP=$have_help"
    ' </dev/null 2>/dev/null
}

all_ok=true
bad=""
for c in "${ROUTED_COMMANDS[@]}"; do
    verdict="$(dispatch_probe "$c")"
    if [[ "$verdict" != "CMD=1 HELP=1" ]]; then
        all_ok=false
        bad+="${c}(${verdict}) "
    fi
done
test_start "all $((${#ROUTED_COMMANDS[@]})) routed commands expose cmd_* and help"
if [[ "$all_ok" == true ]]; then
    test_pass
else
    test_fail "bad: $bad"
fi

# Live dispatch smoke: the full dpx.sh chain (router -> source -> declare -f)
# must never print "Function ... not found" for any routed command. The
# commands exit early in non-interactive envs, which is fine — the assertion
# is about the dispatch error specifically.
live_dispatch_errors=0
for c in "${ROUTED_COMMANDS[@]}"; do
    out="$(timeout 25 bash "$DPX_ROOT/dpx.sh" "$c" </dev/null 2>&1 | grep -cF 'Function cmd_')"
    live_dispatch_errors=$((live_dispatch_errors + out))
done
test_start "live dispatch: zero 'Function ... not found' across the matrix"
check_value "0" "$live_dispatch_errors"

# =================================================================
# Update check: TTL logic + banner (mocked git)
# =================================================================

echo ""
echo "${TEST_CYAN}=== update_check_daily ===${TEST_RESET}"

test_start "expired when cache missing"
if update_cache_expired "$CACHE"; then test_pass; else test_fail "expected expired"; fi

printf '%s\n3\n' "$ts_old" > "$CACHE"
test_start "expired when older than TTL"
if update_cache_expired "$CACHE"; then test_pass; else test_fail "expected expired"; fi

printf '%s\n0\n' "$ts_fresh" > "$CACHE"
test_start "fresh cache is not expired"
if update_cache_expired "$CACHE"; then
    test_fail "fresh cache flagged expired"
else
    test_pass
fi

test_start "read_behind parses cached count"
check_value "0" "$(update_read_behind "$CACHE")"

# Banner unit: isolated child process, mocked git, forced display.
banner_probe() { # $1=behind  $2=force(0|1); rc propagated via if/capture
    export DPX_FORCE_BANNER="$2" FAKE_BEHIND="$1" \
        FAKE_LOCAL_VERSION=1.6.0 FAKE_REMOTE_VERSION=1.8.0
    # Isolated HOME: user-level dpx.conf must not leak into probes
    export HOME="$PROBE_HOME"
    bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" 2>/dev/null
        CACHE="'"$CACHE"'"
        git() {
            case "$*" in
                *rev-list*)
                    # Model the remote release explicitly: 1.8.0 is newer
                    # than the checked-out 1.6.0 and therefore has commits.
                    [[ "$FAKE_REMOTE_VERSION" != "$FAKE_LOCAL_VERSION" ]] \
                        && echo "$FAKE_BEHIND" || echo 0
                    ;;
                *) return 0 ;;
            esac
        }
        update_check_daily "$CACHE"
    ' </dev/null
}

set_stale_cache_with() { # $1 = behind count
    printf '%s\n%s\n' "$ts_old" "$1"> "$CACHE"
    touch -d "2 days ago" "$CACHE"
}

test_start "banner printed when behind > 0 (forced)"
set_stale_cache_with 3
out="$(banner_probe 3 1 2>&1)"
check_marker "DPX update available! Run 'dpx update' to apply (${DPX_VERSION})" "$out"

test_start "rc=10 signals update availability to caller"
set_stale_cache_with 3
if banner_probe 3 1 >/dev/null 2>&1; then
    test_fail "expected rc=10"
else
    rc10=$?
    check_value "10" "$rc10"
fi

test_start "no banner when behind == 0"
set_stale_cache_with 0
out="$(DPX_FORCE_BANNER=1 banner_probe 0 1)"
if grep -qF "update available" <<<"$out"; then
    test_fail "unexpected banner: $out"
else
    test_pass
fi

test_start "auto_update_check=false (user config) suppresses everything"
printf 'auto_update_check = false\n' > "$PROBE_HOME/.config/dpx/dpx.conf"
set_stale_cache_with 5
out="$(DPX_FORCE_BANNER=1 banner_probe 5 1)"
if grep -qF "update available" <<<"$out"; then
    test_fail "shown despite opt-out"
else
    test_pass
fi
# shellcheck disable=SC2034
DEFAULT_CONFIG["auto_update_check"]="true"

test_start "cache refreshed after check (TTL restarts)"
rm -f "$PROBE_HOME/.config/dpx/dpx.conf"
set_stale_cache_with 5
DPX_FORCE_BANNER=1 banner_probe 0 1 >/dev/null 2>&1
if update_cache_expired "$CACHE"; then
    test_fail "cache not refreshed"
else
    test_pass
fi

# =================================================================
# Orphaned tunnel snapshot recovery
# =================================================================

echo ""
echo "${TEST_CYAN}=== orphaned snapshot recovery ===${TEST_RESET}"

ORPHAN_PROJECT="$TEST_TEMP_DIR/orphan-project"
ORPHAN_LOG="$TEST_TEMP_DIR/orphan-ddev.log"
mkdir -p "$ORPHAN_PROJECT/.dpx/subdir"
printf 'dpx-tunnel-before-123\n' > "$ORPHAN_PROJECT/.dpx/current_snapshot"

test_start "orphan finder walks up from a project subdirectory"
out="$(cd "$ORPHAN_PROJECT/.dpx/subdir" && dpx_find_orphaned_snapshot)"
check_value "$ORPHAN_PROJECT" "$out"

test_start "non-interactive recovery logs and preserves orphan state"
out="$(cd "$ORPHAN_PROJECT" && check_orphaned_snapshot </dev/null 2>&1)"
if [[ -f "$ORPHAN_PROJECT/.dpx/current_snapshot" ]] \
   && grep -qF "previous session terminated abruptly" <<<"$out"; then
    test_pass
else
    test_fail "marker removed or recovery message missing: $out"
fi

test_start "snapshot restore uses recorded name and cleans orphan state"
ddev() { printf 'ddev %s\n' "$*" >> "$ORPHAN_LOG"; return 0; }
dpx_restore_orphaned_snapshot "$ORPHAN_PROJECT" "dpx-tunnel-before-123" >/dev/null 2>&1
if [[ ! -f "$ORPHAN_PROJECT/.dpx/current_snapshot" ]] \
   && grep -qxF "ddev snapshot restore dpx-tunnel-before-123" "$ORPHAN_LOG"; then
    test_pass
else
    test_fail "restore command or cleanup missing"
fi
unset -f ddev

# =================================================================
# Version SSOT
# =================================================================

echo ""
echo "${TEST_CYAN}=== Version SSOT ===${TEST_RESET}"

test_start ".version equals 1.8.2"
check_value "1.8.2" "$(cat "$DPX_ROOT/.version")"

out="$(bash "$DPX_ROOT/dpx.sh" -v </dev/null 2>&1)"
test_start "dpx -v reports v1.8.2"
if grep -qF "dpx v1.8.2" <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

ok=true
    grep -qF "version-1.8.2-blue" "$DPX_ROOT/README.md"    || ok=false
    grep -qF "version-1.8.2-blue" "$DPX_ROOT/README.ru.md" || ok=false
test_start "README badges show 1.8.2"
if [[ "$ok" == true ]]; then test_pass; else test_fail "badge missing"; fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
