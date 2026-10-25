#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: universal `dpx new` command
#
# Covers: permission types, interactive menu, wrapper new-wp,
# routing dpx.sh, normalization docroot, .env-rewriter (include
# BSD-simulation), resolver archive URL and protective checks cmd_new.
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Tests require Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: dpx new (universal scaffolding)" "1.0.0"
setup_temp_dir >/dev/null

source "$DPX_ROOT/lib/core.sh"
# Expanding projects in isolated director test
# shellcheck disable=SC2034
DEFAULT_CONFIG["ddev_projects_base_path"]="$TEST_TEMP_DIR/ws"
PROJECTS_ROOT="$TEST_TEMP_DIR/ws"
mkdir -p "$PROJECTS_ROOT"

source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/args.sh"
source "$DPX_ROOT/lib/database.sh"

# shellcheck disable=SC1091
source "$DPX_ROOT/commands/new.sh"

check_value() { # $1 expected, $2 actual
    if [[ "$1" == "$2" ]]; then
        test_pass
    else
        test_fail "expected '$1', got '$2'"
    fi
}

check_marker() { # $1 marker, $2 haystack
    if grep -qF -- "$1" <<<"$2"; then
        test_pass
    else
        test_fail "marker '$1' missing"
    fi
}

# =================================================================
# SECTION A: new_resolve_type
# =================================================================

echo ""
echo "${TEST_CYAN}=== new_resolve_type ===${TEST_RESET}"

test_start "numbers 1..6 map to canonical types"
all_ok=true
[[ "$(new_resolve_type 1)" == "wordpress" ]] || all_ok=false
[[ "$(new_resolve_type 2)" == "joomla" ]]     || all_ok=false
[[ "$(new_resolve_type 3)" == "opencart" ]]   || all_ok=false
[[ "$(new_resolve_type 4)" == "ocstore" ]]    || all_ok=false
[[ "$(new_resolve_type 5)" == "laravel" ]]    || all_ok=false
[[ "$(new_resolve_type 6)" == "php" ]]        || all_ok=false
if [[ "$all_ok" == true ]]; then test_pass; else test_fail "number mapping broken"; fi

test_start "aliases: wp/lara/oc/ocs/html/static"
all_ok=true
[[ "$(new_resolve_type wp)" == "wordpress" ]]    || all_ok=false
[[ "$(new_resolve_type lara)" == "laravel" ]]    || all_ok=false
[[ "$(new_resolve_type oc)" == "opencart" ]]     || all_ok=false
[[ "$(new_resolve_type ocs)" == "ocstore" ]]     || all_ok=false
[[ "$(new_resolve_type html)" == "php" ]]        || all_ok=false
[[ "$(new_resolve_type static)" == "php" ]]      || all_ok=false
if [[ "$all_ok" == true ]]; then test_pass; else test_fail "alias mapping broken"; fi

test_start "case and surrounding spaces normalized"
check_value "laravel" "$(new_resolve_type "  LARAVEL  ")"

test_start "ocStore mixed-case normalized"
check_value "ocstore" "$(new_resolve_type " OcStore ")"

test_start "unknown input -> empty"
check_value "" "$(new_resolve_type drupal)"

test_start "empty input -> empty (triggers interactive menu upstream)"
check_value "" "$(new_resolve_type "")"

# =================================================================
# SECTION B: new_select_type (interactive menu)
# =================================================================

echo ""
echo "${TEST_CYAN}=== new_select_type ===${TEST_RESET}"

test_start "menu renders to stderr, value to stdout"
out="$(printf '3\n' | new_select_type 2>/dev/null)"
check_value "opencart" "$out"

# Note: read -p shows prompt only on TTY; in pipe mode
# verify itself items menu.
err="$(printf '4\n' | new_select_type 2>&1 >/dev/null)"
test_start "menu visible on stderr (numbered list, ocStore included)"
if grep -qF "1) WordPress" <<<"$err" \
   && grep -qF "3) OpenCart (Official)" <<<"$err" \
   && grep -qF "4) ocStore (OpenCart Russia/SEO Pro)" <<<"$err" \
   && grep -qF "5) Laravel" <<<"$err" \
   && grep -qF "6) Plain PHP / HTML" <<<"$err"; then
    test_pass
else
    test_fail "menu content missing on stderr"
fi

test_start "garbage then valid number -> retried and resolved"
check_value "laravel" "$(printf 'drupal\n5\n' | new_select_type 2>/dev/null)"

test_start "EOF without valid input -> error rc=1"
rc=0
printf '' | new_select_type >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then test_pass; else test_fail "rc=$rc"; fi

# =================================================================
# SECTION C: new-wp wrapper passthrough
# =================================================================

echo ""
echo "${TEST_CYAN}=== new-wp backward-compat wrapper ===${TEST_RESET}"

