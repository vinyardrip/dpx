#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: macOS/BSD Simulation Suite
#
# Симулирует выполнение DPX на macOS без физического железа:
#   - OSTYPE=darwin* внутри изолированных процессов Bash;
#   - shim'ы BSD-утилит в PATH: sed (-i ''), stat (-f %m),
#     readlink (без -f, как на macOS < 12.3), tar (строгий порядок
#     опций bsdtar), ddev (функциональный stub).
#
# ВАЖНО: bash ПЕРЕЗАПИСЫВАЕТ $OSTYPE при старте, поэтому значение
# выставляется ВНУТРИ каждого сценария после запуска интерпретатора,
# а не через окружение родителя.
# =================================================================

# =================================================================
# ИНИЦИАЛИЗАЦИЯ
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ОШИБКА: Тесты требуют Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# Путь фреймворка вычисляется во время выполнения (портативность layout)
# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: macOS/BSD Simulation" "1.0.0"
setup_temp_dir >/dev/null   # TEST_TEMP_DIR + EXIT trap (гарантированный teardown)

SHIM_BIN="$TEST_TEMP_DIR/bin"
FAKE_HOME="$TEST_TEMP_DIR/home"
SCEN_DIR="$TEST_TEMP_DIR/scenarios"
mkdir -p "$SHIM_BIN" "$FAKE_HOME" "$SCEN_DIR"

export DPX_SHIM_LOG="$TEST_TEMP_DIR/ddev.log"

# =================================================================
# ГЕНЕРАЦИЯ SHIM'ОВ BSD-УТИЛИТ
# =================================================================

# --- BSD sed: знаменитые отличия от GNU -------------------------
#   * `sed -i '' EXPR FILE` — расширение ВСЕГДА отдельный аргумент;
#   * прикрепленная форма `-ibak` НЕ поддерживается;
#   * GNU long-опции (--expression, --in-place) отсутствуют.
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
    # '' -> без бэкапа (GNU: --in-place); '.bak' -> --in-place=.bak
    exec "$REAL_SED" "--in-place${inplace:+=$inplace}" "${args[@]}"
fi
exec "$REAL_SED" "${args[@]}"
EOF

# --- BSD stat: только -f форматы (%m mtime, %z size) -------------
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

# --- readlink: без -f (как на macOS < 12.3) ----------------------
cat > "$SHIM_BIN/readlink" << 'EOF'
#!/usr/bin/env bash
REAL_READLINK="${DPX_REAL_READLINK:-/usr/bin/readlink}"
if [[ "${1:-}" == "-f" ]]; then
    echo "readlink: illegal option -- f (simulated macOS < 12.3)" >&2
    exit 1
fi
exec "$REAL_READLINK" "$@"
EOF

# --- tar: строгий порядок bsdtar (--exclude ДО -f) ---------------
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

# --- ddev stub: лог вызовов + эмуляция нужных подкоманд ----------
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
    *) exit 0 ;;   # list/describe/start/exec/mysql/snapshot/...
esac
EOF

