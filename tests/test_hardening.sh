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

print_test_header "Unit Tests: Phase 2 hardening" "1.9.2"
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

test_start "redaction covers hyphen and underscore secret flags"
out="$(bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    dpx_redact_command_line --db_password=UnderScore \
        --db-password Hyphen --admin_pass=AdminSecret \
        --api_key ApiSecret --token TokenSecret
' _ "$DPX_ROOT" 2>&1 </dev/null)"
if grep -qF -- '--db_password=***' <<<"$out" \
    && grep -qF -- '--db-password ***' <<<"$out" \
    && grep -qF -- '--admin_pass=***' <<<"$out" \
    && grep -qF -- '--api_key ***' <<<"$out" \
    && grep -qF -- '--token ***' <<<"$out" \
    && ! grep -qE 'UnderScore|Hyphen|AdminSecret|ApiSecret|TokenSecret' <<<"$out"; then
    test_pass
else
    test_fail "underscore/hyphen secret leaked: $out"
fi

test_start "dpx_exec_and_log masks underscore secret flag values"
redact_underscore_project="$TEST_TEMP_DIR/redact_underscore"
mkdir -p "$redact_underscore_project"
bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    dpx_exec_and_log "$2" bash -c "exit 0" --db_password "underscore-secret" >/dev/null 2>&1
' _ "$DPX_ROOT" "$redact_underscore_project" </dev/null
redact_underscore_log="$redact_underscore_project/.dpx/debug.log"
if [[ -f "$redact_underscore_log" ]] \
    && grep -qF -- '--db_password ***' "$redact_underscore_log" \
    && ! grep -qF 'underscore-secret' "$redact_underscore_log"; then
    test_pass
else
    test_fail "underscore secret leaked into $redact_underscore_log"
fi

# =================================================================
# R-02 / R-05: MIGRATION ARGV + EXPORT PERMISSIONS
# =================================================================

echo ""
echo "${TEST_CYAN}=== Migration and export hardening ===${TEST_RESET}"

url_probe() {
    bash -c '
        export DPX_ROOT="$1" DPX_LANG=en NO_COLOR=1
        source "$DPX_ROOT/commands/migrate.sh" >/dev/null 2>&1
        _migrate_validate_url "$2" "URL" >/dev/null 2>&1
    ' _ "$DPX_ROOT" "$1" </dev/null 2>/dev/null
}

test_start "migration accepts absolute http(s) URLs"
if url_probe "https://old.example.test" && url_probe "http://old.example.test/path?x=1"; then
    test_pass
else
    test_fail "valid absolute URL was rejected"
fi

test_start "migration rejects non-absolute, option-like and empty URLs"
if ! url_probe "old.example.test" \
    && ! url_probe "ftp://old.example.test" \
    && ! url_probe "-https://old.example.test" \
    && ! url_probe ""; then
    test_pass
else
    test_fail "invalid URL passed validation"
fi

test_start "migration uses the argv-safe wrapper with parity flags"
if grep -qF "ddev_wp_search_replace \"\$old_url\" \"\$local_url\" \"\$ddev_path\"" \
        "$DPX_ROOT/commands/migrate.sh" \
    && grep -qF -- '--precise --skip-plugins --skip-themes' "$DPX_ROOT/commands/migrate.sh" \
    && ! grep -qF 'ddev exec "wp search-replace' "$DPX_ROOT/commands/migrate.sh" \
    && grep -qF 'Old URL and new URL must differ' "$DPX_ROOT/commands/migrate.sh"; then
    test_pass
else
    test_fail "migration still builds a shell command or misses validation"
fi

test_start "database exports are 0600 and their directory is 0700"
export_project="$TEST_TEMP_DIR/export_project"
export_dir="$TEST_TEMP_DIR/export_dir"
mkdir -p "$export_project"
bash -c '
    export DPX_ROOT="$1"
    source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
    source "$DPX_ROOT/lib/database.sh" >/dev/null 2>&1
    ddev() {
        local a
        for a in "$@"; do
            case "$a" in
                --file=*) printf "dump\n" > "${a#--file=}" ;;
            esac
        done
    }
    umask 022
    db_export "$2" "$3" false >/dev/null 2>&1
' _ "$DPX_ROOT" "$export_dir/dump.sql" "$export_project" </dev/null
export_mode="$(stat -c '%a' "$export_dir/dump.sql" 2>/dev/null || stat -f '%Lp' "$export_dir/dump.sql" 2>/dev/null)"
export_dir_mode="$(stat -c '%a' "$export_dir" 2>/dev/null || stat -f '%Lp' "$export_dir" 2>/dev/null)"
if [[ "$export_mode" == "600" && "$export_dir_mode" == "700" ]]; then
    test_pass
else
    test_fail "export mode=$export_mode dir_mode=$export_dir_mode"
