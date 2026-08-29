#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: Tunnel Patches (Nginx/Smart-Tunnel) + DB Name Detection
#
# Covers:
#   - Nginx Hot-Patch: absolute_redirect/port_in_redirect + forwarded
#     headers (Host, X-Forwarded-Proto) — content generated script;
#   - DPX_SMART_TUNNEL PHP-block: conditional HTTPS by X-Forwarded-Proto;
#   - db_get_db_name(): dynamic extract nameds DATABASE from configs
#     WordPress/Joomla/OpenCart + fallback-behavior;
#   - Portability extract under simulation BSD sed (darwin).
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

print_test_header "Unit Tests: Tunnel Patches + DB Detection" "1.0.0"
setup_temp_dir >/dev/null

FIXTURES="$TEST_TEMP_DIR/fixtures"
mkdir -p "$FIXTURES"

# =================================================================
# FIXTURES CONFIGS CMS
# =================================================================

mkdir -p "$FIXTURES/wp_classic" "$FIXTURES/wp_spaced" "$FIXTURES/wp_nodbname" \
         "$FIXTURES/joomla_site" "$FIXTURES/opencart_site" "$FIXTURES/plain_site" \
         "$FIXTURES/wp_badname"

cat > "$FIXTURES/wp_classic/wp-config.php" << 'PHPEOF'
<?php
define( 'DB_NAME', 'wp_mysite' );
define( 'DB_USER', 'db' );
$table_prefix = 'wp_';
PHPEOF

cat > "$FIXTURES/wp_spaced/wp-config.php" << 'PHPEOF'
<?php
define("DB_NAME",   "shop_prod_db");
define( 'DB_USER', "db" );
PHPEOF

# Config without DB_NAME (Bedrock-style): must fired WP-CLI fallback,
# which outside environment DDEV soft return emptiness.
cat > "$FIXTURES/wp_nodbname/wp-config.php" << 'PHPEOF'
<?php
require __DIR__ . '/vendor/autoload.php';
PHPEOF

cat > "$FIXTURES/joomla_site/configuration.php" << 'PHPEOF'
<?php
class JConfig {
    public $host = 'localhost';
    public $db   = 'joom_base';
}
PHPEOF

cat > "$FIXTURES/opencart_site/config.php" << 'PHPEOF'
<?php
define('DB_HOSTNAME', 'localhost');
define('DB_DATABASE', 'oc_base');
PHPEOF

echo "<?php echo 'hi';" > "$FIXTURES/plain_site/index.php"

cat > "$FIXTURES/wp_badname/wp-config.php" << 'PHPEOF'
<?php
define('DB_NAME', 'bad name;drop table');
PHPEOF

# =================================================================
# DOWNLOAD MODULE (linux-profile)
# =================================================================

source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/database.sh"
# shellcheck disable=SC1091
source "$DPX_ROOT/commands/tunnel.sh"

# Helper: marker consumes -> pass
check_marker() { # $1 marker, $2 haystack
    if grep -qF -- "$1" <<<"$2"; then
        test_pass
    else
        test_fail "marker '$1' missing; got: $2"
    fi
}

# Helper: value matched -> pass (one calls source data)
check_value() { # $1 expected, $2 actual
    if [[ "$1" == "$2" ]]; then
        test_pass
    else
        test_fail "expected '$1', got '$2'"
    fi
}

# =================================================================
# SECTION A: db_get_db_name and identifier validation (native Linux)
# =================================================================

echo ""
echo "${TEST_CYAN}=== db_get_db_name: extraction ===${TEST_RESET}"

test_start "WordPress classic: define( 'DB_NAME', '...' )"
check_value "wp_mysite" "$(db_get_db_name "$FIXTURES/wp_classic" wordpress)"

test_start "WordPress spaced: define(\"DB_NAME\",   \"...\")"
check_value "shop_prod_db" "$(db_get_db_name "$FIXTURES/wp_spaced" wordpress)"

