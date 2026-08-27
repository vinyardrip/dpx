#!/usr/bin/env bash
# =================================================================
# DPX Unit Tests: i18n locale resolution & message grammar
#
# Covers:
#   - Locale auto-detection chain: DPX_LANG -> LC_ALL -> LANG -> en;
#   - Russian output for covered keys under ru locale;
#   - Grammatically clean English default (no stemming artifacts);
#   - Canonical refresh non-WP warning/confirm pair (both locales).
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: tests require Bash 4.0+" >&2
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DPX_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export DPX_ROOT

# shellcheck disable=SC1091
source "$TESTS_DIR/test_framework.sh"

print_test_header "Unit Tests: i18n locale layer" "1.0.0"
setup_temp_dir >/dev/null

check_value() {
    if [[ "$1" == "$2" ]]; then
        test_pass
    else
        test_fail "expected '$1', got '$2'"
    fi
}

probe() { # $1 = env assignments (run inside), $2 = shell snippet
    # Baseline clears ALL locale sources so each case models its own env
    env DPX_LANG= LC_ALL= LANG= bash -c "
        export DPX_ROOT=\"$DPX_ROOT\"
        export PATH=\"$PATH\"
        $1
        source \"\$DPX_ROOT/lib/paths.sh\"
        source \"\$DPX_ROOT/lib/i18n.sh\"
        source \"\$DPX_ROOT/lib/io.sh\"
        $2
    " 2>&1
}

# =================================================================
# Locale detection chain
# =================================================================

echo ""
echo "${TEST_CYAN}=== locale detection ===${TEST_RESET}"

out="$(probe 'export LANG=C LC_ALL=C' 't lbl.step')"
test_start "default (C locale) -> English 'Step'"
check_value "Step" "$out"

# shellcheck disable=SC2016
out="$(probe 'export LANG=ru_RU.UTF-8' 't lbl.step')"
test_start "LANG=ru_RU.UTF-8 -> Russian 'Шаг'"
check_value "Шаг" "$out"

out="$(probe 'export LC_ALL=ru_RU.UTF-8' 't lbl.step')"
test_start "LC_ALL=ru_RU.UTF-8 -> Russian 'Шаг'"
check_value "Шаг" "$out"

out="$(probe 'export LANG=ru_RU.UTF-8 DPX_LANG=en' 't lbl.step')"
test_start "DPX_LANG overrides system LANG (en wins)"
check_value "Step" "$out"

out="$(probe 'export LANG=en_US.UTF-8 DPX_LANG=ru' 't lbl.step')"
test_start "DPX_LANG=ru wins over en_US locale"
check_value "Шаг" "$out"

out="$(probe 'export DPX_LANG=en' 't sel.project.header; t sel.project.outside "ddev logs -f"')"
test_start "[en] project selection headers localized"
check_value $'--- Select project ---\n--- You are outside a project directory. Select project for '\''ddev logs -f'\'' ---' "$out"

out="$(probe 'export DPX_LANG=ru' 't sel.project.header; t sel.project.outside "ddev logs -f"')"
test_start "[ru] project selection headers localized"
check_value $'--- Выберите проект ---\n--- Вы находитесь вне директории проекта. Выберите проект для '\''ddev logs -f'\'' ---' "$out"

# =================================================================
# Localized output through print_* functions
# =================================================================

echo ""
echo "${TEST_CYAN}=== localized CLI output ===${TEST_RESET}"

out="$(probe 'export LANG=ru_RU.UTF-8' 'print_warning "Тестовое сообщение"')"
test_start "[ru] print_warning prefix ВНИМАНИЕ"
if grep -qF "ВНИМАНИЕ: Тестовое сообщение" <<<"$out"; then test_pass; else test_fail "got: $out"; fi

out="$(probe 'true' 'print_warning "Test message"')"
test_start "[en] print_warning prefix WARNING"
if grep -qF "WARNING: Test message" <<<"$out"; then test_pass; else test_fail "got: $out"; fi

out="$(probe 'export LANG=ru_RU.UTF-8' 'print_step 2 Импорт')"
test_start "[ru] print_step label Шаг"
if grep -qF "Шаг 2: Импорт..." <<<"$out"; then test_pass; else test_fail "got: $out"; fi

# =================================================================
# Canonical refresh non-WP pair (release spec wording)
# =================================================================

