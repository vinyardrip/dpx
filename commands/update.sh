#!/usr/bin/env bash
# =================================================================
# DPX Command: update - проверка и установка обновлений
# =================================================================

source "${DPX_ROOT}/lib/core.sh"

# =================================================================
# СПРАВКА
# =================================================================

show_update_help() {
    cat << EOF
 ${COLOR_BOLD}update${COLOR_RESET} - Проверка и установка обновлений DPX

 ${COLOR_BOLD}Использование:${COLOR_RESET}
    ${TOOL_NAME} update [опции]

 ${COLOR_BOLD}Описание:${COLOR_RESET}
    Проверяет наличие обновлений в репозитории https://github.com/vinyardrip/dpx
    и подтягивает свежий код. Если DPX установлен из Git-репозитория,
    выполняется git pull; иначе предлагается обновление вручную.

 ${COLOR_BOLD}Опции:${COLOR_RESET}
    --check         Только проверить наличие обновлений (без установки)
    -y, --yes       Автоматически подтверждать действия
    -h, --help      Показать эту справку

 ${COLOR_BOLD}Примеры:${COLOR_RESET}
    ${TOOL_NAME} update              # Проверка и установка обновлений
    ${TOOL_NAME} update --check      # Только проверить
    ${TOOL_NAME} update -y           # Обновить без подтверждений
EOF
}

# =================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =================================================================

cmd_update() {
    parse_args "$@" || return 1

    if has_arg "help"; then
        show_update_help
        return 0
    fi

    local check_only=false
    has_arg "check" && check_only=true

    print_header "Обновление ${TOOL_NAME^^}"

    # Проверяем, что DPX_ROOT — это Git-репозиторий
    if [[ ! -d "${DPX_ROOT}/.git" ]]; then
        print_warning "DPX не установлен из Git-репозитория."
        print_info "Для обновления скачайте свежую версию:"
        print_info "  git clone https://github.com/vinyardrip/dpx.git"
        print_info "  cd dpx && ./install.sh"
        return 1
    fi

    # Текущая версия
    local current_version="$DPX_VERSION"
    print_info "Текущая версия: v${current_version}"

    # Получаем информацию о remote
    local remote_url
    remote_url=$(git -C "$DPX_ROOT" config --get remote.origin.url 2>/dev/null || echo "")

    if [[ -n "$remote_url" ]]; then
        print_info "Репозиторий: $remote_url"
    else
        print_warning "Remote origin не настроен."
        return 1
    fi

    # Fetch для проверки обновлений
    print_info "Проверка обновлений..."
    if ! git -C "$DPX_ROOT" fetch origin 2>/dev/null; then
        print_error "Не удалось получить информацию об обновлениях."
        print_info "Проверьте подключение к интернету и доступ к репозиторию."
        return 1
    fi

    # Сравниваем локальную и удалённую ветки
    local current_branch
    current_branch=$(git -C "$DPX_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    local local_hash remote_hash
    local_hash=$(git -C "$DPX_ROOT" rev-parse HEAD 2>/dev/null)
    remote_hash=$(git -C "$DPX_ROOT" rev-parse "origin/${current_branch}" 2>/dev/null)

    if [[ "$local_hash" == "$remote_hash" ]]; then
        print_success "Установлена последняя версия (v${current_version})."
        return 0
    fi

    # Есть обновления
    local commits_behind
    commits_behind=$(git -C "$DPX_ROOT" rev-list --count "HEAD..origin/${current_branch}" 2>/dev/null || echo "?")

    print_info "Доступно обновление: ${commits_behind} коммитов позади."

    # Показываем список изменений
    print_info "Изменения:"
    git -C "$DPX_ROOT" log --oneline "HEAD..origin/${current_branch}" 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    if [[ "$check_only" == true ]]; then
        print_info "Для установки выполните: ${TOOL_NAME} update"
        return 0
    fi

    # Подтверждение
    if ! has_arg "yes"; then
        if ! confirm "Установить обновление?"; then
            print_info "Обновление отменено."
            return 0
        fi
    fi

    # Выполняем git pull
    print_info "Загрузка обновлений..."
    if git -C "$DPX_ROOT" pull origin "$current_branch" 2>/dev/null; then
        # Читаем новую версию
        local new_version
        if [[ -f "${DPX_ROOT}/.version" ]]; then
            new_version=$(head -1 "${DPX_ROOT}/.version" | tr -d '[:space:]')
        else
            new_version="unknown"
        fi

        print_success "Обновление установлено: v${current_version} → v${new_version}"

        # Переустановка симлинка
        if [[ -f "${DPX_ROOT}/install.sh" ]]; then
            print_info "Обновление симлинка..."
            bash "${DPX_ROOT}/install.sh" install 2>/dev/null || true
        fi
    else
        print_error "Не удалось установить обновление."
        print_info "Возможно, есть локальные изменения. Проверьте: git -C ${DPX_ROOT} status"
        return 1
    fi
}
