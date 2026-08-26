#!/usr/bin/env bash
# =================================================================
# DPX Args Module - parsing arguments command lines
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_ARGS_LOADED:-}" ]] && return 0
readonly _DPX_ARGS_LOADED=1

# =================================================================
# GLOBAL ARRAY ARGUMENTS
# =================================================================

declare -A DPX_ARGS
declare -a DPX_POSITIONAL

# =================================================================
# PARSING ARGUMENTS
# =================================================================

parse_args() {
    # Flushed previous value
    DPX_ARGS=()
    DPX_POSITIONAL=()

    local arg_pair arg_key arg_val

    while [[ $# -gt 0 ]]; do
        # [FIX v1.4.27] Support format --key=value (--project-name=mysite).
        # Processes UNTIL case: key normalizes (hyphens -> underscore),
        # value keeps as consumes. Flags without value ("=1") still
        # page validate lower.
        if [[ "$1" == --*=* ]]; then
            arg_pair="${1#--}"
            arg_key="${arg_pair%%=*}"
            arg_val="${arg_pair#*=}"

            if [[ -z "$arg_key" ]]; then
                print_error "Invalid parameter: $1"
                return 1
            fi

            DPX_ARGS["${arg_key//-/_}"]="$arg_val"
            shift
            continue
        fi

        case "$1" in
            # Flags without value
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

            # Parameters with values
            --php-version)
                [[ -n "${2:-}" ]] || { print_error "--php-version $(t err.requires.arg)"; return 1; }
                DPX_ARGS["php_version"]="$2"
                shift 2
                ;;
            --db-type)
                [[ -n "${2:-}" ]] || { print_error "--db-type $(t err.requires.arg)"; return 1; }
                DPX_ARGS["db_type"]="$2"
                shift 2
                ;;
            --db-version)
                [[ -n "${2:-}" ]] || { print_error "--db-version $(t err.requires.arg)"; return 1; }
                DPX_ARGS["db_version"]="$2"
                shift 2
                ;;
            --project-name)
                [[ -n "${2:-}" ]] || { print_error "--project-name $(t err.requires.arg)"; return 1; }
                DPX_ARGS["project_name"]="$2"
                shift 2
                ;;
            --cms-type)
                [[ -n "${2:-}" ]] || { print_error "--cms-type $(t err.requires.arg)"; return 1; }
                DPX_ARGS["cms_type"]="$2"
                shift 2
                ;;
            --prod-url)
                [[ -n "${2:-}" ]] || { print_error "--prod-url $(t err.requires.arg)"; return 1; }
                DPX_ARGS["prod_url"]="$2"
                shift 2
                ;;
            --db-file)
                [[ -n "${2:-}" ]] || { print_error "--db-file $(t err.requires.arg)"; return 1; }
                DPX_ARGS["db_file"]="$2"
                shift 2
                ;;
            --devilbox-folder)
                [[ -n "${2:-}" ]] || { print_error "--devilbox-folder $(t err.requires.arg)"; return 1; }
                DPX_ARGS["devilbox_folder"]="$2"
                shift 2
                ;;
            --devilbox-php)
                [[ -n "${2:-}" ]] || { print_error "--devilbox-php $(t err.requires.arg)"; return 1; }
                DPX_ARGS["devilbox_php"]="$2"
                shift 2
                ;;
            --db-name)
                [[ -n "${2:-}" ]] || { print_error "--db-name $(t err.requires.arg)"; return 1; }
                DPX_ARGS["db_name"]="$2"
                shift 2
                ;;
            --sort-by)
                [[ -n "${2:-}" ]] || { print_error "--sort-by $(t err.requires.arg)"; return 1; }
                DPX_ARGS["sort_by"]="$2"
                shift 2
                ;;
            --format)
                [[ -n "${2:-}" ]] || { print_error "--format $(t err.requires.arg)"; return 1; }
                DPX_ARGS["format"]="$2"
                shift 2
                ;;
            --admin-user)
                [[ -n "${2:-}" ]] || { print_error "--admin-user $(t err.requires.arg)"; return 1; }
                DPX_ARGS["admin_user"]="$2"
                shift 2
                ;;
            --admin-pass)
                [[ -n "${2:-}" ]] || { print_error "--admin-pass $(t err.requires.arg)"; return 1; }
                DPX_ARGS["admin_pass"]="$2"
                shift 2
                ;;
            --admin-email)
                [[ -n "${2:-}" ]] || { print_error "--admin-email $(t err.requires.arg)"; return 1; }
                DPX_ARGS["admin_email"]="$2"
                shift 2
                ;;
            --locale)
                [[ -n "${2:-}" ]] || { print_error "--locale $(t err.requires.arg)"; return 1; }
                DPX_ARGS["locale"]="$2"
                shift 2
                ;;
            --prod-tld)
                [[ -n "${2:-}" ]] || { print_error "--prod-tld $(t err.requires.arg)"; return 1; }
                DPX_ARGS["prod_tld"]="$2"
                shift 2
                ;;
            --php-max)
                [[ -n "${2:-}" ]] || { print_error "--php-max $(t err.requires.arg)"; return 1; }
                DPX_ARGS["php_max"]="$2"
                shift 2
                ;;
            --notes)
                [[ -n "${2:-}" ]] || { print_error "--notes $(t err.requires.arg)"; return 1; }
                DPX_ARGS["notes"]="$2"
                shift 2
                ;;
            --provider)
                [[ -n "${2:-}" ]] || { print_error "--provider $(t err.requires.arg)"; return 1; }
                DPX_ARGS["provider"]="$2"
                shift 2
                ;;
            --output)
                [[ -n "${2:-}" ]] || { print_error "--output $(t err.requires.arg)"; return 1; }
                DPX_ARGS["output"]="$2"
                shift 2
                ;;
            --keep)
                [[ -n "${2:-}" ]] || { print_error "--keep $(t err.requires.arg)"; return 1; }
                DPX_ARGS["keep"]="$2"
                shift 2
                ;;
            --cms|--type)
                [[ -n "${2:-}" ]] || { print_error "$1 requires argument"; return 1; }
                DPX_ARGS["cms"]="$2"
                shift 2
                ;;
            --php)
                [[ -n "${2:-}" ]] || { print_error "--php $(t err.requires.arg)"; return 1; }
                DPX_ARGS["php_version"]="$2"
                shift 2
                ;;
            --db)
                DPX_ARGS["db"]=1
                shift
                ;;
            --projects-root)
                [[ -n "${2:-}" ]] || { print_error "--projects-root requires an argument"; return 1; }
                DPX_ARGS["projects_root"]="$2"
                shift 2
                ;;
            --lang)
                [[ -n "${2:-}" ]] || { print_error "--lang requires an argument"; return 1; }
                DPX_ARGS["lang"]="$2"
                shift 2
                ;;
            --db-user)
                [[ -n "${2:-}" ]] || { print_error "--db-user requires an argument"; return 1; }
                DPX_ARGS["db_user"]="$2"
                shift 2
                ;;
            --db-password)
                [[ -n "${2:-}" ]] || { print_error "--db-password requires an argument"; return 1; }
                DPX_ARGS["db_password"]="$2"
                shift 2
                ;;

            # Unknown parameters
            -*)
                print_error "Unknown parameter: $1"
                return 1
                ;;

            # Positional arguments (save in array)
            *)
                DPX_POSITIONAL+=("$1")
                shift
                ;;
        esac
    done

    return 0
}

# =================================================================
# ACCESSORS
# =================================================================

# Get named argument
get_arg() {
    local key="$1"
    local default="${2:-}"
    echo "${DPX_ARGS[$key]:-$default}"
}

# Verify presence flag
has_arg() {
    local key="$1"

    # [FIX v1.4.27] Argument considers passed durings ANY non-empty values:
    #   - flags stores "1" (--yes);
    #   - options with values — with value (--php-version 8.1).
    # Old check == "1" returned false for value-option, because of what
    # calls kind "! has_arg php_version" (migrate, deploy, refresh:prod_tld)
    # repeat requesteds interactive input durings ALREADY passed flag.
    [[ -n "${DPX_ARGS[$key]:-}" ]]
}

# Get positional argument by index (begin with 1)
get_positional_arg() {
    local index="$1"
    local default="${2:-}"
    echo "${DPX_POSITIONAL[$((index-1))]:-$default}"
}

# Get count positional arguments
count_positional_args() {
    echo "${#DPX_POSITIONAL[@]}"
}

# Get all positional arguments line
get_positional_args() {
    echo "${DPX_POSITIONAL[*]:-}"
}

# Verify presence positional argument
has_positional_args() {
    [[ ${#DPX_POSITIONAL[@]} -gt 0 ]]
}