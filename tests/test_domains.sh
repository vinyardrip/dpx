#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: site/db domain routing, legacy aliases,
# 24h update-check TTL & banner.
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: tests require Bash 4.0+" >&2
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
    timeout 20 bash "$DPX_ROOT/dpx.sh" ${*} --help 2>/dev/null \
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
out="$(timeout 20 bash "$DPX_ROOT/dpx.sh" restore --help 2>/dev/null | grep -m1 -F 'Restore project from a full backup')"
if [[ -n "$out" ]]; then test_pass; else test_fail "no help output"; fi

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
if update_cache_expired "$CACHE"; then
    test_fail "fresh cache flagged expired"
else
    test_pass
fi

test_start "read_behind parses cached count"
check_value "0" "$(update_read_behind "$CACHE")"

# Banner unit: isolated child process, mocked git, forced display.
banner_probe() { # $1=behind  $2=force(0|1); rc propagated via if/capture
    export DPX_FORCE_BANNER="$2" FAKE_BEHIND="$1"
    # Isolated HOME: user-level dpx.conf must not leak into probes
    export HOME="$PROBE_HOME"
    bash -c '
        export DPX_ROOT="'"$DPX_ROOT"'" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/lib/core.sh" 2>/dev/null
        CACHE="'"$CACHE"'"
        git() { case "$*" in *rev-list*) echo "$FAKE_BEHIND";; *) return 0;; esac; }
        update_check_daily "$CACHE"
    '
}

set_stale_cache_with() { # $1 = behind count
    printf '%s\n%s\n' "$ts_old" "$1" > "$CACHE"
    touch -d "2 days ago" "$CACHE"
}

test_start "banner printed when behind > 0 (forced)"
set_stale_cache_with 3
out="$(banner_probe 3 1)"
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
# Version SSOT
# =================================================================

echo ""
echo "${TEST_CYAN}=== Version SSOT ===${TEST_RESET}"

test_start ".version equals 1.5.0"
check_value "1.5.0" "$(cat "$DPX_ROOT/.version")"

out="$(bash "$DPX_ROOT/dpx.sh" -v 2>&1)"
test_start "dpx -v reports v1.5.0"
if grep -qF "dpx v1.5.0" <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

ok=true
grep -qF "version-1.5.0-blue" "$DPX_ROOT/README.md"    || ok=false
grep -qF "version-1.5.0-blue" "$DPX_ROOT/README.ru.md" || ok=false
test_start "README badges show 1.5.0"
if [[ "$ok" == true ]]; then test_pass; else test_fail "badge missing"; fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
