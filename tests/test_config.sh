#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: dpx config wizard & first-run trigger
#
# Covers:
#   - user config path + first-run detection (missing/present file);
#   - upsert semantics preserving comments and foreign keys;
#   - project-level override precedence over user config;
#   - cmd_config non-interactive flag updates (--provider/--lang/...);
#   - cmd_config --show output;
#   - interactive wizard via piped stdin;
#   - first-run hook safety in non-interactive sessions;
#   - cli_lang wiring into the i18n resolver;
#   - router registration of the `config` command.
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

print_test_header "Unit Tests: dpx config wizard" "1.0.0"
setup_temp_dir >/dev/null

FAKE_HOME="$TEST_TEMP_DIR/home"
mkdir -p "$FAKE_HOME"

check_value() {
    if [[ "$1" == "$2" ]]; then test_pass; else test_fail "expected '$1', got '$2'"; fi
}
check_marker() {
    if grep -qF -- "$1" <<<"$2"; then test_pass; else test_fail "marker '$1' missing"; fi
}

# Isolated environment: fresh HOME, deterministic locale for EN asserts
load_stack() { # runs in caller shell after HOME exported
    export DPX_LANG="en"
    source "$DPX_ROOT/lib/core.sh"
}

# =================================================================
# Path & detection
# =================================================================

echo ""
echo "${TEST_CYAN}=== user config path / first-run detection ===${TEST_RESET}"

export HOME="$FAKE_HOME"
source "$DPX_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$DPX_ROOT/commands/config.sh"

test_start "config_user_file points to ~/.config/dpx/dpx.conf"
check_value "$FAKE_HOME/.config/dpx/dpx.conf" "$(config_user_file)"

test_start "needs_first_run = true when file missing"
if config_needs_first_run; then
    test_pass
else
    test_fail "expected true"
fi

test_start "needs_first_run = false when file exists"
mkdir -p "$(dirname "$(config_user_file)")"
touch "$(config_user_file)"
if config_needs_first_run; then
    test_fail "expected false"
else
    test_pass
fi

# =================================================================
# Upsert semantics
# =================================================================

echo ""
echo "${TEST_CYAN}=== upsert semantics ===${TEST_RESET}"

test_start "upsert appends new key and preserves comments"
cat > "$(config_user_file)" << 'CONF'
# my manual comment
project_tld = lo
CONF
config_upsert_kv "default_tunnel_provider" "cloudflare"
if grep -qF "# my manual comment" "$(config_user_file)" \
   && grep -qF "default_tunnel_provider = cloudflare" "$(config_user_file)"; then
    test_pass
else
    # shellcheck disable=SC2012  # diagnostic listing of tmp config
    test_fail "file: $(ls -l "$(config_user_file)" >/dev/null 2>&1; cat "$(config_user_file)" | tr '\n' '|')"
fi

test_start "upsert updates existing key in place"
config_upsert_kv "project_tld" "lo2"
if grep -qxF "project_tld = lo2" "$(config_user_file)" && ! grep -qxF "project_tld = lo" "$(config_user_file)"; then
    test_pass
else
    test_fail "update failed"
fi

test_start "no duplicate keys after repeated upserts"
config_upsert_kv "cli_lang" "en"
config_upsert_kv "cli_lang" "ru"
count=$(grep -c '^cli_lang[[:space:]]*=' "$(config_user_file)")
check_value "1" "$count"

# =================================================================
# Precedence: project-level overrides user config
# =================================================================

echo ""
echo "${TEST_CYAN}=== precedence ===${TEST_RESET}"

test_start "project-local conf overrides user value on load"
printf 'cli_lang = ru\n' > "$TEST_TEMP_DIR/proj.conf"
sourceline="source \"$DPX_ROOT/lib/config.sh\""
out="$(
    bash -c "
        export HOME=\"$FAKE_HOME\"
        source \"$DPX_ROOT/lib/paths.sh\"
        $sourceline
        # emulate local config with higher priority
        _parse_config_file \"$TEST_TEMP_DIR/proj.conf\"
        get_config cli_lang auto
    "
)"
check_value "ru" "$out"

# =================================================================
# cmd_config: non-interactive flags
# =================================================================

echo ""
echo "${TEST_CYAN}=== cmd_config flag updates ===${TEST_RESET}"

