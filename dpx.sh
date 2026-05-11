#!/usr/bin/env bash
# =================================================================
# DPX - DDEV Project eXtend
# Минимальная точка входа (Entry Point / Router)
# =================================================================

# =================================================================
# ПРОВЕРКА ОКРУЖЕНИЯ (до любого кода)
# =================================================================

# Надежная проверка версии Bash (работает на macOS и Linux)
# BASH_VERSINFO - встроенный массив с числовыми компонентами версии
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
    echo "ОШИБКА: Этот скрипт требует Bash 4.0 или выше." >&2
    echo "Текущая версия: ${BASH_VERSION:-неизвестно}" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "" >&2
        echo "Подсказка для macOS:" >&2
        echo "  1. Установите современный Bash: brew install bash" >&2
        echo "  2. Добавьте в ~/.zshrc или ~/.bash_profile:" >&2
        echo "     export PATH=\"/opt/homebrew/bin:\$PATH\"" >&2
        echo "     # или для Intel Mac:" >&2
        echo "     export PATH=\"/usr/local/bin:\$PATH\"" >&2
        echo "  3. Перезапустите терминал или выполните: source ~/.zshrc" >&2
    fi
    exit 1
fi

# Сбрасываем кэш путей команд shell
hash -r 2>/dev/null

# =================================================================
# ОПРЕДЕЛЕНИЕ DPX_ROOT (кроссплатформенное)
# =================================================================

