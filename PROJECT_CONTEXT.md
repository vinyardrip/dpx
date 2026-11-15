# DPX CONTEXT SNAPSHOT (v1.4.0-rc1)
**Current Date:** 2026-05-04
**Environment:** DDEV, WordPress, PHP 7.4 -> 8.3 Migration Support.

---

### ЧТО СДЕЛАНО (v1.4.0-rc1):

1.  **Unified Versioning (Single Source of Truth):**
    - Создан файл `.version` в корне проекта (`1.4.0-rc1`).
    - Все компоненты (dpx.sh, install.sh, lib/core.sh, commands/tunnel.sh) читают версию динамически из `.version`.
    - Удалены все захардкоженные версии из заголовков модулей.
2.  **Очистка проекта:**
    - Удалены мусорные файлы: `checklist.md`, `prompt.md`, `readme.md`, `readme_flash_all`, `read_gem`, `read_glm`, `dpx-share-plan`, `full_project.txt`, `VERSION`, `.ddev/`.
    - Удалены старые архивы: `dpx-v0.2.*.tar.gz`, `dpx-tunnel-v0.1.0.tar.gz`.
    - Проект готов к `git init`.
3.  **Safe Sudo Protocol (lib/sudo.sh):**
    - Модуль `lib/sudo.sh` с протоколом: бэкап → правка → проверка → rollback/cleanup.
    - `dpx_sudo()`: 3 попытки ввода пароля, таймаут 60 секунд, fallback для macOS (gtimeout).
    - `dpx_snapshot()` / `dpx_rollback()` / `dpx_cleanup_snapshot()`: бэкапы с расширением `.bak`.
    - `dpx_wp_config_snapshot()` / `dpx_wp_config_rollback()`: бэкапы wp-config.php.
    - Tunnel.sh делегирует бэкапы в lib/sudo.sh.
4.  **Installer & Alias Cleanup (install.sh):**
    - Поиск старых алиасов `alias dpx=...` в `.bashrc`/`.zshrc`/`.bash_profile`/`.profile`.
    - Требование удаления алиасов для перехода на символические ссылки.
    - Установка по умолчанию — локальная (`~/.local/bin/dpx`), без sudo.
    - Глобальная установка — через `./install.sh install-global`.
5.  **WordPress Tunneling (Cloudflare):**
    - `commands/tunnel.sh` — полностью функциональный модуль (на базе v0.2.5).
    - DPX_SMART_TUNNEL: динамический PHP-блок с проверкой TLD (без хардкода провайдеров).
    - `_DPX_DB_MUTATING` флаг: защита от race condition при Ctrl+C.
    - `tunnel_wp_exec()`: подавление PHP Deprecated/Notice (8.5+).
    - Верификация целостности через WP-CLI после патча, автореставрация из бэкапа.
    - Полный откат при Ctrl+C: config → DB → tunnel → log.
6.  **Cross-Platform:**
    - `safe_sed_inplace()` — автоочистка `.bak` файлов на macOS.
    - `dpx_docker_compose()` — обёртка для docker compose v2/v1 в devilbox.sh и migrate.sh.
    - Проверки: `timeout`/`gtimeout` fallback, `ping -W`/`-t` для Linux/macOS, `getent`/`dscl`.
7.  **Core Architecture:**
    - Модульная загрузка через `lib/core.sh` (14 модулей).
    - Кроссплатформенное определение путей (GNU/BSD) в `lib/paths.sh`.
    - Цветовой вывод с поддержкой NO_COLOR и CI/CD.
    - Ротация бэкапов `core_rotate_backups()`.

---

### СТРУКТУРА ПРОЕКТА:

```
dpx/
├── .version          # 1.4.0-rc1 (Single Source of Truth)
├── .gitignore
├── LICENSE
├── PLAN.md
├── README.md
├── dpx.sh            # Entry Point / Router
├── install.sh        # Installer (alias cleanup + symlink)
├── run_tests.sh
├── commands/
│   ├── db-restore.sh
│   ├── db-snap.sh
│   ├── ddev.sh
│   ├── deploy.sh
│   ├── edit.sh
│   ├── list.sh
│   ├── migrate.sh
│   ├── new-wp.sh
│   ├── refresh.sh
│   ├── set-php.sh
│   ├── to-prod.sh
│   └── tunnel.sh
├── config/
│   └── dpx.conf
├── lib/
│   ├── args.sh
│   ├── checks.sh
│   ├── cms.sh
│   ├── config.sh
│   ├── core.sh
│   ├── database.sh
│   ├── ddev.sh
│   ├── devilbox.sh
│   ├── io.sh
│   ├── meta.sh
│   ├── paths.sh
│   ├── projects.sh
│   ├── sudo.sh        # NEW: Safe Sudo Protocol
│   └── utils.sh
└── tests/
    ├── test_core.sh
    └── test_framework.sh
```

---

### ИЗВЕСТНЫЕ ОГРАНИЧЕНИЯ:

- **[BUG] refresh:** Не подхватывает конкретную БД из `wp-config.php`.
- **[NOT TESTED] CMS Support:** Joomla и OpenCart — только теоретическая поддержка.
- **[DONE v1.6.0] ngrok:** Провайдер реализован (API-driven URL extraction, jq/python3/grep fallback, trap-safe cleanup).
- **[DEFERRED] logging:** Критические ошибки пишутся только в консоль.
