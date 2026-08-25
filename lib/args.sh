#!/usr/bin/env bash
# =================================================================
# DPX Args Module - парсинг аргументов командной строки
# =================================================================

# Защита от повторного подключения
[[ -n "${_DPX_ARGS_LOADED:-}" ]] && return 0
readonly _DPX_ARGS_LOADED=1

# =================================================================
# ГЛОБАЛЬНЫЙ МАССИВ АРГУМЕНТОВ
# =================================================================

declare -A DPX_ARGS
declare -a DPX_POSITIONAL

# =================================================================
# ПАРСИНГ АРГУМЕНТОВ
# =================================================================

parse_args() {
    # Очищаем предыдущие значения
    DPX_ARGS=()
    DPX_POSITIONAL=()

    local arg_pair arg_key arg_val

    while [[ $# -gt 0 ]]; do
        # [FIX v1.4.27] Поддержка формата --key=value (--project-name=mysite).
        # Обрабатывается ДО case: ключ нормализуется (дефисы -> подчеркивания),
        # значение сохраняется как есть. Флаги без значения ("=1") по-прежнему
        # строго валидируются ниже.
        if [[ "$1" == --*=* ]]; then
            arg_pair="${1#--}"
            arg_key="${arg_pair%%=*}"
            arg_val="${arg_pair#*=}"

            if [[ -z "$arg_key" ]]; then
                print_error "Некорректный параметр: $1"
                return 1
            fi

            DPX_ARGS["${arg_key//-/_}"]="$arg_val"
            shift
            continue
        fi

        case "$1" in
            # Флаги без значений
            -h|--help)
                DPX_ARGS["help"]=1
                shift
                ;;
            -v|--version)
                DPX_ARGS["version"]=1
                shift
                ;;
            -q|--quiet)
                DPX_ARGS["quiet"]=1
                shift
                ;;
            -y|--yes)
                DPX_ARGS["yes"]=1
                shift
                ;;
            --group)
                DPX_ARGS["group"]=1
                shift
                ;;
            --no-db)
                DPX_ARGS["no_db"]=1
                shift
                ;;
            --no-backup)
                DPX_ARGS["no_backup"]=1
                shift
                ;;
            --keep-backup)
                DPX_ARGS["keep_backup"]=1
                shift
                ;;
            --no-theme)
                DPX_ARGS["no_theme"]=1
                shift
                ;;
            --list)
                DPX_ARGS["list"]=1
                shift
                ;;
            --restart)
                DPX_ARGS["restart"]=1
                shift
                ;;
            --show)
                DPX_ARGS["show"]=1
                shift
                ;;
            --delete)
                DPX_ARGS["delete"]=1
                shift
                ;;

            # Параметры со значениями
            --php-version)
                [[ -n "${2:-}" ]] || { print_error "--php-version требует аргумент"; return 1; }
                DPX_ARGS["php_version"]="$2"
                shift 2
                ;;
            --db-type)
                [[ -n "${2:-}" ]] || { print_error "--db-type требует аргумент"; return 1; }
                DPX_ARGS["db_type"]="$2"
                shift 2
                ;;
            --db-version)
                [[ -n "${2:-}" ]] || { print_error "--db-version требует аргумент"; return 1; }
                DPX_ARGS["db_version"]="$2"
                shift 2
                ;;
            --project-name)
                [[ -n "${2:-}" ]] || { print_error "--project-name требует аргумент"; return 1; }
                DPX_ARGS["project_name"]="$2"
                shift 2
                ;;
            --cms-type)
                [[ -n "${2:-}" ]] || { print_error "--cms-type требует аргумент"; return 1; }
                DPX_ARGS["cms_type"]="$2"
                shift 2
                ;;
            --prod-url)
                [[ -n "${2:-}" ]] || { print_error "--prod-url требует аргумент"; return 1; }
                DPX_ARGS["prod_url"]="$2"
                shift 2
                ;;
            --db-file)
                [[ -n "${2:-}" ]] || { print_error "--db-file требует аргумент"; return 1; }
                DPX_ARGS["db_file"]="$2"
                shift 2
                ;;
            --devilbox-folder)
                [[ -n "${2:-}" ]] || { print_error "--devilbox-folder требует аргумент"; return 1; }
                DPX_ARGS["devilbox_folder"]="$2"
                shift 2
                ;;
            --devilbox-php)
                [[ -n "${2:-}" ]] || { print_error "--devilbox-php требует аргумент"; return 1; }
                DPX_ARGS["devilbox_php"]="$2"
                shift 2
                ;;
            --db-name)
                [[ -n "${2:-}" ]] || { print_error "--db-name требует аргумент"; return 1; }
                DPX_ARGS["db_name"]="$2"
                shift 2
                ;;
            --sort-by)
                [[ -n "${2:-}" ]] || { print_error "--sort-by требует аргумент"; return 1; }
                DPX_ARGS["sort_by"]="$2"
                shift 2
                ;;
            --format)
                [[ -n "${2:-}" ]] || { print_error "--format требует аргумент"; return 1; }
                DPX_ARGS["format"]="$2"
                shift 2
                ;;
            --admin-user)
                [[ -n "${2:-}" ]] || { print_error "--admin-user требует аргумент"; return 1; }
                DPX_ARGS["admin_user"]="$2"
                shift 2
                ;;
            --admin-pass)
                [[ -n "${2:-}" ]] || { print_error "--admin-pass требует аргумент"; return 1; }
                DPX_ARGS["admin_pass"]="$2"
                shift 2
                ;;
            --admin-email)
                [[ -n "${2:-}" ]] || { print_error "--admin-email требует аргумент"; return 1; }
                DPX_ARGS["admin_email"]="$2"
                shift 2
                ;;
            --locale)
                [[ -n "${2:-}" ]] || { print_error "--locale требует аргумент"; return 1; }
                DPX_ARGS["locale"]="$2"
                shift 2
                ;;
            --prod-tld)
                [[ -n "${2:-}" ]] || { print_error "--prod-tld требует аргумент"; return 1; }
                DPX_ARGS["prod_tld"]="$2"
                shift 2
                ;;
            --php-max)
                [[ -n "${2:-}" ]] || { print_error "--php-max требует аргумент"; return 1; }
                DPX_ARGS["php_max"]="$2"
                shift 2
                ;;
            --notes)
                [[ -n "${2:-}" ]] || { print_error "--notes требует аргумент"; return 1; }
                DPX_ARGS["notes"]="$2"
                shift 2
                ;;
            --provider)
                [[ -n "${2:-}" ]] || { print_error "--provider требует аргумент"; return 1; }
                DPX_ARGS["provider"]="$2"
                shift 2
                ;;
            --output)
                [[ -n "${2:-}" ]] || { print_error "--output требует аргумент"; return 1; }
                DPX_ARGS["output"]="$2"
                shift 2
                ;;
            --keep)
                [[ -n "${2:-}" ]] || { print_error "--keep требует аргумент"; return 1; }
                DPX_ARGS["keep"]="$2"
                shift 2
                ;;
            --cms|--type)
                [[ -n "${2:-}" ]] || { print_error "$1 требует аргумент"; return 1; }
                DPX_ARGS["cms"]="$2"
                shift 2
                ;;
            --php)
                [[ -n "${2:-}" ]] || { print_error "--php требует аргумент"; return 1; }
                DPX_ARGS["php_version"]="$2"
                shift 2
                ;;
            --db)
                DPX_ARGS["db"]=1
                shift
                ;;

            # Неизвестные параметры
            -*)
                print_error "Неизвестный параметр: $1"
                return 1
                ;;

            # Позиционные аргументы (сохраняем в массив)
            *)
                DPX_POSITIONAL+=("$1")
                shift
                ;;
        esac
    done

    return 0
}

