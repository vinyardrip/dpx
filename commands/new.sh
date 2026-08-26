#!/usr/bin/env bash
# =================================================================
# DPX Command: new - universal creat projects
#
# Types: wordpress | joomla | opencart | laravel | php
#
# Architecture:
#   new_resolve_type / new_select_type - normalization and selection type;
#   _new_scaffold_*                    - scaffold each type;
#   cmd_new                            - single point input.
#   dpx new-wp - subtle wrapper over cmd_new --cms=wordpress.
# Version: v1.7.0
# =================================================================

source "${DPX_ROOT}/lib/core.sh"
source "${DPX_ROOT}/lib/cms.sh"
source "${DPX_ROOT}/lib/ddev.sh"
source "${DPX_ROOT}/lib/projects.sh"
source "${DPX_ROOT}/lib/devilbox.sh"

# =================================================================
# HELP
# =================================================================

show_new_help() {
    cat << EOF
 ${COLOR_BOLD}new${COLOR_RESET} - Universal project scaffolding (WordPress/Joomla/OpenCart/ocStore/Laravel/PHP)

 ${COLOR_BOLD}Usage:${COLOR_RESET}
    ${TOOL_NAME} new [project-name] [options]

 ${COLOR_BOLD}Description:${COLOR_RESET}
    Single entry point for creating projects on DDEV. Without flags,
    an interactive type selector is shown.

 ${COLOR_BOLD}Project types:${COLOR_RESET}
    1) WordPress        WP-CLI install + starter theme (see also: dpx new-wp)
    2) Joomla           Latest stable release from downloads/GitHub
    3) OpenCart         Official release from GitHub Releases
    4) ocStore          Localized OpenCart fork (SEO Pro built-in)
    5) Laravel          composer create-project + .env wired for DDEV (docroot: public)
    6) Plain PHP        Minimal PHP scaffold (index.php)

 ${COLOR_BOLD}Options:${COLOR_RESET}
    --project-name NAME    New project name (or first positional argument)
    --cms TYPE             Type: wordpress|joomla|opencart|ocstore|laravel|php
                           (alias: --type TYPE, --cms=TYPE, wp/ocs/lara/html)
    --php VERSION          Version PHP (by default from config)
    --db                   Creat base data immediately after start container
    -y, --yes              Skipp confirmation
    -h, --help             Show this help

 ${COLOR_BOLD}Examples:${COLOR_RESET}
    ${TOOL_NAME} new                                   # fully interactive
    ${TOOL_NAME} new myshop --cms=laravel --php=8.3 -y
    ${TOOL_NAME} new blog --type wordpress
    ${TOOL_NAME} new russhop --type=ocstore            # ocStore with SEO Pro
    ${TOOL_NAME} new-wp mysite                         # compatibility (= new --cms=wordpress)
EOF
}

# =================================================================
# PERMISSION TYPE PROJECT
# =================================================================

# Normalization user input in canonical type.
# STDOUT: type ors empty line. Clean function (tested).
new_resolve_type() {
    local input="${1:-}"

    # Normalization: whitespaces by edges -> lower case
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    input="${input,,}"

    case "$input" in
        "" ) return 0 ;;
        1|wp|wordpress)          echo "wordpress" ;;
        2|joomla|jml)            echo "joomla" ;;
        3|oc|opencart)           echo "opencart" ;;
        4|ocs|ocstore)           echo "ocstore" ;;
        5|lara|laravel)          echo "laravel" ;;
        6|php|plain|html|static) echo "php" ;;
        * ) return 0 ;;
    esac
}

# Interactive type selection. Menu -> STDERR, value -> STDOUT.
new_select_type() {
    cat >&2 << MENU

--- Select project type ---
  1) WordPress
  2) Joomla
  3) OpenCart (Official)
  4) ocStore (OpenCart Russia/SEO Pro)
  5) Laravel
  6) Plain PHP / HTML

MENU

    local input resolved=""
    while [[ -z "$resolved" ]]; do
        input=""
        if ! read -r -p "Select [1-6]: " input; then
            print_error "Input aborted (EOF)."
            return 1
        fi
        resolved=$(new_resolve_type "$input")
        if [[ -z "$resolved" ]]; then
            print_warning "Unknown variant '$input'. Enter number ors name."
        fi
    done

    printf '%s\n' "$resolved"
}

