#!/usr/bin/env bash
# =================================================================
# DPX Test Runner - запуск всех тестов
# =================================================================

# =================================================================
# ПРОВЕРКА ВЕРСИИ BASH (защита от macOS Bash 3.2)
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ОШИБКА: DPX Test Runner требует Bash 4.0+" >&2
    echo "Текущая версия: ${BASH_VERSION:-неизвестно}" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS: установите brew install bash и обновите PATH" >&2
    fi
    exit 1
fi

# =================================================================
# ИНИЦИАЛИЗАЦИЯ
# =================================================================

# Определяем директорию тестов (где лежит run_tests.sh)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Цвета
if command -v tput >/dev/null 2>&1; then
    GREEN=$(tput setaf 2); RED=$(tput setaf 1); YELLOW=$(tput setaf 3); CYAN=$(tput setaf 6); BOLD=$(tput bold); RESET=$(tput sgr0)
else
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
fi

# Счетчики
TOTAL_RUN=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

echo ""
echo "${BOLD}========================================${RESET}"
echo "${BOLD}        DPX Test Suite v1.2.0${RESET}"
echo "${BOLD}========================================${RESET}"
echo ""

# =================================================================
# АВТОПОИСК ТЕСТОВ
# =================================================================

# Ищем все test_*.sh файлы
# Если run_tests.sh в корне проекта - ищем в tests/
# Если run_tests.sh в tests/ - ищем в текущей директории
TEST_FILES=()

# Вариант 1: тесты в подпапке tests/ (run_tests.sh в корне)
if [[ -d "$TESTS_DIR/tests" ]]; then
    for f in "$TESTS_DIR/tests"/test_*.sh; do
        [[ -e "$f" ]] && TEST_FILES+=("$f")
    done
fi

# Вариант 2: тесты рядом с run_tests.sh (оба в tests/)
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    for f in "$TESTS_DIR"/test_*.sh; do
        [[ -e "$f" ]] && TEST_FILES+=("$f")
    done
fi

# Проверка наличия тестов
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "${RED}Тесты не найдены в директории: $TESTS_DIR${RESET}"
    echo "${YELLOW}Ищите файлы с именем test_*.sh${RESET}"
    exit 1
fi

# =================================================================
# ФУНКЦИЯ ЗАПУСКА ТЕСТА
# =================================================================

run_test_file() {
    local test_file="$1"
    local test_name=$(basename "$test_file" .sh)
    
    echo "${CYAN}>>> Running: ${test_name}${RESET}"
    echo "----------------------------------------"
    
    # Запускаем тест через тот же интерпретатор Bash, что и раннер
    # Важно для macOS: используем ${BASH}, а не системный /bin/bash (3.2)
    local output
    local exit_code
    
    output=$("${BASH}" "$test_file" 2>&1)
    exit_code=$?
    
    echo "$output"
    
    # Парсим результаты из вывода
    # Используем grep -oE вместо grep -oP для совместимости с macOS/BSD
    local run passed failed skipped
    
    run=$(echo "$output" | grep -oE 'Total:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    passed=$(echo "$output" | grep -oE 'Passed:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    failed=$(echo "$output" | grep -oE 'Failed:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    skipped=$(echo "$output" | grep -oE 'Skipped:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)
    
    # Защита от пустых значений (используем ${var:-0})
    # Предотвращает ошибку "operand expected" при сложении
    run=${run:-0}
    passed=${passed:-0}
    failed=${failed:-0}
    skipped=${skipped:-0}
    
    TOTAL_RUN=$((TOTAL_RUN + run))
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped))
    
    echo ""
    
    return $exit_code
}

# =================================================================
# ЗАПУСК ТЕСТОВ
# =================================================================

for test_file in "${TEST_FILES[@]}"; do
    run_test_file "$test_file"
done

# =================================================================
# ИТОГОВЫЙ ОТЧЕТ
# =================================================================

echo "${BOLD}========================================${RESET}"
echo "${BOLD}         FINAL TEST REPORT${RESET}"
echo "${BOLD}========================================${RESET}"
echo ""
printf "Total Tests:   %d\n" "$TOTAL_RUN"
printf "${GREEN}Passed:        %d${RESET}\n" "$TOTAL_PASSED"
printf "${RED}Failed:        %d${RESET}\n" "$TOTAL_FAILED"
printf "${YELLOW}Skipped:       %d${RESET}\n" "$TOTAL_SKIPPED"
echo ""

if [[ $TOTAL_FAILED -gt 0 ]]; then
    echo "${RED}${BOLD}✗ SOME TESTS FAILED${RESET}"
    exit 1
else
    echo "${GREEN}${BOLD}✓ ALL TESTS PASSED${RESET}"
    exit 0
fi
