#!/usr/bin/env bash
# =================================================================
# WP-Handler: Elementor
# Problem: Elementor caches CSS files with absolute URLs.
# After a domain switch (tunnel, prod→local) styles point to the old URL.
# Solution: `wp elementor flush-css` regenerates the CSS files.
#
# DPX invokes this file automatically via cms_flush_advanced_caches().
# No manual invocation required.
# =================================================================

(
    cd "$_CMS_HANDLER_PROJECT_PATH" 2>/dev/null || exit 0

    # Detector: is the plugin installed?
    if ! ddev exec test -d /var/www/html/wp-content/plugins/elementor 2>/dev/null; then
        exit 0
    fi

    print_step "auto" "[WP-Handler] Elementor: flush CSS..." >&2

    ddev exec php -d display_errors=0 -d error_reporting=0 \
        /usr/local/bin/wp elementor flush-css --allow-root --quiet 2>/dev/null || true
) 2>/dev/null || true