test_start "Joomla: public \$db = '...'"
check_value "joom_base" "$(db_get_db_name "$FIXTURES/joomla_site" joomla)"

test_start "OpenCart: define('DB_DATABASE', '...')"
check_value "oc_base" "$(db_get_db_name "$FIXTURES/opencart_site" opencart)"

test_start "CMS type autodetect (wp-config.php present)"
check_value "wp_mysite" "$(db_get_db_name "$FIXTURES/wp_classic" "")"

test_start "Plain PHP project: empty result"
result="$(db_get_db_name "$FIXTURES/plain_site" php)"
if [[ -z "$result" ]]; then
    test_pass
else
    test_fail "got: '$result'"
fi

test_start "Invalid DB name rejected before command execution"
err_file="$TEST_TEMP_DIR/err.log"
if result="$(db_get_db_name "$FIXTURES/wp_badname" wordpress 2>"$err_file")"; then
    test_fail "invalid database name accepted"
elif [[ -z "$result" ]] && grep -qiF "invalid database name" "$err_file"; then
    test_pass
else
    test_fail "result='$result' stderr=$(cat "$err_file")"
fi

test_start "Database identifier validator rejects hyphens and SQL metacharacters"
if db_validate_identifier "bad-name" "database name" >/dev/null 2>&1 \
   || db_validate_identifier 'bad;DROP_TABLE' "database name" >/dev/null 2>&1; then
    test_fail "unsafe identifier accepted"
else
    test_pass
fi

test_start "Database identifier validator accepts alnum underscore"
if db_validate_identifier "safe_DB_123" "database name" >/dev/null 2>&1; then
    test_pass
else
    test_fail "safe identifier rejected"
fi

test_start "SQL literal escaping doubles quotes and backslashes"
check_value "O''Reilly\\\\site" "$(db_escape_sql_literal "O'Reilly\\site")"

test_start "Config without DB_NAME: graceful empty via WP-CLI fallback (headless)"
result="$(db_get_db_name "$FIXTURES/wp_nodbname" wordpress)"
if [[ -z "$result" ]]; then
    test_pass
else
    test_fail "got: '$result'"
fi

dotenv_fixture="$TEST_TEMP_DIR/dotenv_site"
mkdir -p "$dotenv_fixture/.ddev"
printf 'DB_DATABASE=dotenv_db\n' > "$dotenv_fixture/.env"
test_start ".env DB_DATABASE fallback"
check_value "dotenv_db" "$(db_get_db_name "$dotenv_fixture" php)"

ddev_name_fixture="$TEST_TEMP_DIR/ddev_name_site"
mkdir -p "$ddev_name_fixture/.ddev"
printf 'database_name: ddev_named_db\n' > "$ddev_name_fixture/.ddev/config.yaml"
test_start ".ddev/config.yaml database_name fallback"
check_value "ddev_named_db" "$(db_get_db_name "$ddev_name_fixture" php)"

picker_dir="$TEST_TEMP_DIR/picker"
mkdir -p "$picker_dir"
printf 'old\n' > "$picker_dir/site_old.sql"
printf 'new\n' > "$picker_dir/site_new.sql"
touch -t 202601010101 "$picker_dir/site_old.sql"
touch -t 202601020101 "$picker_dir/site_new.sql"
test_start "dump picker defaults to newest file"
check_value "$picker_dir/site_new.sql" "$(printf '\n' | db_pick_dump_file "$picker_dir" site 2>/dev/null)"

# =================================================================
# SECTION B: NGINX HOT-PATCH CONTENT
# =================================================================

echo ""
echo "${TEST_CYAN}=== Nginx Hot-Patch (generated script content) ===${TEST_RESET}"

patch_script="$(tunnel_nginx_config_render)"

test_start "absolute_redirect off present"
check_marker "absolute_redirect off;" "$patch_script"

test_start "port_in_redirect off present"
check_marker "port_in_redirect off;" "$patch_script"