# Wrapper detects cmd_new_wp (engine already loaded above)
# shellcheck disable=SC1091
source "$DPX_ROOT/commands/new-wp.sh"

# Mock universal engine UNTIL call cmd_new_wp
CMD_NEW_ARGS=""
cmd_new() { CMD_NEW_ARGS="$*"; }

test_start "delegates with appended --cms=wordpress"
cmd_new_wp mysite -y
check_value "mysite -y --cms=wordpress" "$CMD_NEW_ARGS"

test_start "explicit --cms is not overridden by wrapper"
cmd_new_wp --cms=joomla other
if grep -qF -- "--cms=joomla" <<<"$CMD_NEW_ARGS" && ! grep -qF "wordpress" <<<"$CMD_NEW_ARGS"; then
    test_pass
else
    test_fail "args: $CMD_NEW_ARGS"
fi

test_start "=form --cms also suppresses append"
cmd_new_wp --type=laravel zzz
if grep -qF -- "--type=laravel" <<<"$CMD_NEW_ARGS" && ! grep -qF "wordpress" <<<"$CMD_NEW_ARGS"; then
    test_pass
else
    test_fail "args: $CMD_NEW_ARGS"
fi

test_start "show_new_wp_help delegates to universal help"
out="$(show_new_wp_help 2>&1)"
if grep -qF "Universal project scaffolding" <<<"$out" \
   && grep -qF "compatibility" <<<"$out"; then
    test_pass
else
    test_fail "help delegation broken"
fi

test_start "wrapper preserves additional WP-specific flags"
cmd_new_wp --admin-email dev@ex.com --no-theme
if grep -qF -- "--no-theme" <<<"$CMD_NEW_ARGS" && grep -qF -- "--cms=wordpress" <<<"$CMD_NEW_ARGS"; then
    test_pass
else
    test_fail "args: $CMD_NEW_ARGS"
fi

# [FIX] Snapshot mock: return REAL engine for subsequent section
unset -f cmd_new
# shellcheck disable=SC1091
source "$DPX_ROOT/commands/new.sh"

# =================================================================
# SECTION D: router wiring (dpx.sh)
# =================================================================

echo ""
echo "${TEST_CYAN}=== router registration ===${TEST_RESET}"

test_start "'new' registered in run_command dispatch"
if grep -qE '^[[:space:]]*list\|.*\|new\|.*\)' "$DPX_ROOT/dpx.sh"; then
    test_pass
else
    test_fail "router list missing 'new'"
fi

test_start "'new' in help-router list (--help interception)"
new_routes="$(grep -cE '^[[:space:]]*list\|.*\|new\|.*\)' "$DPX_ROOT/dpx.sh")"
if (( new_routes >= 2 )); then
    test_pass
else
    test_fail "help-router list missing 'new'"
fi

test_start "commands/new.sh present and defines cmd_new"
if [[ -f "$DPX_ROOT/commands/new.sh" ]] && grep -qF "cmd_new()" "$DPX_ROOT/commands/new.sh"; then
    test_pass
else
    test_fail "engine missing"
fi

# =================================================================
# SECTION E: _new_normalize_docroot
# =================================================================

echo ""
echo "${TEST_CYAN}=== docroot normalization ===${TEST_RESET}"

test_start "flat layout (index.php at root) left untouched"
d="$TEST_TEMP_DIR/flat"; mkdir -p "$d/sys"; echo "<?php" > "$d/index.php"
_new_normalize_docroot "$d"
if [[ -f "$d/index.php" && -d "$d/sys" ]]; then
    test_pass
else
    test_fail "flat layout mutated"
fi

test_start "single wrapped subdir (upload/) flattened (OpenCart style)"
d="$TEST_TEMP_DIR/wrapped"; mkdir -p "$d/upload/system"; echo "<?php" > "$d/upload/index.php"
_new_normalize_docroot "$d"
if [[ -f "$d/index.php" && -d "$d/system" && ! -d "$d/upload" ]]; then
    test_pass
else
    # shellcheck disable=SC2012  # diagnostic output content tmp-directory
    test_fail "flatten failed: $(ls -A "$d" 2>/dev/null | tr '\n' ' ')"
fi

test_start "ambiguous top-level (files+dirs) -> no destructive move"
d="$TEST_TEMP_DIR/ambig"; mkdir -p "$d/one" "$d/two"; echo x > "$d/readme.txt"
_new_normalize_docroot "$d"
if [[ -f "$d/readme.txt" && -d "$d/one" && -d "$d/two" ]]; then
    test_pass
else
    test_fail "ambiguous layout mutated"
fi

# =================================================================
# SECTION F: _new_env_set_kv / Laravel .env rewriting
# =================================================================

echo ""
echo "${TEST_CYAN}=== .env rewriting ===${TEST_RESET}"

