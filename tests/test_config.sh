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

test_start "config_global_file points to ~/.config/dpx/config"
check_value "$FAKE_HOME/.config/dpx/config" "$(config_global_file)"

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

test_start "upsert creates a newline-terminated owner-only file"
rm -f "$(config_user_file)"
if config_upsert_kv "cli_lang" "en" \
   && [[ -z "$(tail -c 1 "$(config_user_file)")" ]] \
   && [[ "$(stat -c '%a' "$(config_user_file)" 2>/dev/null || stat -f '%Lp' "$(config_user_file)" 2>/dev/null)" == "600" ]] \
   && _parse_config_file "$(config_user_file)" \
   && [[ "$(get_config cli_lang)" == "en" ]]; then
    test_pass
else
    test_fail "new config file was not newline-terminated or is not 0600"
fi

test_start "upsert appends new key and preserves comments"
cat > "$(config_user_file)" << 'CONF'
# my manual comment
project_tld = lo
CONF
config_upsert_kv "default_tunnel_provider" "cloudflare"
if grep -qF "# my manual comment" "$(config_user_file)" \
   && grep -qF "default_tunnel_provider = cloudflare" "$(config_user_file)" \
   && [[ -z "$(tail -c 1 "$(config_user_file)")" ]]; then
    test_pass
else
    # shellcheck disable=SC2012  # diagnostic listing of tmp config
    test_fail "file: $(ls -l "$(config_user_file)" >/dev/null 2>&1; cat "$(config_user_file)" | tr '\n' '|')"
fi

test_start "upsert separates a new key from a file without trailing newline"
: > "$(config_user_file)"
printf 'project_tld = lo' > "$(config_user_file)"
if config_upsert_kv "default_tunnel_provider" "cloudflare" \
   && [[ -z "$(tail -c 1 "$(config_user_file)")" ]] \
   && _parse_config_file "$(config_user_file)" \
   && [[ "$(get_config project_tld)" == "lo" ]] \
   && [[ "$(get_config default_tunnel_provider)" == "cloudflare" ]]; then
    test_pass
else
    test_fail "append merged with the previous line"
fi

test_start "upsert leaves a trailing newline after updating the last line"
: > "$(config_user_file)"
printf 'project_tld = lo' > "$(config_user_file)"
if config_upsert_kv "project_tld" "lo3" \
   && [[ -z "$(tail -c 1 "$(config_user_file)")" ]] \
   && grep -qxF "project_tld = lo3" "$(config_user_file)"; then
    test_pass
else
    test_fail "updated file does not end with a newline"
fi

test_start "upsert updates an existing key in place without duplicates"
config_upsert_kv "project_tld" "lo2"
if grep -qxF "project_tld = lo2" "$(config_user_file)" \
   && ! grep -qxF "project_tld = lo" "$(config_user_file)" \
   && [[ "$(grep -cE '^[[:space:]]*project_tld[[:space:]]*=' "$(config_user_file)")" == "1" ]]; then
    test_pass
else
    test_fail "update failed or created a duplicate"
fi

test_start "upsert replaces an indented existing key without duplicating it"
: > "$(config_user_file)"
printf '   project_tld = lo\n' > "$(config_user_file)"
if config_upsert_kv "project_tld" "lo5" \
   && grep -qxF "project_tld = lo5" "$(config_user_file)" \
   && [[ "$(grep -cE '^[[:space:]]*project_tld[[:space:]]*=' "$(config_user_file)")" == "1" ]]; then
    test_pass
else
    test_fail "indented key was duplicated or mangled"
fi

test_start "upsert updates a legacy compact key with no trailing newline"
: > "$(config_user_file)"
printf '# legacy comment\ncli_lang=de' > "$(config_user_file)"
if config_upsert_kv "cli_lang" "en" \
   && [[ -z "$(tail -c 1 "$(config_user_file)")" ]] \
   && grep -qxF "cli_lang = en" "$(config_user_file)" \
   && grep -qF "# legacy comment" "$(config_user_file)" \
   && [[ "$(grep -cE '^[[:space:]]*cli_lang[[:space:]]*=' "$(config_user_file)")" == "1" ]]; then
    test_pass
else
    test_fail "legacy compact key was duplicated or merged"
fi

test_start "no duplicate keys after repeated upserts"
config_upsert_kv "cli_lang" "en"
config_upsert_kv "cli_lang" "ru"
count=$(grep -c '^cli_lang[[:space:]]*=' "$(config_user_file)")
check_value "1" "$count"