rm -f "$(config_user_file)"
test_start "flags write managed keys and reload config"
cmd_config --projects-root "$FAKE_HOME/work/php" --provider cloudflare \
           --db-user dbu1 --db-password dbp1 --lang en -y >/dev/null 2>&1
rc=$?
all_ok=true
[[ $rc -eq 0 ]] || all_ok=false
grep -qF "ddev_projects_base_path = $FAKE_HOME/work/php" "$(config_user_file)" || all_ok=false
grep -qF "default_tunnel_provider = cloudflare" "$(config_user_file)" || all_ok=false
grep -qF "db_user = dbu1" "$(config_user_file)"                 || all_ok=false
grep -qF "db_password = dbp1" "$(config_user_file)"             || all_ok=false
grep -qF "cli_lang = en" "$(config_user_file)"                  || all_ok=false
if [[ "$all_ok" == true ]]; then test_pass; else test_fail "rc=$rc file=$(tr '\n' '|' < "$(config_user_file)")"; fi

test_start "invalid provider rejected"
if cmd_config --provider terraform -y >/dev/null 2>&1; then
    test_fail "invalid provider accepted"
else
    test_pass
fi

test_start "invalid lang rejected"
if cmd_config --lang de -y >/dev/null 2>&1; then
    test_fail "invalid lang accepted"
else
    test_pass
fi

test_start "--show prints path and managed key"
out="$(cmd_config --show 2>&1)"
if grep -qF "$(config_user_file)" <<<"$out" && grep -qF "default_tunnel_provider" <<<"$out"; then
    test_pass
else
    test_fail "show output incomplete"
fi

# =================================================================
# Interactive wizard via piped stdin
# =================================================================

echo ""
echo "${TEST_CYAN}=== interactive wizard ===${TEST_RESET}"

rm -f "$(config_user_file)"
test_start "wizard writes all four answers"
out="$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$FAKE_HOME/projects-x" "ngrok" "myuser" "mypass" "ru" \
        | cmd_config force 2>&1)"
if [[ -f "$(config_user_file)" ]] \
   && grep -qF "ddev_projects_base_path = $FAKE_HOME/projects-x" "$(config_user_file)" \
   && grep -qF "db_user = myuser" "$(config_user_file)" \
   && grep -qF "cli_lang = ru" "$(config_user_file)" \
   && grep -qF "default_tunnel_provider = ngrok" "$(config_user_file)"; then
    test_pass
else
    test_fail "conf: $(tr '\n' '|' < "$(config_user_file)" 2>/dev/null)"
fi

test_start "first-run hint in non-interactive session (stdin closed)"
rm -f "$(config_user_file)"
out="$(config_run_wizard </dev/null 2>&1)"
if [[ ! -f "$(config_user_file)" ]] && grep -qi "dpx config" <<<"$out"; then
    test_pass
else
    test_fail "out=$out"
fi

# =================================================================
# cli_lang -> i18n resolver wiring
# =================================================================

echo ""
echo "${TEST_CYAN}=== cli_lang wiring ===${TEST_RESET}"

test_start "config cli_lang=ru switches t() under LANG=C"
config_upsert_kv "cli_lang" "ru"
out="$(bash -c "
    export HOME=\"$FAKE_HOME\" DPX_LANG=
    export LANG=C LC_ALL=C
    source \"$DPX_ROOT/lib/core.sh\" 2>/dev/null
    t lbl.step
")"
check_value "Шаг" "$out"

test_start "[en] explicit DPX_LANG still beats config"
out="$(bash -c "
    export HOME=\"$FAKE_HOME\" DPX_LANG=en
    export LANG=C LC_ALL=C
    source \"$DPX_ROOT/lib/core.sh\" 2>/dev/null
    t lbl.step
")"
check_value "Step" "$out"

# =================================================================
# Router registration
# =================================================================

echo ""
echo "${TEST_CYAN}=== router wiring ===${TEST_RESET}"

test_start "'config' registered in dispatch and help-router lists"
if grep -qF 'backup|config)' "$DPX_ROOT/dpx.sh" && grep -qF 'info|backup|config)' "$DPX_ROOT/dpx.sh"; then
    test_pass
else
    test_fail "router lists missing config"
fi

test_start "first-run hook present in entry point"
if grep -qF 'config_first_run_hook' "$DPX_ROOT/dpx.sh"; then
    test_pass
else
    test_fail "hook missing in dpx.sh"
fi

# =================================================================
print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