# =================================================================
# АКСЕССОРЫ
# =================================================================

# Получить именованный аргумент
get_arg() {
    local key="$1"
    local default="${2:-}"
    echo "${DPX_ARGS[$key]:-$default}"
}

# Проверить наличие флага
has_arg() {
    local key="$1"

    # [FIX v1.4.27] Аргумент считается переданным при ЛЮБОМ непустом значении:
    #   - флаги хранят "1" (--yes);
    #   - опции со значениями — свои значения (--php-version 8.1).
    # Старая проверка == "1" возвращала false для value-опций, из-за чего
    # вызовы вида "! has_arg php_version" (migrate, deploy, refresh:prod_tld)
    # повторно запрашивали интерактивный ввод при УЖЕ переданном флаге.
    [[ -n "${DPX_ARGS[$key]:-}" ]]
}

# Получить позиционный аргумент по индексу (начиная с 1)
get_positional_arg() {
    local index="$1"
    local default="${2:-}"
    echo "${DPX_POSITIONAL[$((index-1))]:-$default}"
}

# Получить количество позиционных аргументов
count_positional_args() {
    echo "${#DPX_POSITIONAL[@]}"
}

# Получить все позиционные аргументы строкой
get_positional_args() {
    echo "${DPX_POSITIONAL[*]:-}"
}

# Проверить наличие позиционного аргумента
has_positional_args() {
    [[ ${#DPX_POSITIONAL[@]} -gt 0 ]]
}