test_start "proxy header Host forwarded (\$http_host)"
# shellcheck disable=SC2016  # literal $http_host — hour nginx-directives
check_marker 'proxy_set_header Host $http_host;' "$patch_script"

test_start "proxy header X-Forwarded-Proto forced to https"
check_marker 'proxy_set_header X-Forwarded-Proto https;' "$patch_script"

test_start "explicit /wp-admin location guard"
check_marker "location = /wp-admin { absolute_redirect off; return 301 /wp-admin/; }" "$patch_script"

test_start "native DDEV override markers preserved"
check_marker "# BEGIN_DPX_NGINX" "$patch_script"

test_start "native override is created on host and nginx reloaded"
nginx_project="$TEST_TEMP_DIR/nginx-project"
nginx_log="$TEST_TEMP_DIR/nginx-ddev.log"
mkdir -p "$nginx_project/.ddev"
ddev() { printf 'ddev %s\n' "$*" >> "$nginx_log"; return 0; }
tunnel_patch_nginx "$nginx_project" >/dev/null 2>&1
if [[ -f "$nginx_project/.ddev/nginx_full/dpx-tunnel.conf" ]] \
   && grep -qxF "ddev exec nginx -s reload" "$nginx_log"; then
    test_pass
else
    test_fail "native nginx override or reload missing"
fi

test_start "cleanup removes native override and reloads nginx"
tunnel_unpatch_nginx "$nginx_project" >/dev/null 2>&1
reload_count="$(grep -cFx "ddev exec nginx -s reload" "$nginx_log")"
if [[ ! -e "$nginx_project/.ddev/nginx_full/dpx-tunnel.conf" && "$reload_count" == "2" ]]; then
    test_pass
else
    test_fail "override remains or cleanup reload missing"
fi
unset -f ddev

test_start "no in-container nginx.conf rewriting remains"
if grep -qF '/etc/nginx/nginx.conf' "$DPX_ROOT/commands/tunnel.sh"; then
    test_fail "legacy nginx.conf mutation still present"
else
    test_pass
fi

# =================================================================
# SECTION C: DPX_SMART_TUNNEL PHP BLOCK
# =================================================================

echo ""
echo "${TEST_CYAN}=== Smart Tunnel PHP block ===${TEST_RESET}"

smart_block="$(tunnel_smart_block_render "tunnel.example.com")"

test_start "conditional HTTPS via X-Forwarded-Proto check"
# shellcheck disable=SC2016  # literal PHP-code, $_SERVER not reveals
check_marker "isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https'" "$smart_block"

test_start "HTTPS='on' set inside condition"
# shellcheck disable=SC2016
check_marker "\$_SERVER['HTTPS'] = 'on';" "$smart_block"

test_start "tunnel domain injected (WP_HOME/WP_SITEURL)"
if grep -qF "define('WP_HOME', 'https://tunnel.example.com')" <<<"$smart_block" \
   && grep -qF "define('WP_SITEURL', 'https://tunnel.example.com')" <<<"$smart_block"; then
    test_pass
else
    test_fail "domain injection broken: $smart_block"
fi

test_start "block markers intact (unpatch tooling depends on them)"
if grep -qF "/** DPX_SMART_TUNNEL */" <<<"$smart_block" \
   && grep -qF "/** END_DPX_SMART_TUNNEL */" <<<"$smart_block"; then
    test_pass
else
    test_fail "markers missing"
fi

# =================================================================
# SECTION D: PORTABILITY EXTRACT UNDER BSD SED (darwin-simulation)
# =================================================================

echo ""
echo "${TEST_CYAN}=== db_get_db_name under simulated BSD sed ===${TEST_RESET}"

SHIM_BIN="$TEST_TEMP_DIR/bin"
SCEN_DIR="$TEST_TEMP_DIR/scenarios"
mkdir -p "$SHIM_BIN" "$SCEN_DIR"

