#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: Phase 2 hardening
#
# Covers:
#   - removal of the dead /etc/hosts helpers;
#   - secret redaction in project debug logs;
#   - configured WordPress database credentials;
#   - strict help routing for commands and domain groups;
#   - search-replace parity flags in deploy/refresh;
#   - de-duplicated installer update path;
#   - expanded per-file shellcheck gate.
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Tests require Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# shellcheck source=test_framework.sh
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: Phase 2 hardening" "1.9.0"
setup_temp_dir >/dev/null

run_cli() {
    DPX_LANG=en NO_COLOR=1 DPX_SESSION_LOG_DIR="$TEST_TEMP_DIR/session" \
        bash "$DPX_ROOT/dpx.sh" "$@" </dev/null 2>&1
}

# =================================================================
# DEAD /ETC/HOSTS MODULE
# =================================================================

echo ""
echo "${TEST_CYAN}=== Dead /etc/hosts module ===${TEST_RESET}"

test_start "hosts helpers removed from lib/sudo.sh"
ok=true
if grep -qE 'dpx_hosts_(add|remove)' "$DPX_ROOT/lib/sudo.sh"; then
    ok=false
fi
if [[ "$ok" == true ]]; then
    test_pass
else
    test_fail "hosts helper still present"
fi

test_start "hosts helper references removed from documentation"
ok=true
for doc in README.md README.ru.md; do
    if grep -qE 'dpx_hosts_(add|remove)' "$DPX_ROOT/$doc"; then
        ok=false
    fi
done
if [[ "$ok" == true ]]; then
    test_pass
else
    test_fail "stale hosts helper reference remains"
fi

# =================================================================
# DEBUG LOG REDACTION
# =================================================================

echo ""
echo "${TEST_CYAN}=== Debug log redaction ===${TEST_RESET}"

test_start "dpx_exec_and_log masks secret flag values"
redact_project="$TEST_TEMP_DIR/redact_project"
mkdir -p "$redact_project"
bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    dpx_exec_and_log "$2" bash -c "exit 0" --db-password "topsecret" >/dev/null 2>&1
' _ "$DPX_ROOT" "$redact_project" </dev/null
redact_log="$redact_project/.dpx/debug.log"
if [[ -f "$redact_log" ]] \
    && grep -qF -- '--db-password ***' "$redact_log" \
    && ! grep -qF 'topsecret' "$redact_log"; then
    test_pass
else
    test_fail "secret argv leaked into $redact_log"
fi

# =================================================================
# WORDPRESS DATABASE CREDENTIALS
# =================================================================

echo ""
echo "${TEST_CYAN}=== WordPress DB credentials ===${TEST_RESET}"

test_start "ddev_wp_install honors explicit DB credentials"
wp_project="$TEST_TEMP_DIR/wp_project"
mkdir -p "$wp_project"
out="$(bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/ddev.sh" >/dev/null 2>&1
    ddev() { printf "ddev %s\n" "$*"; }
    ddev_wp_install "$2" "https://example.test" "Title" "admin" "adminpass" \
        "admin@example.test" "en_US" "cfg_user" "s3cret pass"
' _ "$DPX_ROOT" "$wp_project" 2>&1 </dev/null)"
wp_rc=$?
if [[ $wp_rc -eq 0 ]] \
    && grep -qF -- '--dbuser=cfg_user' <<<"$out" \
    && grep -qF -- '--dbpass=s3cret pass' <<<"$out"; then
    test_pass
else
    test_fail "configured credentials missing (rc=$wp_rc): $out"
fi

test_start "ddev_wp_install falls back to configured DB credentials"
out="$(bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/ddev.sh" >/dev/null 2>&1
    get_config() {
        case "$1" in
            db_user) printf "%s\n" "fallback_user" ;;
            db_password) printf "%s\n" "fallback_pass" ;;
            *) return 1 ;;
        esac
    }
    ddev() { printf "ddev %s\n" "$*"; }
    ddev_wp_install "$2" "https://example.test" "Title" "admin" "adminpass" \
        "admin@example.test" "en_US"
' _ "$DPX_ROOT" "$wp_project" 2>&1 </dev/null)"
wp_rc=$?
if [[ $wp_rc -eq 0 ]] \
    && grep -qF -- '--dbuser=fallback_user' <<<"$out" \
    && grep -qF -- '--dbpass=fallback_pass' <<<"$out"; then
    test_pass
else
    test_fail "config fallback missing (rc=$wp_rc): $out"
fi

test_start "new command passes configured credentials to installer"
if grep -qF "db_user=\$(get_config 'db_user' 'db')" "$DPX_ROOT/commands/new.sh" \
    && grep -qF "db_password=\$(get_config 'db_password' 'db')" "$DPX_ROOT/commands/new.sh" \
    && grep -qF '"$locale" "$db_user" "$db_password"' "$DPX_ROOT/commands/new.sh"; then
    test_pass