make_env_fixture() {
    cat > "$1" << 'ENVEOF'
APP_NAME=Laravel
APP_ENV=production
APP_URL=https://old.example.com
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=laravel
DB_USERNAME=root
DB_PASSWORD=
ENVEOF
}

test_start "_new_env_set_kv replaces existing key"
env_f="$TEST_TEMP_DIR/env1"; make_env_fixture "$env_f"
_new_env_set_kv "$env_f" "DB_HOST" "db"
if grep -qF "DB_HOST=db" "$env_f" && ! grep -qF "127.0.0.1" "$env_f"; then
    test_pass
else
    test_fail "replace failed"
fi

test_start "_new_env_set_kv appends missing key"
env_f="$TEST_TEMP_DIR/env2"; make_env_fixture "$env_f"
_new_env_set_kv "$env_f" "SESSION_DRIVER" "database"
if grep -qF "SESSION_DRIVER=database" "$env_f"; then
    test_pass
else
    test_fail "append failed"
fi

test_start "_new_env_set_kv escapes sed replacement metacharacters"
env_f="$TEST_TEMP_DIR/env_meta"; make_env_fixture "$env_f"
meta_value='https://shop.test/path?x=1&y=2|part\slug'
_new_env_set_kv "$env_f" "APP_URL" "$meta_value"
if grep -qxF "APP_URL=${meta_value}" "$env_f"; then
    test_pass
else
    test_fail "sed metacharacters corrupted .env: $(grep -F 'APP_URL=' "$env_f")"
fi

test_start "full Laravel rewrite: DB_* -> DDEV + APP_URL"
env_f="$TEST_TEMP_DIR/env3"; make_env_fixture "$env_f"
_new_laravel_env_rewrite "$env_f" "https://shop.lo"
all_ok=true
grep -qF "DB_HOST=db" "$env_f"          || all_ok=false
grep -qF "DB_DATABASE=db" "$env_f"      || all_ok=false
grep -qF "DB_USERNAME=db" "$env_f"      || all_ok=false
grep -qx "DB_PASSWORD=db" "$env_f"      || all_ok=false
grep -qF "APP_URL=https://shop.lo" "$env_f" || all_ok=false
grep -qF "APP_ENV=local" "$env_f"       || all_ok=false
if [[ "$all_ok" == true ]]; then test_pass; else test_fail ".env content wrong"; fi

test_start "[darwin] .env rewrite under BSD sed"
scen="$TEST_TEMP_DIR/scen_env.sh"
cat > "$scen" << 'EOF'
export OSTYPE=darwin23
source "$DPX_ROOT/lib/paths.sh"
source "$DPX_ROOT/lib/io.sh"
source "$DPX_ROOT/lib/utils.sh"
source "$DPX_ROOT/commands/new.sh"
env_file="$1"
_new_laravel_env_rewrite "$env_file" "https://bsd.lo"
grep -cF "=db" "$env_file"
EOF
SHIM_BIN_ENV="$TEST_TEMP_DIR/bin_env"; mkdir -p "$SHIM_BIN_ENV"
cat > "$SHIM_BIN_ENV/sed" << 'EOF'
#!/usr/bin/env bash
REAL_SED="${DPX_REAL_SED:-/usr/bin/sed}"
args=(); inplace=""; seen_i=0
while [[ $# -gt 0 ]]; do
    a="$1"; shift
    case "$a" in
        --*) exit 1 ;;
        -i)  seen_i=1; inplace="$1"; shift ;;
        -i*) exit 1 ;;
        *)   args+=("$a") ;;
    esac
done
if [[ $seen_i -eq 1 ]]; then
    exec "$REAL_SED" "--in-place${inplace:+=$inplace}" "${args[@]}"
fi
exec "$REAL_SED" "${args[@]}"
EOF
chmod +x "$SHIM_BIN_ENV/sed"
env_f="$TEST_TEMP_DIR/env_bsd"; make_env_fixture "$env_f"
# Isolation environment in subprocess scenario intentional
out="$(
    (
        # shellcheck disable=SC2030
        export PATH="$SHIM_BIN_ENV:$PATH"
        exec "${BASH}" "$scen" "$env_f"
    ) 2>&1
)"
last_line="$(tail -1 <<<"$out")"
check_value "4" "$last_line"

# =================================================================
# SECTION G: resolver archive URL (mocked GitHub API)
# =================================================================

echo ""
echo "${TEST_CYAN}=== archive URL resolver (mocked network) ===${TEST_RESET}"

GH_WITH_ASSET='{"assets":[{"name":"Joomla_5.2.0-Stable-Full_Package.tar.gz","browser_download_url":"https://github.com/Joomla/Joomla-CMS/releases/download/5.2.0/Joomla_5.2.0-Stable-Full_Package.tar.gz"}]}'
GH_NO_ASSET='{"assets":[]}'