# BSD sed shim: only separate form `-i EXT`, no way long-opts
cat > "$SHIM_BIN/sed" << 'EOF'
#!/usr/bin/env bash
REAL_SED="${DPX_REAL_SED:-/usr/bin/sed}"
args=(); inplace=""; seen_i=0
while [[ $# -gt 0 ]]; do
    a="$1"; shift
    case "$a" in
        --*) printf 'sed: illegal option -- %s (simulated BSD)\n' "$a" >&2; exit 1 ;;
        -i)  seen_i=1; inplace="$1"; shift ;;
        -i*) printf 'sed: attached suffix unsupported (simulated BSD)\n' >&2; exit 1 ;;
        *)   args+=("$a") ;;
    esac
done
if [[ $seen_i -eq 1 ]]; then
    exec "$REAL_SED" "--in-place${inplace:+=$inplace}" "${args[@]}"
fi
exec "$REAL_SED" "${args[@]}"
EOF
chmod +x "$SHIM_BIN/sed"

# Scenario: extract named DATABASE in darwin-environments
cat > "$SCEN_DIR/dbnames.sh" << 'EOF'
export OSTYPE=darwin23
source "$DPX_ROOT/lib/paths.sh"
source "$DPX_ROOT/lib/io.sh"
source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/database.sh"
f="$1"
case "$(basename "$f")" in
    wp_classic*)   echo "R=$(db_get_db_name "$f" wordpress)" ;;
    joomla_site*)  echo "R=$(db_get_db_name "$f" joomla)" ;;
    opencart_site*) echo "R=$(db_get_db_name "$f" opencart)" ;;
esac
EOF

run_darwin() {
    local script="$1"; shift
    (
        # Isolation environment intentional (subprocess scenario)
        # shellcheck disable=SC2030
        export PATH="$SHIM_BIN:$PATH"
        exec "${BASH}" "$script" "$@"
    )
}

test_start "[darwin] WordPress extraction matches linux result"
out="$(run_darwin "$SCEN_DIR/dbnames.sh" "$FIXTURES/wp_classic" 2>&1)"
check_marker "R=wp_mysite" "$out"

test_start "[darwin] Joomla extraction matches linux result"
out="$(run_darwin "$SCEN_DIR/dbnames.sh" "$FIXTURES/joomla_site" 2>&1)"
check_marker "R=joom_base" "$out"

test_start "[darwin] OpenCart extraction matches linux result"
out="$(run_darwin "$SCEN_DIR/dbnames.sh" "$FIXTURES/opencart_site" 2>&1)"
check_marker "R=oc_base" "$out"

# =================================================================
# SECTION E: WIRING REFRESH.SH (protect from regressions bundles)
# =================================================================

echo ""
echo "${TEST_CYAN}=== refresh.sh integration wiring ===${TEST_RESET}"

test_start "refresh.sh calls db_get_db_name with project context"
# shellcheck disable=SC2016  # searching literal line source, not expanded
if grep -qF 'db_get_db_name "$project_path" "$cms_type"' "$DPX_ROOT/commands/refresh.sh"; then
    test_pass
else
    test_fail "wiring removed from refresh.sh"
fi

test_start "refresh.sh falls back to project name when detection empty"
# shellcheck disable=SC2016
if grep -qF 'detected_db="$project_name"' "$DPX_ROOT/commands/refresh.sh"; then
    test_pass
else
    test_fail "fallback missing in refresh.sh"
fi

# =================================================================
# SECTION F: NGROK DRIVER (parsers API, loop expect, lifecycle loop)
# =================================================================

echo ""
echo "${TEST_CYAN}=== ngrok provider: parsers ===${TEST_RESET}"