test_start "upsert collapses pre-existing duplicate keys"
printf '# duplicate regression fixture\ncli_lang = de\nproject_tld = lo\nunrelated = keep\ncli_lang = fr' \
    > "$(config_user_file)"
if config_upsert_kv "cli_lang" "en" \
   && [[ -z "$(tail -c 1 "$(config_user_file)")" ]] \
   && _parse_config_file "$(config_user_file)" \
   && [[ "$(get_config cli_lang)" == "en" ]] \
   && [[ "$(get_config project_tld)" == "lo" ]] \
   && [[ "$(get_config unrelated)" == "keep" ]] \
   && grep -qF "# duplicate regression fixture" "$(config_user_file)" \
   && [[ "$(grep -cE '^[[:space:]]*cli_lang[[:space:]]*=' "$(config_user_file)")" == "1" ]]; then
    test_pass
else
    test_fail "duplicate key was not collapsed: $(tr '\n' '|' < "$(config_user_file)")"
fi

test_start "global upsert uses the same duplicate-safe path"
global_file="$(config_global_file)"
mkdir -p "$(dirname "$global_file")"
printf 'DPX_PROJECTS_DIR = /one\nDPX_PROJECTS_DIR = /two\nother = keep\n' > "$global_file"
if config_upsert_global_kv "DPX_PROJECTS_DIR" "/new" \
   && grep -qxF "DPX_PROJECTS_DIR = /new" "$global_file" \
   && grep -qxF "other = keep" "$global_file" \
   && [[ "$(grep -cE '^[[:space:]]*DPX_PROJECTS_DIR[[:space:]]*=' "$global_file")" == "1" ]]; then
    test_pass
else
    test_fail "global duplicate key was not collapsed"
fi
rm -f "$global_file"

test_start "upsert survives sed metacharacters in value (|, &, \\)"
config_upsert_kv "db_password" 'p@ss|w&rd\x'
_parse_config_file "$(config_user_file)"
val="$(get_config db_password)"
if [[ "$val" == 'p@ss|w&rd\x' ]] \
   && config_upsert_kv "db_password" 'plain' \
   && _parse_config_file "$(config_user_file)" \
   && [[ "$(get_config db_password)" == 'plain' ]]; then
    test_pass
else
    test_fail "metacharacter value mangled: '$val'"
fi

test_start "upsert round-trips whitespace, hash, quotes and backslashes"
roundtrip_value='  leading # "double" '\''single'\'' \ slash  '
if config_upsert_kv "db_password" "$roundtrip_value" \
   && _parse_config_file "$(config_user_file)" \
   && [[ "$(get_config db_password)" == "$roundtrip_value" ]]; then
    test_pass
else
    test_fail "round-trip mismatch: $(grep -F 'db_password' "$(config_user_file)")"
fi

test_start "upsert rejects raw newline injection without adding keys"
if config_upsert_kv "db_password" $'safe\nadmin_pass = injected' 2>/dev/null; then
    test_fail "newline value accepted"
elif grep -qE '^admin_pass[[:space:]]*=' "$(config_user_file)"; then
    test_fail "newline value injected an admin_pass key"
elif [[ "$(get_config db_password)" != "$roundtrip_value" ]]; then
    test_fail "newline rejection modified the existing value"
else
    test_pass
fi

test_start "upsert rejects carriage-return values"
if config_upsert_kv "db_password" $'safe\rinjected' 2>/dev/null; then
    test_fail "carriage-return value accepted"
else
    test_pass
fi

test_start "upsert serializes an empty value explicitly"
if config_upsert_kv "empty_value" "" \
   && grep -qxF 'empty_value = ""' "$(config_user_file)" \
   && _parse_config_file "$(config_user_file)" \
   && [[ -z "$(get_config empty_value)" ]]; then
    test_pass
else
    test_fail "empty value was not serialized/parsed as empty"
fi

test_start "upsert rejects invalid config keys"
if config_upsert_kv $'bad\nkey' "value" 2>/dev/null; then
    test_fail "invalid key accepted"
else
    test_pass
fi

test_start "in-memory set_config rejects newline values"
if set_config "db_password" $'safe\ninjected' 2>/dev/null; then
    test_fail "newline accepted by set_config"
else
    test_pass
fi

test_start "parser rejects malformed quoted values before later keys"
cat > "$TEST_TEMP_DIR/malformed.conf" << 'CONF'
parser_broken = "unterminated
parser_injected = yes
CONF
if _parse_config_file "$TEST_TEMP_DIR/malformed.conf" 2>/dev/null; then
    test_fail "malformed quoted value accepted"
