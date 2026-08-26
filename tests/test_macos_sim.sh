#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: macOS/BSD Simulation Suite
#
# Simulates execut DPX on macOS without physical hardware:
#   - OSTYPE=darwin* internals isolated process Bash;
#   - shim's BSD-utility in PATH: sed (-i ''), stat (-f %m),
#     readlink (without -f, as on macOS < 12.3), tar (strict order
#     option bsdtar), ddev (functional stub).
#
# IMPORTANT: bash OVERWRITES $OSTYPE durings start, therefore value
# sets INTERNALS each scenario after start interpreter,
# and not via environment parent.
# =================================================================

# =================================================================
# INITIALIZATION
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: Tests require Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# Path framework computes in time execut (portability layout)
# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: macOS/BSD Simulation" "1.0.0"
setup_temp_dir >/dev/null   # TEST_TEMP_DIR + EXIT trap (guaranteed teardown)

SHIM_BIN="$TEST_TEMP_DIR/bin"
FAKE_HOME="$TEST_TEMP_DIR/home"
SCEN_DIR="$TEST_TEMP_DIR/scenarios"
mkdir -p "$SHIM_BIN" "$FAKE_HOME" "$SCEN_DIR"

export DPX_SHIM_LOG="$TEST_TEMP_DIR/ddev.log"

# =================================================================
# GENERATION SHIM'S BSD-UTILITY
# =================================================================

# --- BSD sed: famous different from GNU -------------------------
#   * `sed -i '' EXPR FILE` — extended ALWAYS separate argument;
#   * attached form `-ibak` NOT supports;
#   * GNU long-options (--expression, --in-place) absent.
cat > "$SHIM_BIN/sed" << 'EOF'
#!/usr/bin/env bash
REAL_SED="${DPX_REAL_SED:-/usr/bin/sed}"
args=()
inplace=""
seen_i=0

while [[ $# -gt 0 ]]; do
    a="$1"; shift
    case "$a" in
        --*)
            printf 'sed: illegal option -- %s (simulated BSD)\n' "$a" >&2
            exit 1 ;;
        -i)
            seen_i=1
            if [[ $# -eq 0 ]]; then
                echo "sed: -i requires an extension argument (simulated BSD)" >&2
                exit 1
            fi
            inplace="$1"; shift
            ;;
        -i*)
            printf 'sed: attached suffix not supported by BSD sed: %s\n' "$a" >&2
            exit 1 ;;
        *)
            args+=("$a") ;;
    esac
done

if [[ $seen_i -eq 1 ]]; then
    # '' -> without backup (GNU: --in-place); '.bak' -> --in-place=.bak
    exec "$REAL_SED" "--in-place${inplace:+=$inplace}" "${args[@]}"
fi
exec "$REAL_SED" "${args[@]}"
EOF

# --- BSD stat: only -f formats (%m mtime, %z size) -------------
cat > "$SHIM_BIN/stat" << 'EOF'
#!/usr/bin/env bash
REAL_STAT="${DPX_REAL_STAT:-/usr/bin/stat}"

if [[ "${1:-}" != "-f" ]]; then
    echo "stat: illegal option (simulated BSD supports -f only)" >&2
    exit 1
fi
fmt="$2"; shift 2
case "$fmt" in
    %m) exec "$REAL_STAT" -c '%Y' -- "$@" ;;
    %z) exec "$REAL_STAT" -c '%s' -- "$@" ;;
    *)  printf 'stat: invalid format %s (simulated BSD)\n' "$fmt" >&2
        exit 1 ;;
esac
EOF

# --- readlink: without -f (as on macOS < 12.3) ----------------------
cat > "$SHIM_BIN/readlink" << 'EOF'
#!/usr/bin/env bash
REAL_READLINK="${DPX_REAL_READLINK:-/usr/bin/readlink}"
if [[ "${1:-}" == "-f" ]]; then
    echo "readlink: illegal option -- f (simulated macOS < 12.3)" >&2
    exit 1
fi
exec "$REAL_READLINK" "$@"
EOF

# --- tar: strict order bsdtar (--exclude UNTIL -f) ---------------
cat > "$SHIM_BIN/tar" << 'EOF'
#!/usr/bin/env bash
REAL_TAR="${DPX_REAL_TAR:-/usr/bin/tar}"

