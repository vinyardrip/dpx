#!/usr/bin/env bash
# =================================================================
# WP-Handler: Flatsome
# Проблема: Тема Flatsome хранит:
#   1. Запечённые CSS-файлы со старыми URL в uploads/flatsome-css/
#   2. Транзиенты в БД (flatsome_%)
# При смене домена верстка «едет» — стили и картинки ведут на старый URL.
# Решение: Удаление папки кэша + очистка транзиентов через SQL.
#
# DPX вызовет этот файл автоматически через cms_flush_advanced_caches().
# Не требует ручного вызова.
# =================================================================

(
    cd "$_CMS_HANDLER_PROJECT_PATH" 2>/dev/null || exit 0

    # Детектор: тема установлена?
    if ! ddev exec test -d /var/www/html/wp-content/themes/flatsome 2>/dev/null; then
        exit 0
    fi

    print_step "auto" "[WP-Handler] Flatsome: cleaning CSS & transients..." >&2

    # 1. Удаление папки с запечёнными CSS
    ddev exec rm -rf /var/www/html/wp-content/uploads/flatsome-css 2>/dev/null || true

    # 2. Очистка транзиентов через SQL (если функция доступна из database.sh)
    if declare -f db_sql_delete_transients >/dev/null 2>&1; then
        db_sql_delete_transients "$_CMS_HANDLER_PROJECT_PATH" "flatsome_%"
    fi
) 2>/dev/null || true