chmod +x "$SHIM_BIN"/*

# =================================================================
# ЗАПУСК СЦЕНАРИЕВ В СИМУЛЯЦИИ DARWIN
#
# Каждый сценарий — ОТДЕЛЬНЫЙ процесс bash: guard-переменные модулей
# (_DPX_*_LOADED, readonly DPX_ROOT) не переживают границу процессов.
# =================================================================

run_darwin() {
    local script="$1"; shift
    (
        # Изоляция окружения НАМЕРЕННА: только внутри подпроцесса сценария
        # shellcheck disable=SC2030
        export HOME="$FAKE_HOME"
        # shellcheck disable=SC2030
        export PATH="$SHIM_BIN:$PATH"
        : > "$DPX_SHIM_LOG"
        exec "${BASH}" "$script" "$@"
    )
}

# Вариант с "легаси-DDEV": флаг --name у restart/import-db не поддержан
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
# ХЕЛПЕРЫ АССЕРТОВ (один test_pass на один test_start)
#
# assert_* фреймворка уже вызывают test_fail при промахе; здесь мы
# добавляем симметричный явный test_pass без "A && B || C" (SC2015).
# =================================================================

check_marker() { # $1 = ожидаемый маркер, $2 = вывод сценария
    local marker="$1" haystack="$2"
    if grep -qF -- "$marker" <<<"$haystack"; then
        test_pass
    else
        test_fail "marker '$marker' missing; got: $haystack"
    fi
}

# =================================================================
# СЦЕНАРИЙ A: детекция ОС (paths.sh)
# =================================================================

cat > "$SCEN_DIR/a_detect.sh" << 'EOF'
export OSTYPE="${SIM_OSTYPE:?}"
source "$DPX_ROOT/lib/paths.sh"
echo "DETECT_OS=$DPX_OS_TYPE EXT=$DPX_SED_INPLACE_EXT"
EOF

# =================================================================
# СЦЕНАРИЙ B: safe_sed_inplace (Joomla config) под BSD sed
# =================================================================

cat > "$SCEN_DIR/b_sed.sh" << 'EOF'
export OSTYPE=darwin23
fixture_dir="$1"

source "$DPX_ROOT/lib/paths.sh"
source "$DPX_ROOT/lib/io.sh"
source "$DPX_ROOT/lib/utils.sh"
source "$DPX_ROOT/lib/cms.sh"

config_file="$fixture_dir/configuration.php"

# Те же паттерны, что в configure_joomla_config (одинарные кавычки
# внутри сценария => sed получает \$host как литерал, как в cms.sh)
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
# СЦЕНАРИЙ C: разрешение путей без GNU readlink -f
# =================================================================

cat > "$SCEN_DIR/c_symlink.sh" << 'EOF'
export OSTYPE=darwin23
base="$1"

source "$DPX_ROOT/lib/paths.sh"

mkdir -p "$base/real"
touch "$base/real/target.txt"
# Цепочка заканчивается на ФАЙЛЕ: контракт dpx_resolve_symlink
# возвращает ДИРЕКТОРИЮ, содержащую итоговый путь (так его
# использует dpx_get_root: paths.sh -> dir=lib -> root).
ln -sfn "real/target.txt" "$base/lvl1"
ln -sfn lvl1 "$base/lvl2"
ln -sfn lvl2 "$base/lvl3"

resolved="$(dpx_resolve_symlink "$base/lvl3")" || resolved=""
if [[ "$(basename "$resolved")" == "real" && -f "$resolved/target.txt" ]]; then
    echo "SYMLINK_RESOLVE_OK"
else
    echo "SYMLINK_RESOLVE_FAIL got=$resolved"
fi

# Циклический симлинк -> защищенный отказ (max_iterations)
ln -sfn "$base/cyc" "$base/cyc"
if dpx_resolve_symlink "$base/cyc" >/dev/null 2>&1; then
    echo "CYCLE_GUARD_FAIL"
else
    echo "CYCLE_GUARD_OK"
fi

# dpx_get_root должен вернуть корень репозитория (содержит dpx.sh)
root="$(dpx_get_root)"
if [[ -d "$root" && -f "$root/dpx.sh" ]]; then
    echo "ROOT_RESOLVE_OK"
else
    echo "ROOT_RESOLVE_FAIL root=$root"
fi
EOF

# =================================================================
# СЦЕНАРИЙ D: project_full_backup под полным BSD-окружением
# =================================================================

cat > "$SCEN_DIR/d_backup.sh" << 'EOF'
export OSTYPE=darwin23
project_dir="$1"
backup_dir="$2"

source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/database.sh"
source "$DPX_ROOT/lib/backup.sh"

# Прогрев ротации: 3 "старых" архива с убывающим mtime
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
# СЦЕНАРИЙ E: db_import_with_replace под BSD sed + ddev-stub
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

# Исходный дамп не должен быть изменен (замена только во временной копии)
if grep -q "old-site.com" "$dump"; then
    echo "ORIGINAL_INTACT_OK"
else
    echo "ORIGINAL_MODIFIED_FAIL"
fi
EOF

# =================================================================
# ФИКСТУРЫ
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
# ТЕСТЫ: ДЕТЕКЦИЯ ОС
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
# ТЕСТЫ: BSD SED
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
# ТЕСТЫ: РАЗРЕШЕНИЕ ПУТЕЙ БЕЗ GNU COREUTILS
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
# ТЕСТЫ: BSD STAT
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
# ТЕСТЫ: ПОРЯДОК ОПЦИЙ BSD TAR
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
# ТЕСТЫ: PROJECT_FULL_BACKUP ПОД DARWIN
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
# ls (не find): сортировка по mtime — суть проверки ротации; имена
# архивов машинно-генерированные (FULL_<name>_<timestamp>), безопасны.
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
# ТЕСТЫ: DB_IMPORT_WITH_REPLACE ПОД BSD
# =================================================================

echo ""
echo "${TEST_CYAN}=== db_import_with_replace (BSD constraints) ===${TEST_RESET}"

test_start "import with URL replace succeeds (rc=0)"
out="$(run_darwin "$SCEN_DIR/e_import.sh" "$IMPORT_DUMP" "$IMPORT_PROJ" 2>&1)"
check_marker "IMPORT_RC=0" "$out"

test_start "original dump NOT modified (temp copy semantics)"
check_marker "ORIGINAL_INTACT_OK" "$out"

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

# =================================================================
# ИТОГИ
# =================================================================

print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