elif [[ -n "$(get_config parser_injected)" ]]; then
    test_fail "later assignment was injected after malformed quote"
else
    test_pass
fi

test_start "upsert returns 0 on success"
if config_upsert_kv "db_user" 'ok'; then
    test_pass
else
    test_fail "valid upsert reported failure"
fi

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

test_start "parser preserves equals signs in quoted values"
printf 'parser_equals = "value=123"\n' > "$TEST_TEMP_DIR/parser.conf"
_parse_config_file "$TEST_TEMP_DIR/parser.conf"
check_value "value=123" "$(get_config parser_equals)"

test_start "parser strips comments after quoted values"
printf 'parser_comment = "value" # trailing comment\n' > "$TEST_TEMP_DIR/parser.conf"
_parse_config_file "$TEST_TEMP_DIR/parser.conf"
check_value "value" "$(get_config parser_comment)"

test_start "parser preserves hash inside quoted values"
printf 'parser_hash = "value#123" # trailing comment\n' > "$TEST_TEMP_DIR/parser.conf"
_parse_config_file "$TEST_TEMP_DIR/parser.conf"
check_value "value#123" "$(get_config parser_hash)"

test_start "parser strips unquoted comments at the first marker"
printf 'parser_multi_comment = value # one # two\n' > "$TEST_TEMP_DIR/parser.conf"
_parse_config_file "$TEST_TEMP_DIR/parser.conf"
check_value "value" "$(get_config parser_multi_comment)"

test_start "parser treats a value-only hash as an empty value"
printf 'parser_only_comment = # just a comment\n' > "$TEST_TEMP_DIR/parser.conf"
_parse_config_file "$TEST_TEMP_DIR/parser.conf"
check_value "" "$(get_config parser_only_comment)"

test_start "parser trims unquoted values and inline comments"
printf 'parser_plain = value=123   # trailing comment\n' > "$TEST_TEMP_DIR/parser.conf"
_parse_config_file "$TEST_TEMP_DIR/parser.conf"
check_value "value=123" "$(get_config parser_plain)"

# =================================================================
# cmd_config: non-interactive flags
# =================================================================

echo ""
echo "${TEST_CYAN}=== cmd_config flag updates ===${TEST_RESET}"

rm -f "$(config_user_file)"
test_start "flags write managed keys and reload config"
cmd_config --projects-root "$FAKE_HOME/work/php" --provider cloudflare \
           --db-local-dir "$FAKE_HOME/work/db_local" \
           --db-prod-dir "$FAKE_HOME/work/db_prod" \
           --backup-dir "$FAKE_HOME/work/backups" \
           --db-user dbu1 --db-password dbp1 --lang en -y >/dev/null 2>&1
rc=$?
all_ok=true
[[ $rc -eq 0 ]] || all_ok=false
grep -qF "ddev_projects_base_path = $FAKE_HOME/work/php" "$(config_user_file)" || all_ok=false
grep -qF "default_tunnel_provider = cloudflare" "$(config_user_file)" || all_ok=false
grep -qF "db_user = dbu1" "$(config_user_file)"                 || all_ok=false
grep -qF "db_password = dbp1" "$(config_user_file)"             || all_ok=false
grep -qF "cli_lang = en" "$(config_user_file)"                  || all_ok=false
grep -qF "DPX_PROJECTS_DIR = $FAKE_HOME/work/php" "$(config_global_file)" || all_ok=false
grep -qF "DPX_DB_LOCAL_DIR = $FAKE_HOME/work/db_local" "$(config_global_file)" || all_ok=false
grep -qF "DPX_DB_PROD_DIR = $FAKE_HOME/work/db_prod" "$(config_global_file)" || all_ok=false
grep -qF "DPX_BACKUP_DIR = $FAKE_HOME/work/backups" "$(config_global_file)" || all_ok=false
if [[ "$all_ok" == true ]]; then test_pass; else test_fail "rc=$rc file=$(tr '\n' '|' < "$(config_user_file)")"; fi

test_start "global path getters resolve canonical DPX directories"
if [[ "$(get_ddev_projects_path)" == "$FAKE_HOME/work/php" \
   && "$(get_db_local_path)" == "$FAKE_HOME/work/db_local" \
   && "$(get_db_prod_path)" == "$FAKE_HOME/work/db_prod" \
   && "$(get_config full_backup_path)" == "$FAKE_HOME/work/backups" ]]; then
    test_pass