else
    test_fail "new.sh does not pass DB credentials"
fi

# =================================================================
# SEARCH-REPLACE PARITY
# =================================================================

echo ""
echo "${TEST_CYAN}=== Search-replace parity ===${TEST_RESET}"

test_start "ddev_wp_search_replace forwards extra flags"
sr_project="$TEST_TEMP_DIR/sr_project"
mkdir -p "$sr_project"
out="$(bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/ddev.sh" >/dev/null 2>&1
    ddev() { printf "%s\n" "$*"; }
    ddev_wp_search_replace "https://old.test" "https://new.test" "$2" \
        --precise --skip-plugins --skip-themes
' _ "$DPX_ROOT" "$sr_project" 2>&1 </dev/null)"
sr_rc=$?
if [[ $sr_rc -eq 0 ]] \
    && grep -qF -- '--precise --skip-plugins --skip-themes' <<<"$out"; then
    test_pass
else
    test_fail "flags not forwarded (rc=$sr_rc): $out"
fi

test_start "deploy and refresh request parity flags"
if grep -qF -- '--precise --skip-plugins --skip-themes' "$DPX_ROOT/commands/deploy.sh" \
    && grep -qF -- '--precise --skip-plugins --skip-themes' "$DPX_ROOT/commands/refresh.sh"; then
    test_pass
else
    test_fail "deploy/refresh call site missing parity flags"
fi

# =================================================================
# STRICT HELP ROUTING
# =================================================================

echo ""
echo "${TEST_CYAN}=== Strict help routing ===${TEST_RESET}"

test_start "dpx db --help exits 0 with domain usage"
out="$(run_cli db --help)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"db subcommands"* && "$out" != *"Unknown"* ]]; then
    test_pass
else
    test_fail "rc=$rc output=$out"
fi

test_start "dpx site -h exits 0 with domain usage"
out="$(run_cli site -h)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"site subcommands"* && "$out" != *"Unknown"* ]]; then
    test_pass
else
    test_fail "rc=$rc output=$out"
fi

test_start "dpx db pull --help still shows canonical command help"
out="$(run_cli db pull --help)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"refresh"* ]]; then
    test_pass
else
    test_fail "rc=$rc output=$out"
fi

test_start "unknown command help exits 64"
out="$(run_cli frobnicate --help)"
rc=$?
if [[ $rc -eq 64 && "$out" == *"No help available"* ]]; then
    test_pass
else
    test_fail "rc=$rc output=$out"
fi

test_start "missing help function exits 64 without executing command"
fake_root="$TEST_TEMP_DIR/fake_root"
mkdir -p "$fake_root" "$TEST_TEMP_DIR/fake_home" "$TEST_TEMP_DIR/fake_log"
cp -R "$DPX_ROOT/lib" "$DPX_ROOT/commands" "$fake_root/"
cp "$DPX_ROOT/dpx.sh" "$DPX_ROOT/.version" "$fake_root/"
sed 's/^show_clean_help() {/show_clean_help_removed() {/' \
    "$fake_root/commands/clean.sh" > "$fake_root/commands/clean.tmp"
mv "$fake_root/commands/clean.tmp" "$fake_root/commands/clean.sh"
out="$(DPX_LANG=en NO_COLOR=1 HOME="$TEST_TEMP_DIR/fake_home" \
    DPX_SESSION_LOG_DIR="$TEST_TEMP_DIR/fake_log" \
    bash "$fake_root/dpx.sh" clean --help </dev/null 2>&1)"
rc=$?
if [[ $rc -eq 64 && "$out" == *"Help function show_clean_help not found"* ]]; then
    test_pass
else
    test_fail "rc=$rc output=$out"
fi

# =================================================================
# INSTALLER + SHELLCHECK GATE
# =================================================================

echo ""
echo "${TEST_CYAN}=== Installer and shellcheck gate ===${TEST_RESET}"

test_start "installer has one git pull update path"
pull_count="$(grep -c 'git -C "$script_dir" pull origin main' "$DPX_ROOT/install.sh" || true)"
if [[ "$pull_count" -eq 1 ]]; then
    test_pass
else
    test_fail "expected 1 pull path, got $pull_count"
fi

test_start "shellcheck gate covers the complete shell surface"
ok=true
for target in \
    '"$TESTS_DIR"/lib/*.sh' \
    '"$TESTS_DIR"/commands/*.sh' \
    '"$TESTS_DIR"/commands/site/*.sh' \
    '"$TESTS_DIR/dpx.sh"' \
    '"$TESTS_DIR/install.sh"'; do
    if ! grep -qF "$target" "$DPX_ROOT/run_tests.sh"; then
        ok=false
    fi
done
if [[ "$ok" == true ]] \
    && grep -qF 'for target in "${SHELLCHECK_TARGETS[@]}"' "$DPX_ROOT/run_tests.sh"; then
    test_pass
else
    test_fail "gate target list or per-file loop missing"
fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