echo ""
echo "${TEST_CYAN}=== refresh non-WP canonical strings ===${TEST_RESET}"

# shellcheck disable=SC2016  # сниппет исполняется в дочернем bash
out="$(probe 'export LANG=ru_RU.UTF-8' \
    'source "$DPX_ROOT/lib/cms.sh"; t msg.refresh.nonwp.warn Joomla')"
test_start "[ru] warning body matches spec"
if grep -qF "Тип проекта — Joomla. Замена URL в базе данных НЕ будет выполнена." <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

out="$(probe 'export LANG=ru_RU.UTF-8' 't q.refresh.nonwp')"
test_start "[ru] confirm prompt matches spec"
check_value "Продолжить без замены URL?" "$out"

# shellcheck disable=SC2016
out="$(probe 'true' \
    'source "$DPX_ROOT/lib/cms.sh"; t msg.refresh.nonwp.warn Joomla')"
test_start "[en] canonical English wording returned"
check_value "Project type is Joomla. Database URL replacement will NOT be performed." "$out"

# =================================================================
# Tunnel command wording
# =================================================================

echo ""
echo "${TEST_CYAN}=== tunnel locale strings ===${TEST_RESET}"

out="$(probe 'export LANG=C' 't tunnel.project.root; t tunnel.cms.detected; t tunnel.cms.warning Joomla; t tunnel.cms.continue; t tunnel.cms.type; t tunnel.project.running; t tunnel.local_url; t tunnel.host_port_ddev; t tunnel.local_domain; t tunnel.params.header; t tunnel.replace.no; t tunnel.rollback.hint; t tunnel.start.prompt; t tunnel.step.start cloudflare; t tunnel.cloudflare.running 123; t tunnel.waiting_url; t tunnel.created https://example.trycloudflare.com; t tunnel.active; t tunnel.stop_hint')"
test_start "[en] tunnel required strings are localized"
if grep -qF "Root project:" <<<"$out" \
    && grep -qF "CMS autodetected:" <<<"$out" \
    && grep -qF "Project type is Joomla. Database URL replacement will NOT be performed." <<<"$out" \
    && grep -qF "Continue without database URL replacement?" <<<"$out" \
    && grep -qF "Project type:" <<<"$out" \
    && grep -qF "Project is running." <<<"$out" \
    && grep -qF "Host port (DDEV → Docker):" <<<"$out" \
    && grep -qF "Verify parameters" <<<"$out" \
    && grep -qF "No (port forwarding only)" <<<"$out" \
    && grep -qF "Ctrl+C → full rollback: restore snapshot + reverse search-replace" <<<"$out" \
    && grep -qF "Start forwarding tunnel?" <<<"$out" \
    && grep -qF "Starting tunnel (cloudflare)" <<<"$out" \
    && grep -qF "Running cloudflared (PID: 123)..." <<<"$out" \
    && grep -qF "Waiting for tunnel URL..." <<<"$out" \
    && grep -qF "Tunnel created: https://example.trycloudflare.com" <<<"$out" \
    && grep -qF "🎉 Tunnel active! 🎉" <<<"$out" \
    && grep -qF "Press Ctrl+C to stop the tunnel and rollback." <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

out="$(probe 'export LANG=ru_RU.UTF-8' 't tunnel.project.root; t tunnel.cms.detected; t tunnel.cms.warning Joomla; t tunnel.cms.continue; t tunnel.cms.type; t tunnel.project.running; t tunnel.local_url; t tunnel.host_port_ddev; t tunnel.local_domain; t tunnel.params.header; t tunnel.replace.no; t tunnel.rollback.hint; t tunnel.start.prompt; t tunnel.step.start cloudflare; t tunnel.cloudflare.running 123; t tunnel.waiting_url; t tunnel.created https://example.trycloudflare.com; t tunnel.active; t tunnel.stop_hint')"
test_start "[ru] tunnel required strings are localized"
if grep -qF "Корень проекта:" <<<"$out" \
    && grep -qF "Автоопределение CMS:" <<<"$out" \
    && grep -qF "Тип проекта — Joomla. Замена URL в базе данных НЕ будет выполнена." <<<"$out" \
    && grep -qF "Продолжить без замены URL в БД?" <<<"$out" \
    && grep -qF "Тип проекта:" <<<"$out" \
    && grep -qF "Проект запущен." <<<"$out" \
    && grep -qF "Порт хоста (DDEV → Docker):" <<<"$out" \
    && grep -qF "Проверка параметров" <<<"$out" \
    && grep -qF "Нет (только проброс порта)" <<<"$out" \
    && grep -qF "Ctrl+C → полный откат: восстановление из снапшота + обратный search-replace" <<<"$out" \
    && grep -qF "Запустить проброс туннеля?" <<<"$out" \
    && grep -qF "Запуск туннеля (cloudflare)" <<<"$out" \
    && grep -qF "Запуск cloudflared (PID: 123)..." <<<"$out" \
    && grep -qF "Ожидание URL туннеля..." <<<"$out" \
    && grep -qF "Туннель создан: https://example.trycloudflare.com" <<<"$out" \
    && grep -qF "🎉 Туннель активен! 🎉" <<<"$out" \
    && grep -qF "Нажмите Ctrl+C для завершения работы туннеля и отката." <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