dpx_get_root() {
    local source="${BASH_SOURCE[0]:-$0}"

    while [[ -h "$source" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || exit 1
        source="$(readlink "$source")" || exit 1
        [[ "$source" != /* ]] && source="${dir}/${source}"
    done

    local root
    root="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || exit 1

    case "$(basename "$root")" in
        lib|commands|tests) root="$(dirname "$root")" ;;
    esac

    echo "$root"
}

DPX_ROOT="$(dpx_get_root)" || exit 1
export DPX_ROOT

# =================================================================
# ЗАГРУЗКА ЯДРА
# =================================================================

if [[ -f "${DPX_ROOT}/lib/core.sh" ]]; then
    source "${DPX_ROOT}/lib/core.sh"
else
    echo "ОШИБКА: Ядро системы не найдено в ${DPX_ROOT}/lib/core.sh" >&2
    exit 1
fi

# =================================================================
# СПРАВКА
# =================================================================

show_help() {
    local bold="$COLOR_BOLD"
    local reset="$COLOR_RESET"
    local green="$COLOR_GREEN"

    printf '\n'
    print_header "${TOOL_NAME^^} - DDEV Project eXtend"
    print_info "Универсальный CLI для управления DDEV проектами"
    echo ""

    printf '%sИСПОЛЬЗОВАНИЕ:%s\n' "$bold" "$reset"
    printf '    %s <команда> [опции]\n\n' "$TOOL_NAME"

    printf '%sКОМАНДЫ:%s\n' "$bold" "$reset"
    printf '    %s%-12s%s %s\n' "$green" "list" "$reset" "Список DDEV проектов"
    printf '    %s%-12s%s %s\n' "$green" "edit" "$reset" "Редактирование метаданных проекта"
    printf '    %s%-12s%s %s\n' "$green" "set-php" "$reset" "Изменение версии PHP проекта"
    printf '    %s%-12s%s %s\n' "$green" "deploy" "$reset" "Развертывание существующего проекта на DDEV"
    printf '    %s%-12s%s %s\n' "$green" "new-wp" "$reset" "Создание нового WordPress проекта"
    printf '    %s%-12s%s %s\n' "$green" "ddev" "$reset" "Выполнение любой команды DDEV для проекта"
    printf '    %s%-12s%s %s\n' "$green" "refresh" "$reset" "Обновление локальной БД с продакшена"
    printf '    %s%-12s%s %s\n' "$green" "migrate" "$reset" "Миграция проекта с Devilbox на DDEV"
    printf '    %s%-12s%s %s\n' "$green" "db-snap" "$reset" "Быстрый снимок (backup) локальной БД"
    printf '    %s%-12s%s %s\n' "$green" "db-restore" "$reset" "Восстановление БД из локального бэкапа"
    printf '    %s%-12s%s %s\n' "$green" "to-prod" "$reset" "Подготовка локальной БД к выгрузке на прод"
    printf '    %s%-12s%s %s\n' "$green" "tunnel" "$reset" "Проброс туннеля для показа проекта"
    printf '    %s%-12s%s %s\n' "$green" "update" "$reset" "Проверка и установка обновлений"
    printf '    %s%-12s%s %s\n\n' "$green" "info" "$reset" "Конфигурация и версии окружения"

    printf '%sОПЦИИ:%s\n' "$bold" "$reset"
    printf '    -h, --help        Показать справку\n'
    printf '    -v, --version     Показать версию\n'
    printf '    -y, --yes         Автоматически подтверждать действия\n\n'

    printf '%sПРИМЕРЫ:%s\n' "$bold" "$reset"
    printf '    %s list\n' "$TOOL_NAME"
    printf '    %s edit mysite --php-max 8.2\n' "$TOOL_NAME"
    printf '    %s set-php\n' "$TOOL_NAME"
    printf '    %s db-snap\n' "$TOOL_NAME"
    printf '    %s to-prod --project-name mysite --prod-url https://mysite.by\n' "$TOOL_NAME"
    printf '    %s tunnel --project-name mysite\n' "$TOOL_NAME"
    printf '    %s update\n' "$TOOL_NAME"
    printf '    %s info\n\n' "$TOOL_NAME"

    printf '%sТРЕБОВАНИЯ:%s\n' "$bold" "$reset"
    printf '    • Bash >= %s\n' "${MIN_BASH_VERSION:-4.0}"
    printf '    • DDEV >= %s\n' "${MIN_DDEV_VERSION:-1.21.0}"
    printf '    • Docker\n'
}

show_version() {
    print_info "${TOOL_NAME} v${DPX_VERSION}"
    print_info "OS: ${DPX_OS_TYPE} | Bash: ${BASH_VERSION%% *}"
}

show_commands() {
    local bold="$COLOR_BOLD"
    local reset="$COLOR_RESET"
    local green="$COLOR_GREEN"

    printf '%sДоступные команды:%s\n' "$bold" "$reset"
    printf '  %s%-12s%s %s\n' "$green" "list" "$reset" "Список проектов"
    printf '  %s%-12s%s %s\n' "$green" "edit" "$reset" "Редактирование метаданных"
    printf '  %s%-12s%s %s\n' "$green" "set-php" "$reset" "Смена версии PHP"
    printf '  %s%-12s%s %s\n' "$green" "deploy" "$reset" "Развертывание проекта"
    printf '  %s%-12s%s %s\n' "$green" "new-wp" "$reset" "Новый WordPress"
    printf '  %s%-12s%s %s\n' "$green" "ddev" "$reset" "Обертка команд DDEV"
    printf '  %s%-12s%s %s\n' "$green" "refresh" "$reset" "Обновление БД"
    printf '  %s%-12s%s %s\n' "$green" "migrate" "$reset" "Миграция с Devilbox"
    printf '  %s%-12s%s %s\n' "$green" "db-snap" "$reset" "Снимок локальной БД"
    printf '  %s%-12s%s %s\n' "$green" "db-restore" "$reset" "Восстановление БД"
    printf '  %s%-12s%s %s\n' "$green" "to-prod" "$reset" "Экспорт БД на прод"
    printf '  %s%-12s%s %s\n' "$green" "tunnel" "$reset" "Проброс туннеля"
    printf '  %s%-12s%s %s\n' "$green" "update" "$reset" "Обновление DPX"
    printf '  %s%-12s%s %s\n' "$green" "info" "$reset" "Конфигурация и версии"
    printf '\nИспользуйте: %s <команда> --help\n' "$TOOL_NAME"
}

# =================================================================
# МАРШРУТИЗАЦИЯ КОМАНД
# =================================================================

run_command() {
    local command="$1"
    shift || true

    case "$command" in
        ""|help|-h|--help)
            show_help
            ;;
        version|-v|--version)
            show_version
            ;;
        commands)
            show_commands
            ;;
        list|edit|set-php|deploy|to-prod|db-snap|db-restore|new-wp|refresh|migrate|ddev|tunnel|update|info)
            local cmd_file="${DPX_ROOT}/commands/${command}.sh"
            if [[ -f "$cmd_file" ]]; then
                # Защита от ошибок синтаксиса в файлах команд
                if ! bash -n "$cmd_file" 2>/dev/null; then
                    print_error "Ошибка синтаксиса в файле команды: $cmd_file"
                    print_error "Проверьте скрипт на наличие опечаток"
                    exit 1
                fi
                source "$cmd_file"
                # Замена дефисов на подчеркивания для имен функций
                local func_name="cmd_${command//-/_}"
                if declare -f "$func_name" >/dev/null; then
                    $func_name "$@"
                else
                    print_error "Функция $func_name не найдена в $cmd_file"
                    exit 1
                fi
            else
                print_error "Файл команды не найден: $cmd_file"
                exit 1
            fi
            ;;
        *)
            print_error "Неизвестная команда: $command"
            show_commands
            exit 1
            ;;
    esac
}

# =================================================================
# ТОЧКА ВХОДА
# =================================================================

main() {
    local command="${1:-help}"
    shift || true

    # Обработка вызова справки для конкретной команды: dpx <cmd> --help
    # Проверяем --help или -h в ЛЮБОЙ позиции аргументов
    local help_requested=false
    local clean_args=()

    for arg in "$@"; do
        if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]]; then
            help_requested=true
        else
            clean_args+=("$arg")
        fi
    done

    if [[ "$help_requested" == true ]]; then
        case "$command" in
            list|edit|set-php|deploy|to-prod|db-snap|db-restore|new-wp|refresh|migrate|tunnel|update|info)
                local cmd_file="${DPX_ROOT}/commands/${command}.sh"
                if [[ -f "$cmd_file" ]]; then
                    # Безопасный source с проверкой синтаксиса
                    if bash -n "$cmd_file" 2>/dev/null; then
                        source "$cmd_file"
                        local help_func="show_${command//-/_}_help"
                        if declare -f "$help_func" >/dev/null; then
                            $help_func
                            exit 0
                        fi
                    fi
                fi
                ;;
        esac
    fi

    # Проверка зависимостей только для функциональных команд
    case "$command" in
        ""|help|-h|--help|version|-v|--version|commands)
            :
            ;;
        *)
            check_dependencies || exit 1
            ;;
    esac

    run_command "$command" "${clean_args[@]}"
}

main "$@"
