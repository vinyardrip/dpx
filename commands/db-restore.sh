#!/usr/bin/env bash
# =================================================================
# DPX Command: db-restore - Restor database from local backup
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/database.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/ddev.sh"

cmd_db_restore() {
    parse_args "$@" || return 1
    print_header "Restor bases data v1.3.0"

    # 1. Selection project
    local project_name
    project_name=$(projects_select_interactive "Select project for restor database")
    [[ -z "$project_name" ]] && return 1

    local project_path
    project_path=$(projects_get_path "$project_name")

    # 2. Search available backups in db_local
    local backup_dir=$(get_db_local_path)
    if [[ ! -d "$backup_dir" ]]; then
        print_error "Director backups not found: $backup_dir"
        return 1
    fi

    # [FIX] Safe reading files in array (works with paths with whitespaces)
    # mapfile reads line-by-line, not split by by spaces as $(...)
    local files=()
    mapfile -t files < <(ls -1t "${backup_dir}/${project_name}"* 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warning "Backups for project '$project_name' not founds in $backup_dir"
        return 1
    fi

    # 3. Interactive selection file
    print_info "Available backups (first new):"
    local i=1
    local display_files=()
    for f in "${files[@]}"; do
        local filename=$(basename "$f")
        # [FIX] awk instead cut - cross-platform compatibility (BSD/GNU du)
        local fsize=$(du -h "$f" | awk '{print $1}')
        echo "$i. $filename ($fsize)"
        display_files+=("$f")
        ((i++))
    done

    local choice
    # [FIX] Removed redundant >&2 (read -p already prints in stderr)
    read -r -p "Select number file for import [1]: " choice
    choice="${choice:-1}"

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#display_files[@]} )); then
        print_error "Invalid selection"
        return 1
    fi

    local selected_file="${display_files[$((choice-1))]}"

    # 4. Check status DDEV
    if ! ddev_is_project_running "$project_name"; then
        confirm "Project '$project_name' not run. Start?" && safe_start_ddev_project "$project_name" "$project_path" || return 1
    fi

    # 5. Execut import
    if confirm "Yous confidents, that want REPLACE base data project '$project_name' file $(basename "$selected_file")?"; then
        # Creat protective backup current state before import
        print_info "Creat protective dump current database..."
        local backup_file
        backup_file=$(db_backup_local "$project_name" "$project_path") || { print_error "Not remove creat protective backup. Cancel."; return 1; }
        print_success "Protective dump saved: $(basename "$backup_file")"

        print_info "Begin import..."

        # [ISSUE 1] Type CMS: from arguments (--cms-type) ors autodetection.
        # Page determin UNTIL import — from result depends post-processing.
        local cms_type
        cms_type=$(get_arg "cms_type" "")
        if [[ -z "$cms_type" ]]; then
            cms_type=$(detect_cms_type "$project_path")
            print_info "Type CMS defin automatics: $(get_cms_name "$cms_type")"
        fi

        # Execute in subshell for isolations cd
        (
            cd "$project_path" || exit 1

            if db_import "$selected_file" "$project_path"; then
                print_success "Base data success restor!"

                # [ISSUE 1] Post-processing PAGE by type CMS.
                # WordPress-routine (wp-cli) performs only for wordpress;
                # Joomla/OpenCart/PHP receive with action and message.
                db_post_import_cms "$project_path" "$cms_type"
            else
                print_error "Error durings restors bases."
                exit 1
            fi
        ) || return 1
    fi
}