# =================================================================
# Grammar artifacts must not exist anywhere in shell sources
# =================================================================

echo ""
echo "${TEST_CYAN}=== stemming artifact sweep ===${TEST_RESET}"

for bad in Continu Creat Updat Restor Delet Cancell Verifi replac continu creat updat restor delet cancell verifi; do
    test_start "no truncated token '$bad' in sources"
    if grep -rqE "\b${bad}\b" "$DPX_ROOT/lib" "$DPX_ROOT/commands" "$DPX_ROOT/dpx.sh" 2>/dev/null; then
        test_fail "found: $(grep -rlE "\b${bad}\b" "$DPX_ROOT/lib" "$DPX_ROOT/commands" | head -1)"
    else
        test_pass
    fi
done

# =================================================================
# new.sh interactive menu respects locale
# =================================================================

echo ""
echo "${TEST_CYAN}=== dpx new menu locale ===${TEST_RESET}"

scen="$TEST_TEMP_DIR/menu.sh"
cat > "$scen" << 'EOF'
export DPX_LANG="${PROBE_LANG:-en}"
source "$DPX_ROOT/lib/core.sh"
source "$DPX_ROOT/lib/cms.sh"
source "$DPX_ROOT/lib/ddev.sh"
source "$DPX_ROOT/lib/projects.sh"
source "$DPX_ROOT/lib/devilbox.sh"
source "$DPX_ROOT/commands/new.sh"
printf '4\n' | new_select_type
EOF

out="$(env PROBE_LANG=ru bash -c "export DPX_ROOT=\"$DPX_ROOT\"; bash \"$scen\"" 2>&1)"
test_start "[ru][new] menu header localized, value intact"
# Примечание: read -p подавляет промпт при stdin!=TTY, поэтому сам
# текст промпта проверяем прямым вызовом t() ниже.
if grep -qF -- "--- Выберите тип проекта ---" <<<"$out" \
   && grep -qxF "ocstore" <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

out="$(env PROBE_LANG=en bash -c "export DPX_ROOT=\"$DPX_ROOT\"; bash \"$scen\"" 2>&1)"
test_start "[en][new] menu header English, value intact"
if grep -qF -- "--- Select project type ---" <<<"$out" \
   && grep -qxF "ocstore" <<<"$out"; then
    test_pass
else
    test_fail "got: $out"
fi

# =================================================================
echo ""
echo "${TEST_CYAN}=== menu prompt text via t() ===${TEST_RESET}"

test_start "[ru] menu.new.prompt wording"
ru_prompt="$(env DPX_LANG= LC_ALL= LANG=ru_RU.UTF-8 bash -c "
    export DPX_ROOT=\"$DPX_ROOT\"
    source lib/paths.sh; source lib/i18n.sh; t menu.new.prompt")"
check_value "Выберите [1-6]: " "$ru_prompt"

test_start "[en] menu.new.prompt wording"
en_prompt="$(env DPX_LANG= LC_ALL=C LANG=C bash -c "
    export DPX_ROOT=\"$DPX_ROOT\"
    source lib/paths.sh; source lib/i18n.sh; t menu.new.prompt")"
check_value "Select [1-6]: " "$en_prompt"


print_test_summary
cleanup_temp_dir
exit $(( TESTS_FAILED > 0 ))