else
    test_fail "global path getters not synchronized"
fi

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
if grep -qF "$(config_global_file)" <<<"$out" \
   && grep -qF "$(config_user_file)" <<<"$out" \
   && grep -qF "default_tunnel_provider" <<<"$out"; then
    test_pass
else
    test_fail "show output incomplete"
fi

test_start "--show masks db_password and admin_pass"
# Values are read via list_config/cmd_config, not the array name itself.
set_config "db_password" "leaky-secret-42"
set_config "admin_pass"  "leaky-admin-pass"
out="$(cmd_config --show 2>&1)"
if grep -qF "db_password" <<<"$out" \
   && grep -qF "db_password                    = ********" <<<"$out" \
   && grep -qF "admin_pass                     = ********" <<<"$out" \
   && ! grep -qF "leaky-secret-42" <<<"$out" \
   && ! grep -qF "leaky-admin-pass" <<<"$out"; then
    test_pass
else
    test_fail "secrets not masked: $out"
fi

# =================================================================
# Interactive wizard via piped stdin
# =================================================================

echo ""
echo "${TEST_CYAN}=== interactive wizard ===${TEST_RESET}"

rm -f "$(config_user_file)"
rm -f "$(config_global_file)"
test_start "wizard writes global paths and application settings"
out="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$FAKE_HOME/projects-x" "$FAKE_HOME/db-local-x" "$FAKE_HOME/db-prod-x" \
        "$FAKE_HOME/backups-x" "ngrok" "myuser" "mypass" "ru" \
        | cmd_config force 2>&1)"
if [[ -f "$(config_user_file)" ]] \
   && grep -qF "ddev_projects_base_path = $FAKE_HOME/projects-x" "$(config_user_file)" \
   && grep -qF "db_user = myuser" "$(config_user_file)" \
   && grep -qF "cli_lang = ru" "$(config_user_file)" \
   && grep -qF "default_tunnel_provider = ngrok" "$(config_user_file)"; then
    if grep -qF "DPX_PROJECTS_DIR = $FAKE_HOME/projects-x" "$(config_global_file)" \
       && grep -qF "DPX_DB_LOCAL_DIR = $FAKE_HOME/db-local-x" "$(config_global_file)" \
       && grep -qF "DPX_DB_PROD_DIR = $FAKE_HOME/db-prod-x" "$(config_global_file)" \
       && grep -qF "DPX_BACKUP_DIR = $FAKE_HOME/backups-x" "$(config_global_file)"; then
        test_pass
    else
        test_fail "global config missing paths"
    fi
else
    test_fail "conf: $(tr '\n' '|' < "$(config_user_file)" 2>/dev/null)"
fi

test_start "first run prefers cloudflare when only cloudflared is installed"
rm -f "$(config_user_file)"
rm -f "$(config_global_file)"
smart_bin="$TEST_TEMP_DIR/smart-bin"
mkdir -p "$smart_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$smart_bin/cloudflared"
chmod +x "$smart_bin/cloudflared"
out="$(printf '%s\n\n\n\n\n%s\n%s\n%s\n' \
        "$FAKE_HOME/projects-smart" "db" "db" "en" \
        | PATH="$smart_bin:/usr/bin:/bin" config_run_wizard force 2>&1)"
if grep -qF "default_tunnel_provider = cloudflare" "$(config_user_file)"; then
    test_pass
else
    test_fail "smart default not applied: $out"
fi

test_start "first-run hint in non-interactive session (stdin closed)"
rm -f "$(config_user_file)"
rm -f "$(config_global_file)"
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

test_start "load_config immediately synchronizes configured language"
config_upsert_kv "cli_lang" "ru"
DPX_LANG=""
_DPX_LANG="en"
load_config
check_value "Шаг" "$(t lbl.step)"

test_start "load_config re-secures a legacy 0644 user config"
printf 'db_password = legacy-secret\n' >> "$(config_user_file)"
chmod 644 "$(config_user_file)"
load_config
mode="$(stat -c '%a' "$(config_user_file)" 2>/dev/null || stat -f '%Lp' "$(config_user_file)" 2>/dev/null)"
check_value "600" "$mode"

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
config_routes="$(grep -cE '^[[:space:]]*list\|.*\|config\|.*\)' "$DPX_ROOT/dpx.sh")"
if (( config_routes >= 2 )); then
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