MOCK_BIN="$TEST_TEMP_DIR/mockbin"; mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s' "${FAKE_GH_PAYLOAD:-}"
EOF
chmod +x "$MOCK_BIN/curl"

run_with_mock_curl() {
    # shellcheck disable=SC2030,SC2031
    (
        export PATH="$MOCK_BIN:$PATH"
        export FAKE_GH_PAYLOAD="$1"
        shift
        _new_resolve_archive_url "$@"
    )
}

test_start "joomla: release asset matched via GitHub API"
out="$(unset DPX_JOOMLA_ARCHIVE_URL; run_with_mock_curl "$GH_WITH_ASSET" joomla)"
check_value "https://github.com/Joomla/Joomla-CMS/releases/download/5.2.0/Joomla_5.2.0-Stable-Full_Package.tar.gz" "$out"

test_start "env override short-circuits network"
out="$(DPX_JOOMLA_ARCHIVE_URL="https://mirror.example/j.tar.gz" run_with_mock_curl "$GH_NO_ASSET" joomla)"
check_value "https://mirror.example/j.tar.gz" "$out"

test_start "no asset -> codeload source fallback with warning"
out="$(unset DPX_OPENCART_ARCHIVE_URL; FAKE_NGROK_UNUSED=1 run_with_mock_curl "$GH_NO_ASSET" opencart 2>"$TEST_TEMP_DIR/resolver.err")"
if grep -qF "refs/heads/master.zip" <<<"$out" && grep -qiF "source" "$TEST_TEMP_DIR/resolver.err"; then
    test_pass
else
    test_fail "out='$out'"
fi

test_start "unknown cms type -> failure"
run_with_mock_curl '{}' magento >/dev/null 2>&1
rc_unknown=$?
if [[ "$rc_unknown" -ne 0 ]]; then test_pass; else test_fail "expected rc!=0"; fi

test_start "opencart zip asset matched"
gh_oc='{"assets":[{"name":"opencart-4.2.0.zip","browser_download_url":"https://github.com/opencart/opencart/releases/download/4.2.0/opencart-4.2.0.zip"}]}'
out="$(unset DPX_OPENCART_ARCHIVE_URL; run_with_mock_curl "$gh_oc" opencart)"
check_value "https://github.com/opencart/opencart/releases/download/4.2.0/opencart-4.2.0.zip" "$out"

test_start "ocstore: release asset matched via GitHub API"
gh_ocs='{"assets":[{"name":"ocstore-3.0.2.4.zip","browser_download_url":"https://github.com/myopencart/ocstore/releases/download/3.0.2.4/ocstore-3.0.2.4.zip"}]}'
out="$(unset DPX_OCSTORE_ARCHIVE_URL; run_with_mock_curl "$gh_ocs" ocstore)"
check_value "https://github.com/myopencart/ocstore/releases/download/3.0.2.4/ocstore-3.0.2.4.zip" "$out"

test_start "ocstore: env override short-circuits network"
out="$(DPX_OCSTORE_ARCHIVE_URL="https://mirror.example/ocs.zip" run_with_mock_curl "$GH_NO_ASSET" ocstore)"
check_value "https://mirror.example/ocs.zip" "$out"

test_start "[ocstore] db_get_db_name reads DB_DATABASE (OpenCart-compatible config)"
ocs_fix="$TEST_TEMP_DIR/ocstore_site"
mkdir -p "$ocs_fix"
cat > "$ocs_fix/config.php" << 'PHPEOF'
<?php
define('DB_HOSTNAME', 'localhost');
define('DB_DATABASE', 'ocstore_base');
PHPEOF
check_value "ocstore_base" "$(db_get_db_name "$ocs_fix" ocstore)"

test_start "[ocstore] dispatch wired into archive scaffold case"
if grep -qF 'joomla|opencart|ocstore)' "$DPX_ROOT/commands/new.sh"; then
    test_pass
else
    test_fail "dispatch missing ocstore"
fi

# =================================================================
# SECTION H: protective checks cmd_new (offline)
# =================================================================

echo ""
echo "${TEST_CYAN}=== cmd_new guards ===${TEST_RESET}"

test_start "existing target directory -> clean abort before scaffolding"
mkdir -p "$PROJECTS_ROOT/existingsite"
cmd_new existingsite --cms=php -y >/dev/null 2>&1
rc_guard=$?
if [[ "$rc_guard" -ne 0 ]] && [[ -d "$PROJECTS_ROOT/existingsite" ]]; then
    test_pass
else
    test_fail "rc=$rc_guard"
fi

test_start "invalid project name rejected"
cmd_new "Bad_Name!" --cms=php -y >/dev/null 2>&1
rc_bad=$?
if [[ "$rc_bad" -ne 0 ]]; then test_pass; else test_fail "invalid name accepted"; fi

# =================================================================
# SUMMARIES
# =================================================================

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