fi

test_start "full backups enforce secure directory and archive modes"
if grep -qF "chmod 700 \"\$backup_dir\"" "$DPX_ROOT/lib/backup.sh" \
    && grep -qF "chmod 600 \"\$archive_file\"" "$DPX_ROOT/lib/backup.sh" \
    && grep -qF 'umask 077' "$DPX_ROOT/lib/backup.sh"; then
    test_pass
else
    test_fail "backup permission hardening missing"
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
    && grep -qF "\"\$locale\" \"\$db_user\" \"\$db_password\"" "$DPX_ROOT/commands/new.sh"; then
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
pull_count="$(grep -c "git -C \"\$script_dir\" pull origin main" "$DPX_ROOT/install.sh" || true)"
if [[ "$pull_count" -eq 1 ]]; then
    test_pass
else
    test_fail "expected 1 pull path, got $pull_count"
fi

test_start "shellcheck gate covers the complete shell surface"
ok=true
for target in \
    "\"\$TESTS_DIR\"/lib/*.sh" \
    "\"\$TESTS_DIR\"/commands/*.sh" \
    "\"\$TESTS_DIR\"/commands/site/*.sh" \
    "\"\$TESTS_DIR/dpx.sh\"" \
    "\"\$TESTS_DIR/install.sh\""; do
    if ! grep -qF "$target" "$DPX_ROOT/run_tests.sh"; then
        ok=false
    fi
done
if [[ "$ok" == true ]] \
    && grep -qF "for target in \"\${SHELLCHECK_TARGETS[@]}\"" "$DPX_ROOT/run_tests.sh"; then
    test_pass
else
    test_fail "gate target list or per-file loop missing"
fi

# =================================================================
# PHASE 4: GATE HONESTY, MIGRATE / SET-PHP / DB-RESTORE EDGE CASES
# =================================================================

echo ""
echo "${TEST_CYAN}=== Phase 4 audit edges ===${TEST_RESET}"

test_start "shellcheck gate parses JSON and self-tests SC2086"
if grep -qF 'shellcheck -s bash -S style -f json' "$DPX_ROOT/run_tests.sh" \
    && grep -qF '_shellcheck_gate_selftest' "$DPX_ROOT/run_tests.sh" \
    && grep -qF 'SHELLCHECK_NONBLOCKING_CODES=(1091 2329)' "$DPX_ROOT/run_tests.sh" \
    && grep -qF 'jq ' "$DPX_ROOT/run_tests.sh" \
    && ! grep -qF 'grep -vcE' "$DPX_ROOT/run_tests.sh"; then
    test_pass
else
    test_fail "gate still relies on non-JSON/note filtering"
fi

test_start "SC2086 remains actionable at info level"
if command -v shellcheck >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    sc_probe="$TEST_TEMP_DIR/sc2086_probe.sh"
    cat > "$sc_probe" <<'EOF'
#!/usr/bin/env bash
value="$1"
printf "%s\n" $value
EOF
    sc_json="$(shellcheck -s bash -S style -f json "$sc_probe" 2>/dev/null || true)"
    sc_count="$(jq '[.[] | select(.code == 2086)] | length' <<<"$sc_json" 2>/dev/null || echo 0)"
    if [[ "$sc_count" -gt 0 ]]; then
        test_pass
    else
        test_fail "seeded SC2086 was filtered out"
    fi
else
    test_skip "shellcheck or jq not available"
fi

mkdir -p "$TEST_TEMP_DIR/home_migrate"

migrate_env_probe() { # dir, absent|original, signal(0|1)
    local dir="$1" mode="$2" signal="${3:-0}"
    bash -c '
        export DPX_ROOT="$1" DPX_LANG=en NO_COLOR=1 HOME="$2"
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        source "$DPX_ROOT/commands/migrate.sh" >/dev/null 2>&1
        dir="$3"; mode="$4"; signal="$5"
        mkdir -p "$dir" || exit 9
        printf "variant\n" > "$dir/.env-7" || exit 9
        cp "$dir/.env-7" "$dir/.env" || exit 9
        _DPX_MIGRATE_ENV_DIR="$dir"
        _DPX_MIGRATE_ENV_PHP="7"
        _DPX_MIGRATE_ENV_SWAPPED=1
        _DPX_MIGRATE_ENV_PHP_SWAPPED=1
        if [[ "$mode" == "original" ]]; then
            printf "original\n" > "$dir/env.bak" || exit 9
            _DPX_MIGRATE_ENV_HAD_ORIGINAL=1
        else
            _DPX_MIGRATE_ENV_HAD_ORIGINAL=0
        fi
        if [[ "$signal" == "1" ]]; then
            trap "_migrate_env_interrupted INT" INT
            kill -INT $$
            echo "NOT_INTERRUPTED"
            exit 99
        fi
        _migrate_env_rollback >/dev/null 2>&1
        echo "RC=$?"
        [[ -e "$dir/.env" ]] && echo "ENV=$(cat "$dir/.env")" || echo "ENV=absent"
        [[ -e "$dir/.env-7" ]] && echo "VARIANT=$(cat "$dir/.env-7")" || echo "VARIANT=absent"
        [[ -e "$dir/env.bak" ]] && echo "BAK=present" || echo "BAK=absent"
    ' _ "$DPX_ROOT" "$TEST_TEMP_DIR/home_migrate" "$dir" "$mode" "$signal" 2>/dev/null
}