# =================================================================
# PRIMITIVES SCAFFOLD (clean file operations — tested)
# =================================================================

# Normalization docroot: ifs content lies in single subdirectory
# (layout kind upload/... at OpenCart), move content on level above.
_new_normalize_docroot() {
    local dir="$1"
    [[ -f "$dir/index.php" ]] && return 0

    local top_dirs top_files sub
    top_dirs=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    top_files=$(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$top_dirs" == "1" && "$top_files" == "0" ]]; then
        sub=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        # dotfiles + files: shopt dotglob local for moved
        (
            shopt -s dotglob nullglob
            mv -- "$sub"/* "$dir"/ 2>/dev/null
        )
        rmdir "$sub" 2>/dev/null || true
        print_info "Docroot normalized: content '$(basename "$sub")' raised in root."
    fi
    return 0
}

# Portable upsert KEY=value in .env-similar file (BSD/GNU sed).
_new_env_set_kv() {
    local env_file="$1" key="$2" value="$3"

    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
        safe_sed_inplace "s|^${key}=.*|${key}=${value}|g" "$env_file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

# Download archive: curl with retries, fallback wget.
_new_archive_fetch() {
    local url="$1" dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 15 -o "$dest" "$url" >/dev/null 2>&1 && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -t 2 -O "$dest" "$url" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# Resolver URL last release CMS-archive.
#
# Strategies:
#   1) env-override: DPX_JOOMLA_ARCHIVE_URL / DPX_OPENCART_ARCHIVE_URL;
#   2) GitHub API releases/latest -> suitable asset;
#   3) codeload source-archive (with warning).
# STDOUT: URL lib empty (caller solves).
_new_resolve_archive_url() {
    local cms_type="$1"
    local repo="" asset_pattern="" source_fallback="" env_var=""

    case "$cms_type" in
        joomla)
            repo="Joomla/Joomla-CMS"
            asset_pattern='Full_Package.*\.tar\.gz'
            source_fallback="https://github.com/Joomla/Joomla-CMS/archive/refs/heads/latest.tar.gz"
            env_var="DPX_JOOMLA_ARCHIVE_URL"
            ;;
        opencart)
            repo="opencart/opencart"
            asset_pattern='opencart.*\.zip'
            source_fallback="https://github.com/opencart/opencart/archive/refs/heads/master.zip"
            env_var="DPX_OPENCART_ARCHIVE_URL"
            ;;
        ocstore)
            repo="myopencart/ocstore"
            asset_pattern='(?i)ocstore.*\.zip'
            source_fallback="https://github.com/myopencart/ocstore/archive/refs/heads/master.zip"
            env_var="DPX_OCSTORE_ARCHIVE_URL"
            ;;
        *) return 1 ;;
    esac

    # 1) Explicit override user/environment
    if [[ -n "${!env_var:-}" ]]; then
        printf '%s\n' "${!env_var}"
        return 0
    fi

    local api_json=""
    api_json=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || api_json=""

    # 2) Asset from official release
    if [[ -n "$api_json" ]]; then
        local url=""
        url=$(printf '%s' "$api_json" \
            | jq -r --arg pat "$asset_pattern" \
                '[.assets[]? | select(.name | test($pat))][0].browser_download_url // empty' 2>/dev/null)
        if [[ -n "$url" && "$url" != "null" ]]; then
            printf '%s\n' "$url"
            return 0
        fi
    fi

    # 3) Source-archive (may requirement composer build — warn)
    if [[ -n "$source_fallback" ]]; then
        print_warning "Release-asset not found; use source-archive ${repo}."
        print_warning "Ifs scaffold not will work, specify ${env_var}=<URL ready package>."
        printf '%s\n' "$source_fallback"
        return 0
    fi

    return 1
}

# Download and unpacking archive in workdir + normalization docroot.
_new_archive_download_unpack() {
    local url="$1" workdir="$2"

    local ext="${url##*.}"
    local archive="$workdir/pkg.${ext}"

    print_step "auto" "Download archive..."
    if ! _new_archive_fetch "$url" "$archive"; then
        print_error "Not remove download: $url"
        return 1
    fi

    # Sanities: archive not may was tiny
    local size
    size=$(wc -c < "$archive" 2>/dev/null | tr -d ' ')
    if [[ -z "$size" ]] || (( size < 10240 )); then
        print_error "Downloaded file suspicious small (${size:-0} bytes). Cancel."
        return 1
    fi

    print_step "auto" "Unpacking..."
    case "$ext" in
        zip)
            if ! command -v unzip >/dev/null 2>&1; then
                print_error "unzip not found (needed for zip-archives)."
                return 1
            fi
            unzip -q -o "$archive" -d "$workdir" || return 1
            ;;
        tar.gz|tgz|gz)
            tar -xzf "$archive" -C "$workdir" || return 1
            ;;
        *)
            print_error "Unsupported format archive: .$ext"
            return 1
            ;;
    esac
    rm -f "$archive"

    _new_normalize_docroot "$workdir"
}

# Creat database (flag --db): name from config CMS ors name project.
_new_provision_db() {
    local project_name="$1" project_path="$2" cms_type="$3"

    local db_name
    db_name=$(db_get_db_name "$project_path" "$cms_type" 2>/dev/null) || db_name=""
    db_name="${db_name//[^a-zA-Z0-9_]/_}"
    [[ -z "$db_name" ]] && db_name="${project_name//-/_}"

    print_step "auto" "Creat bases data '${db_name}'..."
    if ddev mysql -e "CREATE database IF NOT EXISTS \`${db_name}\`;" >/dev/null 2>&1; then
        print_success "database '${db_name}' ready."
    else
        print_warning "Not remove creat database (container database could yet initialize)."
    fi
}

# =================================================================
# SCAFFOLDS BY TYPES
# =================================================================

# WordPress: logic moved verbatim from the legacy new-wp.sh.
_new_scaffold_wordpress() {
    local project_name="$1" project_path="$2" php_version="$3" use_theme="${4:-yes}"

    local site_url
    site_url="https://${project_name}.$(get_config 'project_tld')"
    local locale admin_user admin_pass admin_email
    locale=$(get_arg "locale" "ru_RU")
    admin_user=$(get_arg "admin_user" "$(get_config 'admin_user')")
    admin_pass=$(get_arg "admin_pass" "$(get_config 'admin_pass')")
    admin_email=$(get_arg "admin_email" "$(get_config 'admin_email')")

    print_step "2" "Configuration and start DDEV"
    if ! ddev config --project-type wordpress --docroot "" \
            --project-tld "$(get_config 'project_tld')" \
            --php-version "$php_version" 2>&1; then
        print_error "Error configurations DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Error start DDEV"
        return 1
    fi

    print_step "3" "Install WordPress via WP-CLI"
    if ! ddev_wp_install "$project_path" "$site_url" \
            "New site ${project_name}" "$admin_user" "$admin_pass" "$admin_email" "$locale"; then
        print_error "Error installs WordPress"
        return 1
    fi

    local starter_theme_path
    starter_theme_path=$(get_config "starter_theme_path")

    if [[ "$use_theme" == "yes" ]] && [[ -d "$starter_theme_path" ]]; then
        print_step "4" "Copi and activation started thens '${project_name}'"

        local theme_dir="wp-content/themes/${project_name}"
        cp -r "${starter_theme_path}/." "$theme_dir"

        if [[ ! -f "${theme_dir}/style.css" ]]; then
            cat > "${theme_dir}/style.css" << EOF
/*
Theme Name: ${project_name}
Author: Auto-generated by ${TOOL_NAME}
Version: 1.0
*/
EOF
            print_success "File style.css creat automatics."
        fi

        ddev wp theme activate "$project_name" 2>&1 || {
            print_warning "Not remove activated then."
        }
        ddev_wp_theme_delete "twentytwentytwo twentytwentythree twentytwentyfour" "$project_path"
    elif [[ "$use_theme" == "yes" ]]; then
        print_warning "Started then not found (${starter_theme_path}). Step skipped."
    fi

    print_step "5" "Cleanup standard plugins"
    ddev_wp_plugin_delete "akismet hello" "$project_path"

    print_celebration "WordPress project '${project_name}' creat!"
    print_highlight "Admin panel: ${site_url}/wp-admin/ (login: ${admin_user})"
    return 0
}

# Joomla / OpenCart: download release + DDEV project_type=php.
_new_scaffold_archive_cms() {
    local cms_type="$1" project_name="$2" project_path="$3" php_version="$4"

    local archive_url
    archive_url=$(_new_resolve_archive_url "$cms_type") || archive_url=""
    if [[ -z "$archive_url" ]]; then
        print_error "Not remove determin URL release ${cms_type}."
        print_info  "Specify DPX_${cms_type^^}_ARCHIVE_URL=<URL archive> and retry."
        return 1
    fi
    print_info "Release: $archive_url"

    local tmpdir
    tmpdir=$(create_temp_dir) || { print_error "No temporary directors."; return 1; }
    trap 'rm -rf "$tmpdir" 2>/dev/null' RETURN

    if ! _new_archive_download_unpack "$archive_url" "$tmpdir"; then
        print_error "Error downloads/unpackings ${cms_type}."
        return 1
    fi

    # Move unpacked content in director project
    (
        shopt -s dotglob nullglob
        mv -- "$tmpdir"/* "$project_path"/ 2>/dev/null
    )

    print_step "auto" "Configuration DDEV (project_type: php)"
    if ! ddev_configure_project "$project_name" "php" "$php_version" \
            "$(get_config 'default_db_type')" "$(get_config 'default_db_version')" \
            "" "$(get_config 'project_tld')"; then
        print_error "Error configurations DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Error start DDEV"
        return 1
    fi

    case "$cms_type" in
        joomla)   print_info "Gave open site in browser and complete install (/installation)." ;;
        opencart) print_info "Gave open site in browser and complete install (/install)." ;;
        ocstore)  print_info "Gave open site in browser, complete install (/install) and enable SEO Pro." ;;
    esac
    return 0
}

# Laravel: project_type=laravel, docroot=public, composer + .env under DDEV.
_new_laravel_env_rewrite() {
    local env_file="$1" app_url="$2"

    [[ -f "$env_file" ]] || { print_error ".env not found after create-project."; return 1; }

    _new_env_set_kv "$env_file" "DB_HOST" "db"
    _new_env_set_kv "$env_file" "DB_DATABASE" "db"
    _new_env_set_kv "$env_file" "DB_USERNAME" "db"
    _new_env_set_kv "$env_file" "DB_PASSWORD" "db"
    _new_env_set_kv "$env_file" "APP_URL" "$app_url"
    _new_env_set_kv "$env_file" "APP_ENV" "local"

    print_success ".env configured under DDEV (db/db/db)."
    return 0
}

_new_scaffold_laravel() {
    local project_name="$1" project_path="$2" php_version="$3"

    print_step "2" "Configuration DDEV (project_type: laravel, docroot: public)"
    if ! ddev_configure_project "$project_name" "laravel" "$php_version" \
            "$(get_config 'default_db_type')" "$(get_config 'default_db_version')" \
            "public" "$(get_config 'project_tld')"; then
        print_error "Error configurations DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Error start DDEV"
        return 1
    fi

    # composer create-project requires empty directory: puts in temporary
    # subfolder and brings up content (include dotfiles: .env, .gitignore).
    print_step "3" "composer create-project laravel/laravel (this take time)..."
    if ! ddev composer create-project --no-interaction --prefer-dist \
            laravel/laravel _app_tmp; then
        print_error "composer create-project failed."
        rm -rf "_app_tmp"
        return 1
    fi

    (
        shopt -s dotglob nullglob
        mv -- _app_tmp/* . 2>/dev/null
    )
    rmdir _app_tmp 2>/dev/null || true

    local site_url
    site_url="https://${project_name}.$(get_config 'project_tld')"
    if ! _new_laravel_env_rewrite "${project_path}/.env" "$site_url"; then
        return 1
    fi

    print_celebration "Laravel project '${project_name}' creat!"
    print_highlight "Migrations:  ddev artisan migrate"
    print_highlight "URL:       ${site_url}"
    return 0
}

# Plain PHP: minimum scaffold + optional database (--db).
_new_scaffold_php() {
    local project_name="$1" project_path="$2" php_version="$3"

    cat > index.php << EOF
<?php
phpinfo();
EOF

    print_step "2" "Configuration DDEV (project_type: php)"
    if ! ddev_configure_project "$project_name" "php" "$php_version" \
            "$(get_config 'default_db_type')" "$(get_config 'default_db_version')" \
            "" "$(get_config 'project_tld')"; then
        print_error "Error configurations DDEV"
        return 1
    fi

    if ! safe_start_ddev_project "$project_name" "$project_path"; then
        print_error "Error start DDEV"
        return 1
    fi

    if has_arg "db"; then
        _new_provision_db "$project_name" "$project_path" "php"
    fi

    print_celebration "PHP project '${project_name}' creat!"
    return 0
}

# =================================================================
# MAIN FUNCTION
# =================================================================

cmd_new() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_new_help
        return 0
    fi

    print_header "Creat new project"

    # --- Name project: positional argument ors interactive ---
    local project_name
    project_name=$(get_positional_arg 1 "")
    [[ -z "$project_name" ]] && project_name=$(get_arg "project_name" "")

    if [[ -z "$project_name" ]]; then
        prompt_input "1. Name new project (e.g., my-cool-site)" "" project_name
    fi
    validate_project_name "$project_name" || return 1

    local project_path="${PROJECTS_ROOT}/${project_name}"
    if [[ -d "$project_path" ]]; then
        print_error "Director already exist: $project_path"
        return 1
    fi

    # --- Type project: --cms/--type (=value and separate forms), otherwise menu ---
    local cms_type
    cms_type=$(new_resolve_type "$(get_arg "cms" "")")
    if [[ -z "$cms_type" ]]; then
        cms_type=$(new_resolve_type "$(get_arg "type" "")")
    fi
    if [[ -z "$cms_type" ]]; then
        cms_type=$(new_select_type) || return 1
    fi
    print_success "Type project: $(get_cms_name "$cms_type")"

    local php_version
    php_version=$(get_arg "php_version" "$(get_config 'default_php_version')")
    if ! has_arg "project_name" && [[ $# -eq 0 ]]; then
        prompt_input "Version PHP" "$php_version" php_version
    fi

    local use_theme="yes"
    has_arg "no_theme" && use_theme="no"

    local site_url
    site_url="https://${project_name}.$(get_config 'project_tld')"

    print_header "Verify parameters"
    echo "Name project:      ${COLOR_GREEN}${project_name}${COLOR_RESET}"
    echo "Type:              ${COLOR_GREEN}$(get_cms_name "$cms_type")${COLOR_RESET}"
    echo "URL site:        ${COLOR_GREEN}${site_url}${COLOR_RESET}"
    echo "Version PHP:       ${COLOR_GREEN}${php_version}${COLOR_RESET}"
    echo "Base data (--db): ${COLOR_GREEN}$(has_arg 'db' && echo 'yes' || echo 'no')${COLOR_RESET}"
    echo "Path:             ${COLOR_GREEN}${project_path}${COLOR_RESET}"
    print_separator

    if ! has_arg "yes"; then
        confirm "Creat project?" || return 1
    fi

    devilbox_stop

    mkdir -p "$project_path" || { print_error "Not remove creat director."; return 1; }

    # --- Scaffold by type; durings error removes created empty director ---
    local scaffold_rc=0
    case "$cms_type" in
        wordpress)
            ( cd "$project_path" && _new_scaffold_wordpress "$project_name" "$project_path" "$php_version" "$use_theme" ) || scaffold_rc=1
            ;;
        joomla|opencart|ocstore)
            ( cd "$project_path" && _new_scaffold_archive_cms "$cms_type" "$project_name" "$project_path" "$php_version" ) || scaffold_rc=1
            ;;
        laravel)
            ( cd "$project_path" && _new_scaffold_laravel "$project_name" "$project_path" "$php_version" ) || scaffold_rc=1
            ;;
        php)
            ( cd "$project_path" && _new_scaffold_php "$project_name" "$project_path" "$php_version" ) || scaffold_rc=1
            ;;
        *)
            print_error "Internal error: unknown type '$cms_type'."
            scaffold_rc=1
            ;;
    esac

    if [[ $scaffold_rc -ne 0 ]]; then
        print_error "Creat project fail. Clean director..."
        rm -rf "$project_path"
        return 1
    fi

    if has_arg "db" && [[ "$cms_type" != "php" ]]; then
        _new_provision_db "$project_name" "$project_path" "$cms_type"
    fi

    print_separator
    print_highlight "Path:        ${project_path}"
    print_highlight "URL:         ${site_url}"
    print_highlight "Next step: dpx tunnel --project-name ${project_name}"
    print_separator

    ddev_launch "$project_name"
    return 0
}