# Fixtures API-responses ngrok (/api/tunnels)
NGROK_OK_JSON='{"tunnels":[{"name":"cmd","proto":"http","public_url":"http://abc.ngrok-free.app"},{"name":"cmd","proto":"https","public_url":"https://abc.ngrok-free.app"}]}'
NGROK_SPACED_JSON='{"tunnels":[ {"proto":"https", "public_url" :  "https://spaced.ngrok.app" } ]}'
NGROK_HTTP_ONLY_JSON='{"tunnels":[{"proto":"http","public_url":"http://only-http.ngrok.app"}]}'
NGROK_EMPTY_JSON='{"tunnels":[]}'
NGROK_ERR_JSON='{"error":{"status_code":503,"msg":"tunnel session closed"}}'
NGROK_GARBAGE='<<< not json at all >>>'

test_start "[ngrok] jq parser picks HTTPS endpoint"
check_value "https://abc.ngrok-free.app" "$(_tunnel_ngrok_parse_jq "$NGROK_OK_JSON")"

test_start "[ngrok] python3 fallback parser picks HTTPS endpoint"
check_value "https://abc.ngrok-free.app" "$(_tunnel_ngrok_parse_python "$NGROK_OK_JSON")"

test_start "[ngrok] grep/cut fallback parser (incl. spacing variants)"
check_value "https://spaced.ngrok.app" "$(_tunnel_ngrok_parse_grep "$NGROK_SPACED_JSON")"

test_start "[ngrok] dispatcher returns HTTPS URL on valid payload"
check_value "https://abc.ngrok-free.app" "$(tunnel_ngrok_parse_api "$NGROK_OK_JSON")"

test_start "[ngrok] empty tunnels array -> empty result"
check_value "" "$(tunnel_ngrok_parse_api "$NGROK_EMPTY_JSON")"

test_start "[ngrok] error payload -> empty result (no crash)"
check_value "" "$(tunnel_ngrok_parse_api "$NGROK_ERR_JSON")"

test_start "[ngrok] garbage payload -> empty result"
check_value "" "$(tunnel_ngrok_parse_api "$NGROK_GARBAGE")"

test_start "[ngrok] HTTP-only tunnel rejected (HTTPS required by spec)"
check_value "" "$(tunnel_ngrok_parse_api "$NGROK_HTTP_ONLY_JSON")"

# --- Loop expect and lifecycle loop: substitution curl/ngrok via PATH ---

cat > "$SHIM_BIN/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s' "${FAKE_NGROK_API_PAYLOAD:-}"
EOF

cat > "$SHIM_BIN/ngrok" << 'EOF'
#!/usr/bin/env bash
# Fake ngrok: lives 60with as single process (exec), log empty
exec sleep 60
EOF
chmod +x "$SHIM_BIN/curl" "$SHIM_BIN/ngrok"

test_start "[ngrok] wait loop extracts URL from mocked API (fast poll)"
# Isolation environment in $( ) intentional (shim-PATH, intervals polling)
# shellcheck disable=SC2030,SC2031
out="$(
    {
        export PATH="$SHIM_BIN:$PATH"
        # shellcheck disable=SC2034
        TUNNEL_NGROK_POLL_INTERVAL=0.05
        export FAKE_NGROK_API_PAYLOAD="$NGROK_OK_JSON"
        # [FIX] stdout child -> /dev/null, otherwise $( ) waits closed pipe
        sleep 30 >/dev/null 2>&1 & _DPX_TUNNEL_PID=$!
        tunnel_ngrok_wait_public_url
    }
)"
check_value "https://abc.ngrok-free.app" "$out"

test_start "[ngrok] wait loop: dead ngrok PID exits immediately"
rc_dead=0
# shellcheck disable=SC2030,SC2031
out="$(
    {
        export PATH="$SHIM_BIN:$PATH"
        TUNNEL_NGROK_POLL_INTERVAL=0.05
        export FAKE_NGROK_API_PAYLOAD="$NGROK_OK_JSON"
        _DPX_TUNNEL_PID=999999   # knowingly nonexistent process
        tunnel_ngrok_wait_public_url
    }
)" || rc_dead=$?
if [[ "$rc_dead" -ne 0 && -z "$out" ]]; then
    test_pass
else
    test_fail "expected fast failure, got rc=$rc_dead out='$out'"
