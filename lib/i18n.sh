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
    [[ -z "$candidate" ]] && candidate="${LC_ALL:-}"
    [[ -z "$candidate" ]] && candidate="${LANG:-}"
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

_i18n_on_load() {
    dpx_detect_lang
}
_i18n_on_load

export _DPX_LANG
