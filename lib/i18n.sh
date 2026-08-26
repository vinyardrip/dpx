#!/usr/bin/env bash
# =================================================================
# DPX I18n Module - locale resolution & message translation
#
# Resolution order (first match wins):
#   1. DPX_LANG            explicit override ("en" | "ru")
#   2. LC_ALL              "ru*" -> ru
#   3. LANG                "ru*" -> ru
#   4. Fallback            "en"
#
# Contract:
#   t KEY [printf-args...] -> localized line on STDOUT.
#   EN texts are the canonical source of truth; RU translations
#   cover the keys listed below. Unknown key => non-zero exit.
# =================================================================

[[ -n "${_DPX_I18N_LOADED:-}" ]] && return 0
readonly _DPX_I18N_LOADED=1

_DPX_LANG="en"

# -----------------------------------------------------------------
# Locale auto-detection
# -----------------------------------------------------------------
dpx_detect_lang() {
    local candidate="${DPX_LANG:-}"

    # Configured preference from `dpx config --lang ...`; "auto" defers
    # to the environment chain. config.sh loads before i18n.sh.
    if [[ -z "$candidate" ]] && declare -F get_config >/dev/null; then
        local pref
        pref="$(get_config "cli_lang" "auto")"
        case "$pref" in
            en|ru) candidate="$pref" ;;
        esac
    fi

    if [[ -z "$candidate" ]]; then
        candidate="${LC_ALL:-}"
    fi
    if [[ -z "$candidate" ]]; then
        candidate="${LANG:-}"
    fi
    case "$candidate" in
        ru*|RU*) _DPX_LANG="ru" ;;
        *)       _DPX_LANG="en" ;;
    esac
}

# -----------------------------------------------------------------
# EN canonical texts (source of truth)
# -----------------------------------------------------------------
declare -A _I18N_EN=(
    ["lbl.step"]="Step"
    ["lbl.error"]="ERROR"
    ["lbl.warning"]="WARNING"
    ["lbl.fatal"]="FATAL"
    ["q.proceed"]="Proceed?"
    ["err.input.aborted"]="Input aborted (EOF)."
    ["err.unknown.choice"]="Unknown choice '%s'. Enter a number or name."
    ["err.no.interactive"]="No interactive terminal available."
    ["err.requires.arg"]="requires an argument"
    ["sel.project.type"]="--- Select project type ---"
    ["menu.new.prompt"]="Select [1-6]: "
    ["msg.refresh.nonwp.warn"]="Project type is %s. Database URL replacement will NOT be performed."
    ["q.refresh.nonwp"]="Continue without replacing URLs?"
    ["cfg.wizard.title"]="DPX configuration wizard"
    ["cfg.wizard.hint"]="Settings file:"
    ["cfg.q.projects_root"]="Projects root directory"
    ["cfg.q.provider"]="Preferred tunnel provider"
    ["cfg.q.db_user"]="MySQL/MariaDB username"
    ["cfg.q.db_password"]="MySQL/MariaDB password"
    ["cfg.q.lang"]="CLI output language"
    ["cfg.saved"]="Configuration saved"
    ["cfg.firstrun.hint"]="No user configuration found - run dpx config to set the projects root, tunnel provider and DB credentials."
    ["cfg.show.title"]="Active DPX configuration"
    ["cfg.show.file"]="Config file"
    ["cfg.err.provider"]="Provider must be ngrok or cloudflare"
    ["cfg.err.lang"]="Language must be auto, en or ru"
    ["cfg.apply.header"]="Applying configuration changes:"
    ["cfg.apply.confirm"]="Apply these changes?"
    ["dom.db.usage"]="db subcommands: pull (refresh from prod) | push (prepare for prod) | snap | restore"
    ["dom.site.usage"]="site subcommands: new | backup | restore | migrate | deploy"
    ["restore.title"]="Restore project from full backup"
    ["restore.q.archive"]="Archive path (empty = pick from backups)"
    ["restore.no.archives"]="No FULL_*.tar.gz archives found in"
    ["restore.pick"]="Select archive to restore"
    ["restore.target"]="Target project"
    ["restore.missing.project"]="Project directory not found. Deploy or scaffold it first:"
    ["restore.snapshot"]="Safety DB snapshot before restore"
    ["restore.unpack"]="Unpacking archive into project directory..."
    ["restore.dump.found"]="Embedded database dump found:"
    ["restore.import"]="Importing database into DDEV..."
    ["restore.done"]="Project restored successfully!"
    ["banner.update"]="DPX update available! Run 'dpx update' to apply"
    ["orphan.detected"]="💡 A previous session terminated abruptly. Would you like to restore the database from snapshot?"
    ["orphan.snapshot"]="Orphaned snapshot:"
    ["orphan.noninteractive"]="Non-interactive session: snapshot was not restored."
    ["orphan.q.restore"]="Restore the database from this snapshot?"
    ["orphan.restoring"]="Restoring database from snapshot..."
    ["orphan.restored"]="Database restored; orphan state cleaned up."
    ["orphan.restore.failed"]="Snapshot restore failed; orphan state was preserved."
    ["cfg.err.archive.corrupt"]="Archive is corrupted or unreadable:"
    ["restore.overwrite.warn"]="Existing project files matching the archive will be overwritten. Extra files are kept."
)

