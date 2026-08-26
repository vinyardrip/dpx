#!/usr/bin/env bash
# =================================================================
# WP-Handler: Flatsome
# Problem: the Flatsome theme stores:
#   1. Baked CSS files with old URLs in uploads/flatsome-css/
#   2. Transients in the DB (flatsome_%)
# After a domain switch the layout "breaks" — styles and images point
# to the old URL. Solution: remove the cache folder + flush transients via SQL.
#
# DPX invokes this file automatically via cms_flush_advanced_caches().
# No manual invocation required.
# =================================================================

(
    cd "$_CMS_HANDLER_PROJECT_PATH" 2>/dev/null || exit 0

    # Detector: is the theme installed?
    if ! ddev exec test -d /var/www/html/wp-content/themes/flatsome 2>/dev/null; then
        exit 0
    fi

    print_step "auto" "[WP-Handler] Flatsome: cleaning CSS & transients..." >&2

    # 1. Remove the baked-CSS folder
    ddev exec rm -rf /var/www/html/wp-content/uploads/flatsome-css 2>/dev/null || true

    # 2. Flush transients via SQL (if the helper from database.sh is available)
    if declare -f db_sql_delete_transients >/dev/null 2>&1; then
        db_sql_delete_transients "$_CMS_HANDLER_PROJECT_PATH" "flatsome_%"
    fi
) 2>/dev/null || true
