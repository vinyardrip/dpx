#!/usr/bin/env bash
# =================================================================
# DPX Installer - установка, обновление и управление DPX
# =================================================================

set -e

# =================================================================
# КРОССПЛАТФОРМЕННОЕ ОПРЕДЕЛЕНИЕ ДОМАШНЕЙ ДИРЕКТОРИИ
# =================================================================

get_real_home() {
    local home

    if [[ -n "${SUDO_USER:-}" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        else
            home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        fi
    fi

    if [[ -z "${home:-}" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            home=$(dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        else
            home=$(getent passwd "$USER" 2>/dev/null | cut -d: -f6)
        fi
    fi

    echo "${home:-$HOME}"
}

REAL_HOME=$(get_real_home)
TOOL_NAME="dpx"

# --- Цвета ---
if command -v tput >/dev/null 2>&1; then
    GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4)
    RED=$(tput setaf 1); CYAN=$(tput setaf 6); BOLD=$(tput bold); NC=$(tput sgr0)
else
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
fi

# --- Константы ---
TOOL_NAME="dpx"

# Версия читается из .version (Single Source of Truth)
_script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [[ -f "${_script_dir}/.version" ]]; then
    INSTALL_VERSION="$(head -1 "${_script_dir}/.version" | tr -d '[:space:]')"
else
    INSTALL_VERSION="0.0.0-unknown"
fi

MIN_BASH_VERSION="4.0"
MIN_DDEV_VERSION="1.21.0"
MIN_DOCKER_VERSION="20.10"

# --- Функции вывода ---
print_header() { printf "\n%s=== %s ===%s\n" "${BLUE}" "$1" "${NC}"; }
print_success() { printf "%s✔ %s%s\n" "${GREEN}" "$1" "${NC}"; }
print_error() { printf "%s✗ %s%s\n" "${RED}" "$1" "${NC}"; }
print_warning() { printf "%s⚠ %s%s\n" "${YELLOW}" "$1" "${NC}"; }
print_info() { printf "%sℹ %s%s\n" "${CYAN}" "$1" "${NC}"; }

# =================================================================
# СРАВНЕНИЕ ВЕРСИЙ (кроссплатформенное, через awk)
# =================================================================

version_ge() {
    awk -v v1="$1" -v v2="$2" 'BEGIN {
        split(v1, a, "."); split(v2, b, ".");
        for (i=1; i<=3; i++) {
            if (a[i]+0 < b[i]+0) exit 1;
            if (a[i]+0 > b[i]+0) exit 0;
        }
        exit 0;
    }'
}

extract_version() {
    echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# =================================================================
# ПРОВЕРКА ВЕРСИИ BASH
# =================================================================

check_bash() {
    if (( BASH_VERSINFO[0] < 4 )); then
        print_error "Требуется Bash >= ${MIN_BASH_VERSION}"
        print_error "Текущая версия: ${BASH_VERSION:-неизвестно}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            print_warning "macOS поставляется с Bash 3.2 из-за лицензии GPLv3"
            print_info "Установите современный Bash: brew install bash"
        fi
        return 1
    fi

    print_success "Bash ${BASH_VERSION%% *}"
    return 0
}

# =================================================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ
# =================================================================

check_dependencies() {
    local errors=0

    check_bash || errors=1

    # DDEV
    if command -v ddev >/dev/null 2>&1; then
        local ddev_version
        ddev_version=$(ddev --version 2>/dev/null | extract_version)
        if [[ -z "$ddev_version" ]]; then
            print_warning "DDEV установлен, но версию определить не удалось"
        elif version_ge "$ddev_version" "$MIN_DDEV_VERSION"; then
            print_success "DDEV ${ddev_version}"
        else
            print_error "DDEV устарел: ${ddev_version}. Требуется >= ${MIN_DDEV_VERSION}"
            errors=1
        fi
    else
        print_error "DDEV не найден. Установите: https://ddev.readthedocs.io/en/stable/"
        errors=1
    fi

    # Docker
    if command -v docker >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | extract_version)
        if [[ -z "$docker_version" ]]; then
            print_warning "Docker установлен, но версию определить не удалось"
        elif version_ge "$docker_version" "$MIN_DOCKER_VERSION"; then
            print_success "Docker ${docker_version}"
        else
            print_error "Docker устарел: ${docker_version}. Требуется >= ${MIN_DOCKER_VERSION}"
            errors=1
        fi
    else
        print_error "Docker не найден. Установите: https://docs.docker.com/get-docker/"
        errors=1
    fi

    # Базовые утилиты
    for cmd in sed grep awk git curl jq; do
        if command -v "$cmd" >/dev/null 2>&1; then
            print_success "$cmd установлен"
        else
            print_error "$cmd не найден"
            errors=1
        fi
    done

    return $errors
}

# =================================================================
# ПОИСК СТАРЫХ АЛИАСОВ — требует удаления для перехода на симлинки
# =================================================================

# Ищет строки вида: alias dpx=... в shell-конфигах
# Возвращает 0 если найдены, 1 если чисто
find_old_aliases() {
    local found=0
    local shell_configs=()

    # Проверяем .bashrc, .zshrc, .bash_profile, .profile
    for rc in .bashrc .zshrc .bash_profile .profile; do
        local rc_path="${REAL_HOME}/${rc}"
        if [[ -f "$rc_path" ]] && grep -qE "^[[:space:]]*alias[[:space:]]+dpx=" "$rc_path" 2>/dev/null; then
            print_warning "Обнаружен старый алиас в ~/${rc}:"
            grep -E "^[[:space:]]*alias[[:space:]]+dpx=" "$rc_path" 2>/dev/null | while IFS= read -r line; do
                echo "    ${YELLOW}${line}${NC}"
            done
            found=1
        fi
    done

    return $found
}

# Автоматически удаляет старые алиасы из shell-конфигов
remove_old_aliases() {
    local removed=0

    for rc in .bashrc .zshrc .bash_profile .profile; do
        local rc_path="${REAL_HOME}/${rc}"
        if [[ ! -f "$rc_path" ]]; then
            continue
        fi

        if grep -qE "^[[:space:]]*alias[[:space:]]+dpx=" "$rc_path" 2>/dev/null; then
            print_info "Удаление алиаса dpx из ~/${rc}..."

            # Кроссплатформенное удаление строк
            local temp_file
            temp_file=$(mktemp)

            grep -vE "^[[:space:]]*alias[[:space:]]+dpx=" "$rc_path" > "$temp_file" 2>/dev/null || true

            if [[ -s "$temp_file" ]]; then
                cp "$temp_file" "$rc_path"
                rm -f "$temp_file"
                print_success "Алиас dpx удалён из ~/${rc}"
                ((removed++)) || true
            else
                rm -f "$temp_file"
                print_warning "Не удалось очистить ~/${rc} — пропускаем"
            fi
        fi
    done

    if (( removed > 0 )); then
        print_info "Перезапустите терминал или выполните: source ~/.bashrc (или ~/.zshrc)"
    fi

    return 0
}

# =================================================================
# ОПРЕДЕЛЕНИЕ ДИРЕКТОРИИ СКРИПТА
# =================================================================

get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir

    while [[ -L "$source" ]]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done

    echo "$(cd -P "$(dirname "$source")" && pwd)"
}

# =================================================================
# УСТАНОВКА
# =================================================================

install() {
    local script_dir="$(get_script_dir)"
    local install_mode="${1:-local}"
    local bin_dir config_dir

    # Определение реального пользователя
    local REAL_USER=${SUDO_USER:-$USER}
    local REAL_GROUP
    REAL_GROUP=$(id -g -n "$REAL_USER" 2>/dev/null || echo "$REAL_USER")

    print_header "Установка ${TOOL_NAME^^} v${INSTALL_VERSION}"

    # --- Проверка старых алиасов ---
    print_header "Проверка старых алиасов"
    if find_old_aliases; then
        print_warning "Обнаружены старые алиасы dpx в конфигурации shell."
        print_info "Символьная ссылка (symlink) и алиас конфликтуют."
        print_info "Для корректной работы алиасы должны быть удалены."
        echo ""
        echo -n "Удалить старые алиасы автоматически? [Y/n]: "
        read -r confirm
        confirm="${confirm:-y}"
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            remove_old_aliases
        else
            print_error "Удалите старые алиасы вручную и повторите установку."
            print_info "Найденные строки:"
            for rc in .bashrc .zshrc .bash_profile .profile; do
                grep -E "^[[:space:]]*alias[[:space:]]+dpx=" "${REAL_HOME}/${rc}" 2>/dev/null | while IFS= read -r line; do
                    echo "    ~/${rc}: ${line}"
                done
            done
            exit 1
        fi
    else
        print_success "Старые алиасы не найдены."
    fi

    # --- Определяем пути установки ---
    # По умолчанию: ~/.local/bin (не требует sudo)
    if [[ "$install_mode" == "global" ]]; then
        bin_dir="/usr/local/bin"
        print_info "Режим: глобальная установка (/usr/local/bin)"
    else
        bin_dir="${REAL_HOME}/.local/bin"
        print_info "Режим: локальная установка (~/.local/bin)"
    fi
    config_dir="${REAL_HOME}/.config/${TOOL_NAME}"

    # --- Проверка зависимостей ---
    print_header "Проверка зависимостей"
    if ! check_dependencies; then
        print_error "Не все зависимости удовлетворены. Установите их и повторите попытку."
        exit 1
    fi

    # --- Проверка прав для глобальной установки ---
    if [[ "$install_mode" == "global" && $EUID -ne 0 ]]; then
        print_warning "Глобальная установка (/usr/local/bin) может потребовать sudo."
    fi

    # --- Настройка прав доступа ---
    print_header "Настройка прав доступа"
    chmod +x "${script_dir}/${TOOL_NAME}.sh"
    find "${script_dir}/commands" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
    find "${script_dir}/lib" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

    if [[ -n "$SUDO_USER" ]]; then
        chown -R "$REAL_USER:$REAL_GROUP" "$script_dir"
        print_info "Владелец файлов проекта: $REAL_USER:$REAL_GROUP"
    fi

    # --- Создание директории для конфигурации ---
    print_header "Создание конфигурации"
    mkdir -p "$config_dir"
    chown "$REAL_USER:$REAL_GROUP" "$config_dir" 2>/dev/null || true

    if [[ ! -f "${config_dir}/${TOOL_NAME}.conf" ]]; then
        if [[ -f "${script_dir}/config/${TOOL_NAME}.conf" ]]; then
            cp "${script_dir}/config/${TOOL_NAME}.conf" "${config_dir}/${TOOL_NAME}.conf"
            chown "$REAL_USER:$REAL_GROUP" "${config_dir}/${TOOL_NAME}.conf" 2>/dev/null || true
            print_success "Конфигурация создана: ${config_dir}/${TOOL_NAME}.conf"
        else
            print_warning "Шаблон конфигурации не найден в ${script_dir}/config/"
        fi
    else
        print_warning "Конфигурация уже существует: ${config_dir}/${TOOL_NAME}.conf"
    fi

    # --- Создание символической ссылки ---
    print_header "Создание символической ссылки"
    mkdir -p "$bin_dir" 2>/dev/null || sudo mkdir -p "$bin_dir"

    local link_target="${script_dir}/${TOOL_NAME}.sh"
    local link_name="${bin_dir}/${TOOL_NAME}"

    # Удаляем существующую ссылку/файл
    if [[ -L "$link_name" ]] || [[ -f "$link_name" ]]; then
        if [[ -w "$(dirname "$link_name")" ]]; then
            rm -f "$link_name"
        else
            sudo rm -f "$link_name"
        fi
    fi

    # Создаём симлинк
    if [[ -w "$bin_dir" ]]; then
        ln -sf "$link_target" "$link_name"
    else
        print_info "Требуются права администратора для создания ссылки в ${bin_dir}"
        sudo ln -sf "$link_target" "$link_name"
    fi

    print_success "Ссылка создана: ${link_name} -> ${link_target}"

    # --- Проверка PATH ---
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        print_warning "$bin_dir не в PATH"
        print_info "Добавьте в ~/.bashrc или ~/.zshrc:"
        echo ""
        echo "    ${GREEN}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
        echo ""
        print_info "Затем: source ~/.bashrc (или ~/.zshrc)"
    fi

    # --- Проверка установки ---
    print_header "Проверка установки"
    hash -r 2>/dev/null || true

    if "$link_name" --version >/dev/null 2>&1; then
        local installed_version
        installed_version=$("$link_name" --version 2>/dev/null | head -1)
        print_success "Установка завершена: ${installed_version}"
    else
        print_error "Ошибка: скрипт не отвечает по пути ${link_name}"
        print_info "Убедитесь, что $bin_dir в PATH"
        exit 1
    fi

    # --- Финальное сообщение ---
    echo ""
    print_header "Готово!"
    echo ""
    echo "Использование:"
    echo "    ${GREEN}${TOOL_NAME} --help${NC}          показать справку"
    echo "    ${GREEN}${TOOL_NAME} list${NC}            список проектов"
    echo "    ${GREEN}${TOOL_NAME} tunnel${NC}          проброс туннеля"
    echo "    ${GREEN}${TOOL_NAME} deploy${NC}          развернуть проект"
    echo ""
    echo "Конфигурация: ${config_dir}/${TOOL_NAME}.conf"
    echo ""
}

# =================================================================
# УДАЛЕНИЕ
# =================================================================

uninstall() {
    print_header "Удаление ${TOOL_NAME^^}"

    local REAL_USER=${SUDO_USER:-$USER}
    local bin_dirs=("/usr/local/bin" "${REAL_HOME}/.local/bin")
    local config_dir="${REAL_HOME}/.config/${TOOL_NAME}"

    # Удаление символических ссылок
    for bin_dir in "${bin_dirs[@]}"; do
        local link_name="${bin_dir}/${TOOL_NAME}"
        if [[ -L "$link_name" ]] || [[ -f "$link_name" ]]; then
            if [[ -w "$bin_dir" ]]; then
                rm -f "$link_name"
            else
                print_info "Запрос sudo для удаления ссылки в ${bin_dir}"
                sudo rm -f "$link_name"
            fi
            print_success "Удалена ссылка: ${link_name}"
        fi
    done

    # Удаление конфигурации
    if [[ -d "$config_dir" ]]; then
        echo -n "Обнаружена конфигурация в ${config_dir}. Удалить? [y/N]: "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$config_dir"
            print_success "Конфигурация удалена."
        fi
    fi

    print_success "Удаление завершено."
}

# =================================================================
# ОБНОВЛЕНИЕ
# =================================================================

update() {
    local script_dir="$(get_script_dir)"
    local REAL_USER=${SUDO_USER:-$USER}

    print_header "Обновление ${TOOL_NAME^^}"

    if [[ -d "${script_dir}/.git" ]]; then
        print_info "Обновление исходного кода через Git..."
        sudo -u "$REAL_USER" git -C "$script_dir" pull origin main 2>/dev/null || \
        sudo -u "$REAL_USER" git -C "$script_dir" pull origin main 2>/dev/null
        print_success "Репозиторий обновлен"
    else
        print_warning "Папка не является Git-репозиторием. Используется текущий код."
    fi

    install "local"
}

# =================================================================
# СПРАВКА
# =================================================================

show_help() {
    cat << EOF
 ${BOLD}${TOOL_NAME^^} Installer v${INSTALL_VERSION}${NC}

Использование:
    ./install.sh [команда]

Команды:
    install         Установить локально (~/.local/bin) [по умолчанию]
    install-global  Установить глобально (/usr/local/bin)
    uninstall       Удалить
    update          Обновить (git pull + переустановка)
    check           Проверить зависимости
    help            Показать эту справку

Примеры:
    ./install.sh                 # локальная установка (рекомендуется)
    ./install.sh install-global  # глобальная установка (требует sudo)
    ./install.sh check           # только проверка зависимостей

Примечания:
    - При обнаружении старых алиасов (alias dpx=...) в ~/.bashrc
      или ~/.zshrc установщик потребует их удаления для перехода
      на символические ссылки.
    - Рекомендуется локальная установка (~/.local/bin/dpx),
      не требующая прав администратора.

Требования:
    Bash >= ${MIN_BASH_VERSION}
    DDEV >= ${MIN_DDEV_VERSION}
    Docker >= ${MIN_DOCKER_VERSION}

EOF
}

# =================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# =================================================================

main() {
    local command="${1:-install}"

    case "$command" in
        install)
            install "local"
            ;;
        install-local|local)
            install "local"
            ;;
        install-global|global)
            install "global"
            ;;
        uninstall|remove)
            uninstall
            ;;
        update|upgrade)
            update
            ;;
        check|deps)
            print_header "Проверка зависимостей"
            check_dependencies
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Неизвестная команда: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