fi

test_start "[ngrok] wait loop: API error payload times out (bounded)"
t_start=$SECONDS
# shellcheck disable=SC2030,SC2031
out="$(
    {
        export PATH="$SHIM_BIN:$PATH"
        TUNNEL_NGROK_POLL_INTERVAL=0.05
        # shellcheck disable=SC2034
        TUNNEL_NGROK_MAX_WAIT=1
        export FAKE_NGROK_API_PAYLOAD="$NGROK_ERR_JSON"
        sleep 30 >/dev/null 2>&1 & _DPX_TUNNEL_PID=$!
        tunnel_ngrok_wait_public_url
    }
)" || true
elapsed=$(( SECONDS - t_start ))
if [[ -z "$out" ]] && (( elapsed <= 4 )); then
    test_pass
else
    test_fail "out='$out' elapsed=${elapsed}s"
fi

test_start "[ngrok] start(): full lifecycle with mocked binary+API"
# shellcheck disable=SC2030,SC2031
lifecycle_out="$(
    {
        export PATH="$SHIM_BIN:$PATH"
        # shellcheck disable=SC2034
        TUNNEL_NGROK_POLL_INTERVAL=0.05
        export FAKE_NGROK_API_PAYLOAD="$NGROK_OK_JSON"
        log_file="$TEST_TEMP_DIR/ngrok.log"
        if tunnel_ngrok_start "http://127.0.0.1:80" "$log_file" "mysite.lo"; then
            echo "START_OK pid=$_DPX_TUNNEL_PID url=$_DPX_TUNNEL_URL"
            tunnel_ngrok_stop "$_DPX_TUNNEL_PID"
            if kill -0 "$_DPX_TUNNEL_PID" 2>/dev/null; then
                echo "ORPHAN_LEFT"
            else
                echo "ORPHAN_CLEAN"
            fi
        else
            echo "START_FAIL"
        fi
    } 2>/dev/null
)"
check_marker "START_OK" "$lifecycle_out"

test_start "[ngrok] stop(): zero orphan processes after shutdown"
check_marker "ORPHAN_CLEAN" "$lifecycle_out"

test_start "[ngrok] host-header forwarded into command line"
# Static guarantee: --host-header present in assembly command
# shellcheck disable=SC2016  # literal line source
if grep -qF '"--host-header=${host_header}"' "$DPX_ROOT/commands/tunnel.sh"; then
    test_pass
else
    test_fail "--host-header wiring missing in tunnel_ngrok_start"
fi

# =================================================================
# SECTION G: NGROK PARSERS UNDER DARWIN (BSD-simulation)
# =================================================================

echo ""
echo "${TEST_CYAN}=== ngrok parsers under simulated BSD ===${TEST_RESET}"

cat > "$SCEN_DIR/ngrok_parse.sh" << 'EOF'
export OSTYPE=darwin23
# ngrok-functions live in command/tunnel.sh (it itself pulls lib/*)
source "$DPX_ROOT/lib/paths.sh"
source "$DPX_ROOT/lib/io.sh"
source "$DPX_ROOT/commands/tunnel.sh"
payload="$1"
echo "J=$(_tunnel_ngrok_parse_jq "$payload")"
echo "P=$(_tunnel_ngrok_parse_python "$payload")"
echo "G=$(_tunnel_ngrok_parse_grep "$payload")"
EOF

out="$(run_darwin "$SCEN_DIR/ngrok_parse.sh" "$NGROK_OK_JSON" 2>&1)"

test_start "[darwin][ngrok] jq parser"
check_marker "J=https://abc.ngrok-free.app" "$out"

test_start "[darwin][ngrok] python3 parser"
check_marker "P=https://abc.ngrok-free.app" "$out"

test_start "[darwin][ngrok] grep/cut fallback parser"
check_marker "G=https://abc.ngrok-free.app" "$out"

