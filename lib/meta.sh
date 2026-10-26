#!/usr/bin/env bash
# =================================================================
# DPX Meta Module - management metadatas projects
# Storage: ~/.config/dpx/projects.json
# =================================================================

# Re-entrancy guard
[[ -n "${_DPX_META_LOADED:-}" ]] && return 0
readonly _DPX_META_LOADED=1

# =================================================================
# PATH To FILE STORAGE
# =================================================================

# File metadata projects
dpx_meta_file() {
    echo "${HOME}/.config/${TOOL_NAME}/projects.json"
}

# Initialization storage (creates the file when missing or empty)
dpx_meta_init() {
    local meta_file
    meta_file=$(dpx_meta_file)

    # An empty file is treated as "absent": jq cannot parse it and the
    # atomic writer below would otherwise refuse every update.
    if [[ ! -s "$meta_file" ]]; then
        mkdir -p "$(dirname "$meta_file")" 2>/dev/null
        printf '{"projects":{}}\n' > "$meta_file"
    fi
}

# =================================================================
# READING METADATA
# =================================================================

# Get value by key for project
# dpx_meta_get <project_name> <key> [default]
dpx_meta_get() {
    local project_name="$1"
    local key="$2"
    local default="${3:-}"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    local value
    value=$(jq -r --arg name "$project_name" --arg k "$key" \
        '.projects[$name][$k] // empty' "$meta_file" 2>/dev/null)

    echo "${value:-$default}"
}

# Get all metadata project (JSON)
# dpx_meta_get_all <project_name>
dpx_meta_get_all() {
    local project_name="$1"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    jq -r --arg name "$project_name" \
        '.projects[$name] // empty' "$meta_file" 2>/dev/null
}

# Verify presence project in storage
dpx_meta_exists() {
    local project_name="$1"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    jq -e --arg name "$project_name" \
        '.projects[$name]' "$meta_file" >/dev/null 2>&1
}

# =================================================================
# RECORD METADATA
# =================================================================

# Atomic JSON mutation of the metadata store.
#   $1 = metadata file
#   $2 = jq filter
#   rest = jq options (--arg ...)
# The original file is left untouched on ANY failure: corrupt input,
# jq error, empty/invalid output, or a failed atomic rename.
_dpx_meta_write() {
    local meta_file="$1"
    local filter="$2"
    shift 2

    if ! command -v jq >/dev/null 2>&1; then
        print_error "dpx_meta: jq is required for metadata updates" >&2
        return 1
    fi

    # Refuse to rewrite a corrupt document: jq would emit nothing and
    # the rename below would replace the store with garbage.
    if [[ -s "$meta_file" ]] && ! jq -e . "$meta_file" >/dev/null 2>&1; then
        print_error "dpx_meta: refusing to rewrite invalid JSON: $meta_file" >&2
        return 1
    fi

    local meta_dir meta_base temp_file
    meta_dir="$(dirname "$meta_file")"
    meta_base="$(basename "$meta_file")"
    ensure_directory "$meta_dir" || return 1

    # Same directory => same filesystem => atomic rename.
    temp_file="$(mktemp "${meta_dir}/${meta_base}.tmp.XXXXXX")" || {
        print_error "dpx_meta: cannot create temporary file in $meta_dir" >&2
        return 1
    }

    if ! jq "$@" "$filter" "$meta_file" > "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        print_error "dpx_meta: jq failed; $meta_file left untouched" >&2
        return 1
    fi

    if [[ ! -s "$temp_file" ]] || ! jq -e . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        print_error "dpx_meta: empty/invalid result; $meta_file left untouched" >&2
        return 1
    fi

    if ! mv -f "$temp_file" "$meta_file"; then
        rm -f "$temp_file"
        print_error "dpx_meta: failed to replace $meta_file" >&2
        return 1
    fi

    return 0
}

# Install value for project
# dpx_meta_set <project_name> <key> <value>
dpx_meta_set() {
    local project_name="$1"
    local key="$2"
    local value="$3"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    _dpx_meta_write "$meta_file" \
        ".projects[\$name][\$k] = \$v" \
        --arg name "$project_name" --arg k "$key" --arg v "$value"
}

# Batch set (single atomic rewrite):
# dpx_meta_set_many <project_name> <key> <value> [<key> <value> ...]
# Used by `dpx set-php` to save type/php_max/tested in one transaction.
dpx_meta_set_many() {
    local project_name="$1"
    shift

    if (( $# == 0 )) || (( $# % 2 != 0 )); then
        print_error "dpx_meta_set_many: expected key/value pairs" >&2
        return 1
    fi

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    local filter=".projects[\$name] = ((.projects[\$name] // {}) + {"
    local -a jq_args=(--arg name "$project_name")
    local idx=0

    while (( $# >= 2 )); do
        # Keys are internal constants; reject anything that could break
        # the emitted jq object literal.
        if [[ ! "$1" =~ ^[A-Za-z0-9_]+$ ]]; then
            print_error "dpx_meta_set_many: invalid key: $1" >&2
            return 1
        fi
        filter+="\"${1}\": \$v${idx},"
        jq_args+=(--arg "v${idx}" "$2")
        shift 2
        idx=$((idx + 1))
    done
    filter="${filter%,}})"

    _dpx_meta_write "$meta_file" "$filter" "${jq_args[@]}"
}

# Remove key from project
# dpx_meta_unset <project_name> <key>
dpx_meta_unset() {
    local project_name="$1"
    local key="$2"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    _dpx_meta_write "$meta_file" \
        "del(.projects[\$name][\$k])" \
        --arg name "$project_name" --arg k "$key"
}

# Remove all metadata project
# dpx_meta_delete <project_name>
dpx_meta_delete() {
    local project_name="$1"

    dpx_meta_init
    local meta_file
    meta_file=$(dpx_meta_file)

    _dpx_meta_write "$meta_file" \
        "del(.projects[\$name])" \
        --arg name "$project_name"
}

# =================================================================
# SPECIALIZED GETTERS
# =================================================================

# Get php_max
dpx_get_php_max() {
    dpx_meta_get "$1" "php_max" "-"
}

# Get type project
dpx_get_project_type() {
    dpx_meta_get "$1" "type" "-"
}

# Get notes
dpx_get_notes() {
    dpx_meta_get "$1" "notes" "-"
}

# Get date testing
dpx_get_tested() {
    dpx_meta_get "$1" "tested" "-"
}