# -----------------------------------------------------------------
# RU translations (covered keys)
# -----------------------------------------------------------------
declare -A _I18N_RU=(
    ["lbl.step"]="Шаг"
    ["lbl.error"]="ОШИБКА"
    ["lbl.warning"]="ВНИМАНИЕ"
    ["lbl.fatal"]="FATAL"
    ["q.proceed"]="Продолжить?"
    ["err.input.aborted"]="Ввод прерван (EOF)."
    ["err.unknown.choice"]="Неизвестный вариант '%s'. Введите номер или название."
    ["err.no.interactive"]="Нет интерактивного терминала."
    ["err.requires.arg"]="требует аргумент"
    ["sel.project.type"]="--- Выберите тип проекта ---"
    ["menu.new.prompt"]="Выберите [1-6]: "
    ["msg.refresh.nonwp.warn"]="Тип проекта — %s. Замена URL в базе данных НЕ будет выполнена."
    ["q.refresh.nonwp"]="Продолжить без замены URL?"
    ["cfg.wizard.title"]="Мастер настройки DPX"
    ["cfg.wizard.hint"]="Файл настроек:"
    ["cfg.q.projects_root"]="Корневая директория проектов"
    ["cfg.q.provider"]="Предпочтительный провайдер туннеля"
    ["cfg.q.db_user"]="Пользователь MySQL/MariaDB"
    ["cfg.q.db_password"]="Пароль MySQL/MariaDB"
    ["cfg.q.lang"]="Язык вывода CLI"
    ["cfg.saved"]="Конфигурация сохранена"
    ["cfg.firstrun.hint"]="Пользовательская конфигурация не найдена — выполните dpx config, чтобы задать директорию проектов, провайдера туннеля и учётные данные БД."
    ["cfg.show.title"]="Активная конфигурация DPX"
    ["cfg.show.file"]="Файл конфигурации"
    ["cfg.err.provider"]="Провайдер должен быть ngrok или cloudflare"
    ["cfg.err.lang"]="Язык должен быть auto, en или ru"
    ["cfg.apply.header"]="Применяем изменения конфигурации:"
    ["cfg.apply.confirm"]="Применить эти изменения?"
    ["dom.db.usage"]="Подкоманды db: pull (обновить из прода) | push (подготовить к проду) | snap | restore"
    ["dom.site.usage"]="Подкоманды site: new | backup | restore | migrate | deploy"
    ["restore.title"]="Восстановление проекта из полного бэкапа"
    ["restore.q.archive"]="Путь к архиву (пусто = выбрать из бэкапов)"
    ["restore.no.archives"]="Архивы FULL_*.tar.gz не найдены в"
    ["restore.pick"]="Выберите архив для восстановления"
    ["restore.target"]="Целевой проект"
    ["restore.missing.project"]="Директория проекта не найдена. Сначала разверните или создайте его:"
    ["restore.snapshot"]="Страховочный снапшот БД перед восстановлением"
    ["restore.unpack"]="Распаковка архива в директорию проекта..."
    ["restore.dump.found"]="Найден дамп базы данных в архиве:"
    ["restore.import"]="Импорт базы данных в DDEV..."
    ["restore.done"]="Проект успешно восстановлен!"
    ["banner.update"]="Доступно обновление DPX! Выполните 'dpx update' для установки"
    ["orphan.detected"]="💡 Предыдущая сессия завершилась аварийно. Восстановить базу данных из снапшота?"
    ["orphan.snapshot"]="Осиротевший снапшот:"
    ["orphan.noninteractive"]="Неинтерактивная сессия: снапшот не восстановлен."
    ["orphan.q.restore"]="Восстановить базу данных из этого снапшота?"
    ["orphan.restoring"]="Восстановление базы данных из снапшота..."
    ["orphan.restored"]="База данных восстановлена; осиротевшее состояние очищено."
    ["orphan.restore.failed"]="Восстановление снапшота не удалось; осиротевшее состояние сохранено."
    ["cfg.err.archive.corrupt"]="Архив повреждён или не читается:"
    ["restore.overwrite.warn"]="Файлы проекта, присутствующие в архиве, будут перезаписаны. Лишние файлы останутся."
)

# -----------------------------------------------------------------
# Translate: t KEY [printf-args...]
# -----------------------------------------------------------------
t() {
    local key="$1"
    shift || true
    local lang="${_DPX_LANG:-en}" msg=""

    if [[ "$lang" == "ru" && -n "${_I18N_RU[$key]:-}" ]]; then
        msg="${_I18N_RU[$key]}"
    elif [[ -n "${_I18N_EN[$key]:-}" ]]; then
        msg="${_I18N_EN[$key]}"
    else
        return 1
    fi

    # guard: a leading dash would be parsed as a printf option
    [[ "$msg" == -* ]] && msg=" $msg"

    local out=""
    if (( $# )); then
        printf -v out -- "$msg" "$@"
    else
        out="$msg"
    fi
    printf '%s\n' "$out"
}

# NOTE: dpx_detect_lang is (re)invoked by core.sh AFTER load_config so
# that the configured cli_lang preference is visible. It is also safe
# to call manually whenever configuration changes.
# Auto-resolve on load (env-based; config tier self-skips without
# get_config). core.sh re-invokes dpx_detect_lang after load_config so
# the configured cli_lang preference is honored too.
dpx_detect_lang

export _DPX_LANG
