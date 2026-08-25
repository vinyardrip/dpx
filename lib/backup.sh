#!/usr/bin/env bash
# =================================================================
# DPX Backup Module — полный бэкап проекта (файлы + база данных)
#
# Архитектура:
#   project_full_backup  — оркестратор: дамп БД + tar.gz файлов + ротация
#   backup_rotate        — ротация старых архивов (retention N)
#
# КОНТРАКТ ВЫВОДА (как у db_backup_local):
#   STDOUT — путь к созданному архиву (одна строка);
#   STDERR — весь UI: шаги, предупреждения, ошибки.
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_BACKUP_LOADED:-}" ]] && return 0
readonly _DPX_BACKUP_LOADED=1

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/ddev.sh"

# =================================================================
# РОТАЦИЯ БЭКАПОВ
#
# Удаляет самые старые архивы, оставляя последние $3 штук.
# Учитываются только файлы с префиксом $2 (изоляция проектов).
#
# АРГУМЕНТЫ:
#   $1 — директория с архивами
#   $2 — префикс имени (например "FULL_mysite_")
#   $3 — сколько хранить (N)
# =================================================================

backup_rotate() {
    local backup_dir="$1"
    local prefix="$2"
    local keep="${3:-3}"

    [[ ! -d "$backup_dir" ]] && return 0

    local archives=()
    # -t сортировка по mtime (новые первыми); mapfile — безопасно для пробелов
    mapfile -t archives < <(ls -1t "${backup_dir}/${prefix}"*.tar.gz 2>/dev/null)

    local total=${#archives[@]}
    (( total <= keep )) && return 0

    local removed=0 i
    for (( i = keep; i < total; i++ )); do
        if rm -f -- "${archives[$i]}"; then
            print_info "Ротация: удален старый архив $(basename "${archives[$i]}")" >&2
            ((removed++))
        else
            print_warning "Не удалось удалить ${archives[$i]}" >&2
        fi
    done

    if (( removed > 0 )); then
        print_info "Ротация завершена: удалено ${removed}, хранится ${keep}." >&2
    fi
    return 0
}

# =================================================================
# ПОЛНЫЙ БЭКАП ПРОЕКТА (файлы + база данных) [ISSUE 3]
#
# Состав архива:
#   <project_name>/          — файлы проекта (с исключениями ниже);
#   <project_name>_db.sql.gz — дамп БД через ddev export-db.
#
# ИСКЛЮЧЕНИЯ из файловой части:
#   .ddev/.importdb, .ddev-db-snapshots  — временные данные DDEV;
#   .ddev-backups, backups               — папки вывода бэкапов;
#   node_modules, vendor                 — тяжелые зависимости;
#   .git                                 — VCS-история.
#
# Имя архива: FULL_<project>_<YYYY-MM-DD>_<HHMMSS>.tar.gz
#
# АРГУМЕНТЫ:
#   $1 — project_name
#   $2 — project_path
#   $3 — backup_dir   (опционально; по умолчанию full_backup_path из конфига)
#   $4 — keep_count   (опционально; по умолчанию full_backup_keep из конфига)
#
# STDOUT: путь к архиву. RETURN: 0/1.
# =================================================================

project_full_backup() {
    local project_name="$1"
    local project_path="$2"
    local backup_dir="${3:-$(get_config "full_backup_path" "$(get_config 'workspace_root')/backups")}"
    local keep_count="${4:-$(get_config "full_backup_keep" "3")}"

    # --- Валидация входа ---
    validate_directory "$project_path" "Директория проекта" || return 1
    validate_non_empty "$project_name" "Имя проекта" || return 1

    if ! command -v tar >/dev/null 2>&1; then
        print_error "tar не найден в PATH — создание архива невозможно."
        return 1
    fi

    ensure_directory "$backup_dir"

    # --- Подготовка имен ---
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H%M%S")
    local archive_file="${backup_dir}/FULL_${project_name}_${timestamp}.tar.gz"

    # Временная директория для дампа БД (удаляется по выходу из функции)
    local tmpdir
    tmpdir=$(create_temp_dir) || { print_error "Не удалось создать временную директорию."; return 1; }
    local db_dump="${tmpdir}/${project_name}_db.sql.gz"
    trap 'rm -rf "$tmpdir" 2>/dev/null' RETURN

    print_header "Полный бэкап проекта '$project_name'"

    # --- Шаг 1: Дамп базы данных ---
    print_step "1/3" "Экспорт базы данных"
    if ! db_export "$db_dump" "$project_path" "true"; then
        print_warning "Дамп БД не создан. Архив будет содержать ТОЛЬКО файлы проекта."
        db_dump=""
    fi

    # --- Шаг 2: Архивация файлов проекта ---
    print_step "2/3" "Архивация файлов проекта"

    # Паттерны без слэша исключают каталог с ЛЮБЫМ уровнем вложенности
    # (GNU tar и BSD tar ведут себя одинаково для таких паттернов).
    local -a excludes=(
        --exclude='.ddev/.importdb'
        --exclude='.ddev-db-snapshots'
        --exclude='.ddev-backups'
        --exclude='backups'
        --exclude='node_modules'
        --exclude='vendor'
        --exclude='.git'
    )

    # Сборка аргументов tar:
    #   -C projects_base  -> внутрь архива кладем папку <project_name>/
    #   -C tmpdir         -> рядом кладем дамп БД
    local -a tar_args=()
    local exclude
    for exclude in "${excludes[@]}"; do
        tar_args+=("$exclude")
    done
    tar_args+=(-czf "$archive_file")

    local projects_base
    projects_base=$(dirname "$project_path")

    if [[ -n "$db_dump" ]]; then
        (
            cd "$projects_base" || exit 1
            tar "${tar_args[@]}" "$project_name" -C "$tmpdir" "$(basename "$db_dump")"
        ) >/dev/null 2>&1
    else
        (
            cd "$projects_base" || exit 1
            tar "${tar_args[@]}" "$project_name"
        ) >/dev/null 2>&1
    fi

    if [[ $? -ne 0 || ! -f "$archive_file" ]]; then
        print_error "Ошибка создания архива: $archive_file"
        rm -f "$archive_file" 2>/dev/null
        return 1
    fi

    # --- Шаг 3: Верификация целостности ---
    print_step "3/3" "Проверка целостности архива"
    if ! tar -tzf "$archive_file" >/dev/null 2>&1; then
        print_error "Архив поврежден (tar -tzf вернул ошибку)."
        rm -f "$archive_file" 2>/dev/null
        return 1
    fi

    # --- Ротация ---
    backup_rotate "$backup_dir" "FULL_${project_name}_" "$keep_count"

    # --- Итог ---
    # [FIX] du вместо stat: кроссплатформенность (GNU/BSD), awk вместо cut
    local archive_size
    archive_size=$(du -h "$archive_file" 2>/dev/null | awk '{print $1}')

    print_success "Архив создан: $archive_file ($archive_size)"
    echo "$archive_file"
    return 0
}

# =================================================================
# ЭКСПОРТ ФУНКЦИЙ
# =================================================================

export -f project_full_backup backup_rotate