first_exclude=-1
first_file=-1
i=0
for a in "$@"; do
    case "$a" in
        --exclude*) [[ $first_exclude -eq -1 ]] && first_exclude=$i ;;
        --file*)    [[ $first_file    -eq -1 ]] && first_file=$i ;;
        -*f)        [[ $first_file    -eq -1 ]] && first_file=$i ;;  # -f, -czf
    esac
    i=$((i + 1))
done

if (( first_file >= 0 && first_exclude >= 0 && first_file < first_exclude )); then
    echo "bsdtar-sim: --exclude must precede -f (BSD option order)" >&2
    exit 2
fi
exec "$REAL_TAR" "$@"
EOF

# --- ddev stub: log calls + emulation need subcommand ----------
cat > "$SHIM_BIN/ddev" << 'EOF'
#!/usr/bin/env bash
LOG="${DPX_SHIM_LOG:?DPX_SHIM_LOG not set}"
echo "ddev $*" >> "$LOG"
cmd="$1"
shift || true
case "$cmd" in
    restart)
        for a in "$@"; do
            case "$a" in
                --name=*) [[ "${DPX_SHIM_NO_NAME_FLAG:-}" == "yes" ]] && exit 99 ;;
            esac
        done
        exit 0 ;;
    export-db)
        out=""; gz="false"
        for a in "$@"; do
            case "$a" in
                --file=*) out="${a#--file=}" ;;
                --gzip=*) gz="${a#--gzip=}" ;;
            esac
        done
        { [[ "$gz" == "true" ]] && printf 'GZDUMP' || printf 'DUMP'; } > "$out"
        exit 0 ;;
    import-db)
        for a in "$@"; do
            case "$a" in
                --name=*) [[ "${DPX_SHIM_NO_NAME_FLAG:-}" == "yes" ]] && exit 99 ;;
            esac
        done
        exit 0 ;;
    exec)
        # Emulate `ddev exec php <helper> --old= --new= --in= --out=`:
        # the real container helper rewrites URLs AND recomputes PHP
        # serialized byte lengths; the stub approximates with sed so
        # the Bash pipeline (staging, exit codes, cleanup) is covered.
        is_php=""; old=""; new=""; fin=""; fout=""
        for a in "$@"; do
            case "$a" in
                php)      is_php=yes ;;
                --old=*)  old="${a#--old=}" ;;
                --new=*)  new="${a#--new=}" ;;
                --in=*)   fin="${a#--in=}" ;;
                --out=*)  fout="${a#--out=}" ;;
            esac
        done
        if [[ "$is_php" == yes && -n "$fin" && -n "$fout" && -f "$fin" ]]; then
            "${REAL_SED:-/usr/bin/sed}" "s|$old|$new|g" "$fin" > "$fout" || exit 4
        fi
        exit 0 ;;
    *) exit 0 ;;   # list/describe/start/mysql/snapshot/...
esac
EOF