# =================================================================
# SECTION H: SERIALIZATION-SAFE URL REPLACE (v1.5.1 PHP HELPER)
# =================================================================

echo ""
echo "${TEST_CYAN}=== Serialization-safe SQL replace helper ===${TEST_RESET}"

PHP_HELPER="$DPX_ROOT/lib/php_helpers/dpx_serialize_safe_replace.php"

test_start "php helper file present in lib/php_helpers"
if [[ -f "$PHP_HELPER" ]]; then test_pass; else test_fail "missing: $PHP_HELPER"; fi

test_start "database.sh runs helper via ddev exec php (container-side)"
if grep -qF 'dpx_serialize_safe_replace.php' "$DPX_ROOT/lib/database.sh" \
    && grep -qF 'ddev exec php -d display_errors=0' "$DPX_ROOT/lib/database.sh"; then
    test_pass
else
    test_fail "container-side helper invocation missing in database.sh"
fi

test_start "database.sh has NO grep-based Deprecated filtering left"
if grep -qE "grep -vE? ['\"](\\^)?(PHP )?Deprecated" "$DPX_ROOT/lib/database.sh"; then
    test_fail "grep Deprecated filtering still present"
else
    test_pass
fi

test_start "database.sh db_import_with_replace uses no raw sed URL swap"
if grep -A 30 '^db_import_with_replace()' "$DPX_ROOT/lib/database.sh" \
    | grep -qE 'sed "s\|'; then
    test_fail "raw sed URL replacement still present"
else
    test_pass
fi

SQL_IN="$TEST_TEMP_DIR/serialize_in.sql"
SQL_OUT="$TEST_TEMP_DIR/serialize_out.sql"
cat > "$SQL_IN" << 'SQLEOF'
INSERT INTO cfg VALUES (1,'live_site','https://old-site.com');
INSERT INTO cfg VALUES (2,'a:2:{s:3:"url";s:20:"https://old-site.com";s:4:"host";s:12:"old-site.com";}');
INSERT INTO cfg VALUES (3,'a:1:{s:5:"image";s:36:"https:\/\/old-site.com\/assets\/logo.png";}');
SQLEOF

run_php_helper() {
    php -d display_errors=0 -d error_reporting="E_ALL & ~E_DEPRECATED" \
        "$PHP_HELPER" "--old=https://old-site.com" "--new=https://new-site.lo" \
        "--in=$SQL_IN" "--out=$SQL_OUT" 2>/dev/null
}

if command -v php >/dev/null 2>&1; then
    run_php_helper

    test_start "helper: plain SQL literals replaced"
    if grep -qF "'https://new-site.lo'" "$SQL_OUT"; then
        test_pass
    else
        test_fail "out: $(cat "$SQL_OUT")"
    fi

    test_start "helper: serialized s:N header recomputed (20 -> 19)"
    if grep -qF 's:19:"https://new-site.lo"' "$SQL_OUT"; then
        test_pass
    else
        test_fail "out: $(cat "$SQL_OUT")"
    fi

    test_start "helper: escaped-slash payload re-measured byte-exact"
    if grep -qF 's:35:"https://new-site.lo/assets/logo.png"' "$SQL_OUT"; then
        test_pass
    else
        test_fail "out: $(cat "$SQL_OUT")"
    fi

    test_start "helper: zero old-URL occurrences remain"
    if grep -qF "old-site.com" "$SQL_OUT"; then
        test_fail "stale URL left: $(cat "$SQL_OUT")"
    else
        test_pass
    fi
else
    test_start "helper: plain SQL literals replaced"
    test_skip "php CLI not available on host"
    test_start "helper: serialized s:N header recomputed (20 -> 19)"
    test_skip "php CLI not available on host"
    test_start "helper: escaped-slash payload re-measured byte-exact"
    test_skip "php CLI not available on host"
    test_start "helper: zero old-URL occurrences remain"
    test_skip "php CLI not available on host"
fi

# =================================================================
# SUMMARIES
# =================================================================

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