test_start "migrate rollback restores an originally absent .env"
out="$(migrate_env_probe "$TEST_TEMP_DIR/migrate_absent" absent 0)"
if grep -qF "RC=0" <<<"$out" \
    && grep -qF "ENV=absent" <<<"$out" \
    && grep -qF "VARIANT=variant" <<<"$out"; then
    test_pass
else
    test_fail "absent .env not restored: $out"
fi

test_start "migrate rollback restores the original .env"
out="$(migrate_env_probe "$TEST_TEMP_DIR/migrate_original" original 0)"
if grep -qF "RC=0" <<<"$out" \
    && grep -qF "ENV=original" <<<"$out" \
    && grep -qF "VARIANT=variant" <<<"$out" \
    && grep -qF "BAK=absent" <<<"$out"; then
    test_pass
else
    test_fail "original .env not restored: $out"
fi

test_start "migrate INT trap restores .env and exits 130"
migrate_env_probe "$TEST_TEMP_DIR/migrate_signal" absent 1 >/dev/null 2>&1
signal_rc=$?
if [[ "$signal_rc" -eq 130 && ! -e "$TEST_TEMP_DIR/migrate_signal/.env" ]] \
    && [[ -f "$TEST_TEMP_DIR/migrate_signal/.env-7" ]]; then
    test_pass
else
    test_fail "expected rc=130 and absent .env, got rc=$signal_rc"
fi

test_start "set-php validates project names before path derivation"
if grep -qF "validate_project_name \"\$project_name\"" "$DPX_ROOT/commands/set-php.sh" \
    && grep -qF "projects_exists \"\$project_name\"" "$DPX_ROOT/commands/set-php.sh" \
    && grep -qF "trap '_set_php_interrupted INT' INT" "$DPX_ROOT/commands/set-php.sh" \
    && grep -qF 'Continue WITHOUT a safety backup?' "$DPX_ROOT/commands/set-php.sh" \
    && grep -qF 'exit 130' "$DPX_ROOT/commands/set-php.sh"; then
    test_pass
else
    test_fail "set-php validation/trap/backup confirmation missing"
fi

test_start "set-php rejects unsafe project name at runtime"
mkdir -p "$TEST_TEMP_DIR/home_setphp"
out="$(
    DPX_ROOT="$DPX_ROOT" DPX_LANG=en NO_COLOR=1 HOME="$TEST_TEMP_DIR/home_setphp" \
        bash -c '
            source "$DPX_ROOT/commands/set-php.sh" >/dev/null 2>&1
            cmd_set_php "../escape"
        ' 2>&1
)"
setphp_rc=$?
if [[ "$setphp_rc" -ne 0 ]] && grep -qi 'lowercase' <<<"$out"; then
    test_pass
else
    test_fail "rc=$setphp_rc output=$out"
fi

test_start "db-restore has pre-import snapshot, traps and canonical paths"
if grep -qF "db_create_snapshot \"\$project_path\" \"pre_db_restore\"" "$DPX_ROOT/commands/db-restore.sh" \
    && grep -qF "trap '_dpx_db_restore_interrupted INT' INT" "$DPX_ROOT/commands/db-restore.sh" \
    && grep -qF 'exit 130' "$DPX_ROOT/commands/db-restore.sh" \
    && grep -qF "dpx_absolute_path \"\$selected_file\"" "$DPX_ROOT/commands/db-restore.sh"; then
    test_pass
else
    test_fail "db-restore snapshot/trap/path hardening missing"
fi

test_start "dpx_absolute_path resolves relative dump paths"
path_root="$TEST_TEMP_DIR/path_root"
mkdir -p "$path_root/sub"
: > "$path_root/sub/dump.sql"
out="$(
    bash -c '
        source "$DPX_ROOT/lib/core.sh" >/dev/null 2>&1
        cd "$2/sub" || exit 1
        dpx_absolute_path "dump.sql"
    ' _ "$DPX_ROOT" "$path_root" 2>/dev/null
)"
if [[ "$out" == "$path_root/sub/dump.sql" ]]; then
    test_pass
else
    test_fail "expected '$path_root/sub/dump.sql', got '$out'"
fi

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
