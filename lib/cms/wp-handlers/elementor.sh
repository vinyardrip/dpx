#!/usr/bin/env bash
# =================================================================
# WP-Handler: Elementor
# Проблема: Elementor кэширует CSS-файлы с абсолютными URL.
# При смене домена (туннель, прод→локал) стили ведут на старый URL.
# Решение: wp elementor flush-css пересоздаёт CSS-файлы.
#
# DPX вызовет этот файл автоматически через cms_flush_advanced_caches().
# Не требует ручного вызова.
# =================================================================

(
    cd "$_CMS_HANDLER_PROJECT_PATH" 2>/dev/null || exit 0

    # Детектор: плагин установлен?
    if ! ddev exec test -d /var/www/html/wp-content/plugins/elementor 2>/dev/null; then
        exit 0
    fi

    print_step "auto" "[WP-Handler] Elementor: flush CSS..." >&2

    ddev exec php -d display_errors=0 -d error_reporting=0 \
        /usr/local/bin/wp elementor flush-css --allow-root --quiet 2>/dev/null || true
) 2>/dev/null || true