chmod +x "$SHIM_BIN"/*

# =================================================================
# START SCENARIOS In SIMULATIONS DARWIN
#
# Each scenario — SEPARATE process bash: guard-variable module
# (_DPX_*_LOADED, readonly DPX_ROOT) not survive boundary process.
# =================================================================

run_darwin() {
    local script="$1"; shift
    (
        # Isolation environment INTENTIONAL: only internals subprocess scenario
        # shellcheck disable=SC2030
        export HOME="$FAKE_HOME"
        # shellcheck disable=SC2030
        export PATH="$SHIM_BIN:$PATH"
        : > "$DPX_SHIM_LOG"
        exec "${BASH}" "$script" "$@"
    )
}

# Variant with "legacy-DDEV": flag --name at restart/import-db not supported
run_darwin_legacy_ddev() {
    local script="$1"; shift
    (
        # shellcheck disable=SC2030,SC2031
        export HOME="$FAKE_HOME"
        # shellcheck disable=SC2031
        export PATH="$SHIM_BIN:$PATH"
        export DPX_SHIM_NO_NAME_FLAG=yes
        : > "$DPX_SHIM_LOG"
        exec "${BASH}" "$script" "$@"
    )
}

# =================================================================
# HELPERS ASSERTS (one test_pass on one test_start)
#
# assert_* framework already cause test_fail durings miss; here wes
# add symmetric explicit test_pass without "A && B || C" (SC2015).
# =================================================================

check_marker() { # $1 = expected marker, $2 = output scenario
    local marker="$1" haystack="$2"
    if grep -qF -- "$marker" <<<"$haystack"; then
        test_pass
    else
        test_fail "marker '$marker' missing; got: $haystack"
    fi
}

# =================================================================
# SCENARIO A: detection OS (paths.sh)
# =================================================================

cat > "$SCEN_DIR/a_detect.sh" << 'EOF'
export OSTYPE="${SIM_OSTYPE:?}"
source "$DPX_ROOT/lib/paths.sh"
echo "DETECT_OS=$DPX_OS_TYPE EXT=$DPX_SED_INPLACE_EXT"
EOF

# =================================================================
# SCENARIO B: safe_sed_inplace (Joomla config) under BSD sed
# =================================================================

cat > "$SCEN_DIR/b_sed.sh" << 'EOF'
export OSTYPE=darwin23
fixture_dir="$1"

source "$DPX_ROOT/lib/paths.sh"
source "$DPX_ROOT/lib/io.sh"
source "$DPX_ROOT/lib/utils.sh"
source "$DPX_ROOT/lib/cms.sh"

config_file="$fixture_dir/configuration.php"

# Those same patterns, that in configure_joomla_config (single quotes
# internals scenario => sed gets \$host as literal, as in cms.sh)
safe_sed_inplace 's|public[[:space:]]*\$host[[:space:]]*=.*|public \$host = '"'"'db'"'"';|g' "$config_file"

if grep -q "public \$host = 'db';" "$config_file"; then
    echo "SED_REPLACE_OK"
else
    echo "SED_REPLACE_FAIL content:"; cat "$config_file"
fi

if [[ ! -e "${config_file}.bak" ]]; then
    echo "SED_BAK_CLEANED_OK"
else
    echo "SED_BAK_RESIDUE_FAIL"
fi
EOF

# =================================================================
# SCENARIO C: permission path without GNU readlink -f
# =================================================================

cat > "$SCEN_DIR/c_symlink.sh" << 'EOF'
export OSTYPE=darwin23
base="$1"

source "$DPX_ROOT/lib/paths.sh"

mkdir -p "$base/real"
touch "$base/real/target.txt"
# Chain finishes on FILE: contract dpx_resolve_symlink
# returns DIRECTOR, containing final path (so its
# uses dpx_get_root: paths.sh -> dir=lib -> root).
ln -sfn "real/target.txt" "$base/lvl1"
ln -sfn lvl1 "$base/lvl2"
ln -sfn lvl2 "$base/lvl3"

resolved="$(dpx_resolve_symlink "$base/lvl3")" || resolved=""
if [[ "$(basename "$resolved")" == "real" && -f "$resolved/target.txt" ]]; then
    echo "SYMLINK_RESOLVE_OK"
else
    echo "SYMLINK_RESOLVE_FAIL got=$resolved"
fi

# Cyclic symlink -> protected refusal (max_iterations)
ln -sfn "$base/cyc" "$base/cyc"
if dpx_resolve_symlink "$base/cyc" >/dev/null 2>&1; then
    echo "CYCLE_GUARD_FAIL"
else
    echo "CYCLE_GUARD_OK"
fi

# dpx_get_root must back root repository (contains dpx.sh)
root="$(dpx_get_root)"
if [[ -d "$root" && -f "$root/dpx.sh" ]]; then
    echo "ROOT_RESOLVE_OK"
else
    echo "ROOT_RESOLVE_FAIL root=$root"
fi
EOF

# =================================================================
# SCENARIO D: project_full_backup under full BSD-environment
# =================================================================

cat > "$SCEN_DIR/d_backup.sh" << 'EOF'
export OSTYPE=darwin23
project_dir="$1"
backup_dir="$2"

source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/database.sh"
source "$DPX_ROOT/lib/backup.sh"

# Progress rotations: 3 "old" archive with decrementing mtime
mkdir -p "$backup_dir"
for n in 1 2 3; do
    old="${backup_dir}/FULL_bsdproj_2026-01-0${n}_00000${n}.tar.gz"
    echo old > "$old"
    touch -d "2026-01-0${n} 00:00:00" "$old"
done

archive="$(project_full_backup "bsdproj" "$project_dir" "$backup_dir" 2)"
rc=$?
echo "BACKUP_RC=$rc"
[[ -n "$archive" ]] && echo "ARCHIVE_PATH_SET"

if tar -tzf "$archive" >/dev/null 2>&1; then
    echo "TAR_LIST_OK"
else
    echo "TAR_LIST_CORRUPT"
fi

contents="$(tar -tzf "$archive")"
grep -q "bsdproj/index.php" <<<"$contents" && echo "CONTENT_APP_OK"
grep -q "bsdproj_db.sql.gz" <<<"$contents" && echo "DB_DUMP_INCLUDED"

if grep -Eq '(^|/)vendor/|(^|/)node_modules/|(^|/)\.git/' <<<"$contents"; then
    echo "EXCLUDE_VIOLATION"
else
    echo "EXCLUDE_CLEAN_OK"
fi
EOF

# =================================================================
# SCENARIO E: db_import_with_replace under BSD sed + ddev-stub
# =================================================================

cat > "$SCEN_DIR/e_import.sh" << 'EOF'
export OSTYPE=darwin23
dump="$1"
proj="$2"

source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/database.sh"

db_import_with_replace "$dump" "https://old-site.com" "https://new-site.lo" "$proj"
echo "IMPORT_RC=$?"

# Source dump not must was chang (replace only in temporary cops)
if grep -q "old-site.com" "$dump"; then
    echo "ORIGINAL_INTACT_OK"
else
    echo "ORIGINAL_MODIFIED_FAIL"
fi

# Staged container-side artifacts (helper + temp dumps) must be cleaned
if [[ ! -e "$proj/.dpx/tmp/dpx_import_in.sql" \
   && ! -e "$proj/.dpx/tmp/dpx_import_out.sql" \
   && ! -e "$proj/.dpx/tmp/dpx_serialize_safe_replace.php" ]]; then
    echo "TMP_CLEANED_OK"
else
    echo "TMP_LEAK_FAIL"
fi
EOF

# =================================================================
# FIXTURES
# =================================================================

JOOM_FIXTURE="$TEST_TEMP_DIR/joomla-fixture"
mkdir -p "$JOOM_FIXTURE"
cat > "$JOOM_FIXTURE/configuration.php" << 'PHPEOF'
<?php
class JConfig {
    public $host = 'localhost';
    public $user = 'root';
    public $password = 'secret';
    public $db = 'joomla_db';
}
PHPEOF

BACKUP_PROJ="$TEST_TEMP_DIR/ws/php/bsdproj"
mkdir -p "$BACKUP_PROJ/vendor/heavy" "$BACKUP_PROJ/node_modules/pkg" \
         "$BACKUP_PROJ/.git/objects" "$BACKUP_PROJ/.ddev/.importdb" \
         "$BACKUP_PROJ/web/wp-content"
echo "app" > "$BACKUP_PROJ/index.php"
echo "dep" > "$BACKUP_PROJ/vendor/heavy/lib.bin"
echo "js"  > "$BACKUP_PROJ/node_modules/pkg/x.js"
echo "git" > "$BACKUP_PROJ/.git/objects/o.pack"
echo "tmp" > "$BACKUP_PROJ/.ddev/.importdb/partial.sql"
echo "wp"  > "$BACKUP_PROJ/web/wp-content/post.txt"

IMPORT_PROJ="$TEST_TEMP_DIR/ws/php/importsite"
mkdir -p "$IMPORT_PROJ"
IMPORT_DUMP="$TEST_TEMP_DIR/prod_dump.sql"
cat > "$IMPORT_DUMP" << 'SQLEOF'
-- MySQL dump
INSERT INTO config VALUES (1, 'live_site', 'https://old-site.com');
SQLEOF

# =================================================================
# TESTS: DETECTION OS
# =================================================================

echo ""
echo "${TEST_CYAN}=== OS Detection (simulated) ===${TEST_RESET}"

test_start "OSTYPE=darwin -> macos + sed ext .bak"
out="$(SIM_OSTYPE=darwin23 run_darwin "$SCEN_DIR/a_detect.sh" 2>&1)"
check_marker "DETECT_OS=macos EXT=.bak" "$out"

test_start "OSTYPE=linux-gnu -> linux + empty ext (control)"
out="$(SIM_OSTYPE=linux-gnu run_darwin "$SCEN_DIR/a_detect.sh" 2>&1)"
check_marker "DETECT_OS=linux EXT=" "$out"

# =================================================================
# TESTS: BSD SED
# =================================================================

echo ""
echo "${TEST_CYAN}=== BSD sed Simulation ===${TEST_RESET}"

test_start "shim rejects attached '-ibak' (GNU-only syntax)"
if "$SHIM_BIN/sed" -ibak 's/a/b/' /dev/null >/dev/null 2>&1; then
    test_fail "attached -i form unexpectedly accepted"
else
    test_pass
fi

test_start "shim rejects GNU long option '--expression'"
if "$SHIM_BIN/sed" --expression 's/a/b/' /dev/null >/dev/null 2>&1; then
    test_fail "long option unexpectedly accepted"
else
    test_pass
fi

test_start "safe_sed_inplace replaces Joomla config (BSD '-i .bak')"
out="$(run_darwin "$SCEN_DIR/b_sed.sh" "$JOOM_FIXTURE" 2>&1)"
check_marker "SED_REPLACE_OK" "$out"

test_start ".bak residue cleaned after in-place edit"
check_marker "SED_BAK_CLEANED_OK" "$out"

# =================================================================
# TESTS: PERMISSION PATH WITHOUT GNU COREUTILS
# =================================================================

echo ""
echo "${TEST_CYAN}=== Path Resolution (no readlink -f) ===${TEST_RESET}"

test_start "readlink shim rejects '-f' (macOS < 12.3 behavior)"
if "$SHIM_BIN/readlink" -f "$TEST_TEMP_DIR" >/dev/null 2>&1; then
    test_fail "-f unexpectedly accepted"
else
    test_pass
fi

test_start "symlink chain resolved via dpx_resolve_symlink"
SYM_BASE="$TEST_TEMP_DIR/symlinks"
out="$(run_darwin "$SCEN_DIR/c_symlink.sh" "$SYM_BASE" 2>&1)"
check_marker "SYMLINK_RESOLVE_OK" "$out"

test_start "cyclic symlink guarded (no hang, error returned)"
check_marker "CYCLE_GUARD_OK" "$out"

test_start "dpx_get_root returns repository root"
check_marker "ROOT_RESOLVE_OK" "$out"

# =================================================================
# TESTS: BSD STAT
# =================================================================

echo ""
echo "${TEST_CYAN}=== BSD stat Simulation ===${TEST_RESET}"

STAT_FILE="$TEST_TEMP_DIR/statfile.txt"
echo "hello" > "$STAT_FILE"

test_start "stat -f %m matches real mtime epoch"
if [[ "$("$SHIM_BIN/stat" -f '%m' "$STAT_FILE")" == "$(stat -c '%Y' "$STAT_FILE")" ]]; then
    test_pass
else
    test_fail "mtime mismatch"
fi

test_start "stat -f %z matches real size"
if [[ "$("$SHIM_BIN/stat" -f '%z' "$STAT_FILE")" == "$(stat -c '%s' "$STAT_FILE")" ]]; then
    test_pass
else
    test_fail "size mismatch"
fi

test_start "GNU flag '-c' rejected by shim"
if "$SHIM_BIN/stat" -c '%Y' "$STAT_FILE" >/dev/null 2>&1; then
    test_fail "GNU flag unexpectedly accepted"
else
    test_pass
fi

# =================================================================
# TESTS: ORDER OPTION BSD TAR
# =================================================================

echo ""
echo "${TEST_CYAN}=== tar Exclusion Order (bsdtar strictness) ===${TEST_RESET}"

TAR_DIR="$TEST_TEMP_DIR/tardir"
mkdir -p "$TAR_DIR/sub"
echo x > "$TAR_DIR/sub/file.txt"

test_start "NEGATIVE CONTROL: -f before --exclude rejected by guard"
if "$SHIM_BIN/tar" -czf "$TEST_TEMP_DIR/bad.tar.gz" --exclude='zz' -C "$TAR_DIR" . >/dev/null 2>&1; then
    test_fail "guard did not trigger on bad order"
else
    test_pass
fi

test_start "POSITIVE: --exclude before -czf accepted (DPX backup order)"
if "$SHIM_BIN/tar" --exclude='zz' -czf "$TEST_TEMP_DIR/good.tar.gz" -C "$TAR_DIR" . >/dev/null 2>&1; then
    test_pass
else
    test_fail "valid BSD order rejected"
fi

# =================================================================
# TESTS: PROJECT_FULL_BACKUP UNDER DARWIN
# =================================================================

echo ""
echo "${TEST_CYAN}=== project_full_backup (full BSD environment) ===${TEST_RESET}"

BACKUP_OUT="$TEST_TEMP_DIR/full-backups"
mkdir -p "$BACKUP_OUT"

test_start "backup completes: rc=0, archive listed OK"
out="$(run_darwin "$SCEN_DIR/d_backup.sh" "$BACKUP_PROJ" "$BACKUP_OUT" 2>&1)"
if grep -q "BACKUP_RC=0" <<<"$out" && grep -q "TAR_LIST_OK" <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

test_start "app files included into archive"
check_marker "CONTENT_APP_OK" "$out"

test_start "DB dump included (gzip from ddev export-db)"
check_marker "DB_DUMP_INCLUDED" "$out"

test_start "excludes honored (vendor/node_modules/.git absent)"
check_marker "EXCLUDE_CLEAN_OK" "$out"

test_start "rotation keeps last N=2 (3 seeded old archives removed)"
# ls (not find): sorting by mtime — day checks rotations; named
# archives machine-generated (FULL_<name>_<timestamp>), safes.
# shellcheck disable=SC2012
kept_count="$(ls -1 "$BACKUP_OUT"/FULL_bsdproj_*.tar.gz 2>/dev/null | wc -l)"
kept_count="${kept_count// /}"
if [[ "$kept_count" == "2" ]]; then
    test_pass
else
    test_fail "expected 2 archives, found $kept_count"
fi

test_start "newest archive survives rotation (fresh one retained)"
# shellcheck disable=SC2012
newest_kept="$(ls -1t "$BACKUP_OUT"/FULL_bsdproj_*.tar.gz | head -1)"
if tar -tzf "$newest_kept" | grep -q "bsdproj/index.php"; then
    test_pass
else
    test_fail "retained archive invalid: $newest_kept"
fi

# =================================================================
# TESTS: DB_IMPORT_WITH_REPLACE UNDER BSD
# =================================================================

echo ""
echo "${TEST_CYAN}=== db_import_with_replace (BSD constraints) ===${TEST_RESET}"

test_start "import with URL replace succeeds (rc=0)"
out="$(run_darwin "$SCEN_DIR/e_import.sh" "$IMPORT_DUMP" "$IMPORT_PROJ" 2>&1)"
check_marker "IMPORT_RC=0" "$out"

test_start "original dump NOT modified (temp copy semantics)"
check_marker "ORIGINAL_INTACT_OK" "$out"

test_start "staged .dpx/tmp artifacts cleaned after replace+import"
check_marker "TMP_CLEANED_OK" "$out"

test_start "ddev flow logged: soft-restart + import-db present"
ddev_log="$(cat "$DPX_SHIM_LOG")"
if grep -q "restart" <<<"$ddev_log" && grep -q "import-db" <<<"$ddev_log"; then
    test_pass
else
    test_fail "log: $ddev_log"
fi

test_start "legacy DDEV (no --name flag): fallback path works"
out="$(run_darwin_legacy_ddev "$SCEN_DIR/e_import.sh" "$IMPORT_DUMP" "$IMPORT_PROJ" 2>&1)"
ddev_log="$(cat "$DPX_SHIM_LOG")"
if grep -q "IMPORT_RC=0" <<<"$out" && grep -qE 'restart importsite( |$)' <<<"$ddev_log"; then
    test_pass
else
    test_fail "out=$out log=$ddev_log"
fi

test_start "replace runs in-container: ddev exec php with -d suppression flags"
ddev_log="$(cat "$DPX_SHIM_LOG")"
if grep -qF "exec php -d display_errors=0 -d error_reporting=E_ALL & ~E_DEPRECATED" <<<"$ddev_log" \
    && grep -qF -- "--old=https://old-site.com" <<<"$ddev_log" \
    && grep -qF "dpx_serialize_safe_replace.php" <<<"$ddev_log"; then
    test_pass
else
    test_fail "log: $ddev_log"
fi

# =================================================================
# SUMMARIES
# =================================================================

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
