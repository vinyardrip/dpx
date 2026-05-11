#!/usr/bin/env bash
# =================================================================
# DPX Test Framework - легковесный фреймворк для unit-тестов
# =================================================================

# =================================================================
# ПРОВЕРКА ВЕРСИИ BASH
# =================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ОШИБКА: Test Framework требует Bash 4.0+" >&2
    exit 1
fi

# =================================================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# =================================================================

# Счетчики
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# [FIX] Флаг состояния текущего теста (защита от False Positives)
# Предотвращает двойной счёт когда test_pass вызывается после test_fail
CURRENT_TEST_FAILED=0
CURRENT_TEST=""

# Временная директория
TEST_TEMP_DIR=""

# Цвета (совместимость с терминалом и fallback)
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    TEST_GREEN=$(tput setaf 2)
    TEST_RED=$(tput setaf 1)
    TEST_YELLOW=$(tput setaf 3)
    TEST_CYAN=$(tput setaf 6)
    TEST_BOLD=$(tput bold)
    TEST_RESET=$(tput sgr0)
else
    TEST_GREEN='\033[0;32m'
    TEST_RED='\033[0;31m'
    TEST_YELLOW='\033[1;33m'
    TEST_CYAN='\033[0;36m'
    TEST_BOLD='\033[1m'
    TEST_RESET='\033[0m'
fi

# =================================================================
# ОСНОВНЫЕ ФУНКЦИИ ТЕСТИРОВАНИЯ
# =================================================================

# Начало теста (сбрасывает флаг состояния)
test_start() {
    local name="$1"
    CURRENT_TEST="$name"
    CURRENT_TEST_FAILED=0  # [FIX] Сброс флага для каждого нового теста
    ((TESTS_RUN++))
    printf "  Testing: %-50s " "$name"
}

# Успешное завершение теста
test_pass() {
    # [FIX] Засчитываем успех ТОЛЬКО если не было вызовов test_fail
    # Это делает фреймворк "пуленепробиваемым" - test_pass после test_fail игнорируется
    if [[ $CURRENT_TEST_FAILED -eq 0 ]]; then
        printf "${TEST_GREEN}✓ PASS${TEST_RESET}\n"
        ((TESTS_PASSED++))
    fi
}

# Неудачное завершение теста
test_fail() {
    local reason="${1:-}"

    # [FIX] Если тест уже был провален ранее, не плюсуем счетчик дважды
    if [[ $CURRENT_TEST_FAILED -eq 0 ]]; then
        printf "${TEST_RED}✗ FAIL${TEST_RESET}\n"
        ((TESTS_FAILED++))
        CURRENT_TEST_FAILED=1
    fi

    if [[ -n "$reason" ]]; then
        printf "           ${TEST_RED}Reason: %s${TEST_RESET}\n" "$reason"
    fi
}

# Пропуск теста
test_skip() {
    local reason="${1:-No reason provided}"
    printf "${TEST_YELLOW}⊘ SKIP${TEST_RESET}\n"
    ((TESTS_SKIPPED++))
    if [[ -n "$reason" ]]; then
        printf "           ${TEST_YELLOW}Reason: %s${TEST_RESET}\n" "$reason"
    fi
}

# =================================================================
# ASSERT ФУНКЦИИ (Assertion Library)
# =================================================================

# Проверка равенства строк
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        test_fail "$message: expected '$expected', got '$actual'"
        return 1
    fi
}

# Проверка неравенства строк
assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"

    if [[ "$expected" != "$actual" ]]; then
        return 0
    else
        test_fail "$message: values should differ but both are '$expected'"
        return 1
    fi
}

# Проверка, что строка содержит подстроку
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        test_fail "$message: '$haystack' does not contain '$needle'"
        return 1
    fi
}

# Проверка, что строка НЕ содержит подстроку
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    else
        test_fail "$message: '$haystack' contains '$needle'"
        return 1
    fi
}

# Проверка, что строка пустая
assert_empty() {
    local value="$1"
    local message="${2:-Value should be empty}"

    if [[ -z "$value" ]]; then
        return 0
    else
        test_fail "$message: expected empty, got '$value'"
        return 1
    fi
}

# Проверка, что строка НЕ пустая
assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"

    if [[ -n "$value" ]]; then
        return 0
    else
        test_fail "$message: value is empty"
        return 1
    fi
}

# Проверка истинности (true/1)
# [FIX] Исправлена ошибка типизации - используем строковое сравнение вместо -eq
# Оператор -eq предназначен только для чисел и может вызвать ошибку при строковых значениях
assert_true() {
    local condition="$1"
    local message="${2:-Condition should be true}"

    # [FIX] Безопасное строковое сравнение вместо числового -eq
    if [[ "$condition" == "true" || "$condition" == "1" ]]; then
        return 0
    else
        test_fail "$message: expected true/1, got '$condition'"
        return 1
    fi
}

# Проверка ложности (false/0/empty)
# [FIX] Исправлена ошибка типизации - используем строковое сравнение вместо -eq
assert_false() {
    local condition="$1"
    local message="${2:-Condition should be false}"

    # [FIX] Безопасное строковое сравнение вместо числового -eq
    if [[ "$condition" == "false" || "$condition" == "0" || -z "$condition" ]]; then
        return 0
    else
        test_fail "$message: expected false/0/empty, got '$condition'"
        return 1
    fi
}

# Проверка существования файла
assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"

    if [[ -f "$file" ]]; then
        return 0
    else
        test_fail "$message: file '$file' does not exist"
        return 1
    fi
}

# Проверка отсутствия файла
assert_file_not_exists() {
    local file="$1"
    local message="${2:-File should not exist}"

    if [[ ! -f "$file" ]]; then
        return 0
    else
        test_fail "$message: file '$file' exists"
        return 1
    fi
}

# Проверка существования директории
assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory should exist}"

    if [[ -d "$dir" ]]; then
        return 0
    else
        test_fail "$message: directory '$dir' does not exist"
        return 1
    fi
}

# Проверка, что команда успешна (exit code 0)
assert_success() {
    local exit_code=$1
    local message="${2:-Command should succeed}"

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        test_fail "$message: exit code $exit_code"
        return 1
    fi
}

# Проверка, что команда падает (exit code != 0)
assert_failure() {
    local exit_code=$1
    local message="${2:-Command should fail}"

    if [[ $exit_code -ne 0 ]]; then
        return 0
    else
        test_fail "$message: expected failure but got exit code 0"
        return 1
    fi
}

# =================================================================
# УПРАВЛЕНИЕ ВРЕМЕННОЙ ДИРЕКТОРИЕЙ
# =================================================================

# Создание временной директории
# [FIX] Добавлен trap для гарантированной очистки при любом завершении
setup_temp_dir() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dpx_test_XXXXXX")

    # [FIX] Гарантированная очистка при любом завершении скрипта
    # Сработает даже при exit 1 или Ctrl+C
    trap 'cleanup_temp_dir' EXIT

    echo "Test directory: $TEST_TEMP_DIR"
}

# Очистка временной директории
cleanup_temp_dir() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
        TEST_TEMP_DIR=""
    fi
}

# =================================================================
# ГЕНЕРАТОРЫ MOCK-ОБЪЕКТОВ
# =================================================================

# Создание фейкового проекта WordPress
create_fake_wordpress_project() {
    local project_dir="$1"
    local project_name="${2:-testproject}"
    local site_url="${3:-https://${project_name}.ddev.site}"

    mkdir -p "$project_dir"
    mkdir -p "$project_dir/wp-content/themes"
    mkdir -p "$project_dir/.ddev"

    # wp-config.php
    cat > "$project_dir/wp-config.php" << 'PHPEOF'
<?php
define('DB_NAME', 'db');
define('DB_USER', 'db');
define('DB_PASSWORD', 'db');
define('DB_HOST', 'db');
define('WP_SITEURL', 'https://example.com');
 $table_prefix = 'wp_';
PHPEOF

    # DDEV config.yaml
    cat > "$project_dir/.ddev/config.yaml" << YAML
name: $project_name
type: wordpress
docroot: ""
php_version: "8.1"
webserver_type: nginx-fpm
YAML

    # Фейковая тема
    mkdir -p "$project_dir/wp-content/themes/test-theme"
    echo "/* Theme */" > "$project_dir/wp-content/themes/test-theme/style.css"

    echo "$project_dir"
}

# Создание фейкового проекта Joomla
create_fake_joomla_project() {
    local project_dir="$1"
    local project_name="${2:-joomlatest}"

    mkdir -p "$project_dir"
    mkdir -p "$project_dir/administrator"
    mkdir -p "$project_dir/components"
    mkdir -p "$project_dir/.ddev"

    # configuration.php
    cat > "$project_dir/configuration.php" << 'PHPEOF'
<?php
class JConfig {
    public $host = 'db';
    public $user = 'db';
    public $password = 'db';
    public $db = 'db';
    public $live_site = 'https://example.com';
}
PHPEOF

    # DDEV config.yaml
    cat > "$project_dir/.ddev/config.yaml" << YAML
name: $project_name
type: php
docroot: ""
php_version: "8.0"
webserver_type: apache-fpm
YAML

    echo "$project_dir"
}

# Создание фейкового DDEV проекта (generic)
create_fake_ddev_project() {
    local project_dir="$1"
    local project_name="${2:-genericproject}"
    local project_type="${3:-php}"
    local php_version="${4:-8.1}"

    mkdir -p "$project_dir/.ddev"

    cat > "$project_dir/.ddev/config.yaml" << YAML
name: $project_name
type: $project_type
docroot: ""
php_version: "$php_version"
webserver_type: nginx-fpm
YAML

    # Файловая структура
    mkdir -p "$project_dir/public"
    echo "<?php echo 'Hello';" > "$project_dir/public/index.php"

    echo "$project_dir"
}

# Создание фейкового SQL-дампа
create_fake_sql_dump() {
    local output_file="$1"
    local db_name="${2:-testdb}"

    cat > "$output_file" << SQLEOF
-- MySQL dump
-- Database: $db_name

CREATE TABLE wp_options (
    option_id bigint(20) NOT NULL,
    option_name varchar(191) NOT NULL,
    option_value longtext NOT NULL
);

INSERT INTO wp_options VALUES (1, 'siteurl', 'https://example.ddev.site');
INSERT INTO wp_options VALUES (2, 'home', 'https://example.ddev.site');
SQLEOF

    echo "$output_file"
}

# Создание фейкового конфига DPX
create_fake_dpx_config() {
    local config_dir="$1"

    mkdir -p "$config_dir"

    cat > "$config_dir/config.sh" << 'BASH'
# DPX Config
DDEV_PROJECTS_BASE_PATH="$HOME/projects"
DB_PROD_PATH="$HOME/backups/prod"
DB_LOCAL_PATH="$HOME/backups/local"
DEFAULT_PHP_VERSION="8.1"
PROJECT_TLD="ddev.site"
DEFAULT_PROD_TLD="by"
BASH

    echo "$config_dir"
}

# =================================================================
# ИТОГОВАЯ ОТЧЁТНОСТЬ
# =================================================================

print_test_summary() {
    echo ""
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo "${TEST_BOLD}         Test Results Summary${TEST_RESET}"
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo ""
    printf "Total:    %d\n" "$TESTS_RUN"
    printf "${TEST_GREEN}Passed:   %d${TEST_RESET}\n" "$TESTS_PASSED"
    printf "${TEST_RED}Failed:   %d${TEST_RESET}\n" "$TESTS_FAILED"
    printf "${TEST_YELLOW}Skipped:  %d${TEST_RESET}\n" "$TESTS_SKIPPED"
    echo ""

    # Проверка целостности статистики
    local calculated_total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    if [[ $calculated_total -ne $TESTS_RUN ]]; then
        echo "${TEST_RED}WARNING: Statistics mismatch!${TEST_RESET}"
        echo "  Expected: $TESTS_RUN, Got: $calculated_total"
    fi

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "${TEST_RED}${TEST_BOLD}✗ SOME TESTS FAILED${TEST_RESET}"
        return 1
    else
        echo "${TEST_GREEN}${TEST_BOLD}✓ ALL TESTS PASSED${TEST_RESET}"
        return 0
    fi
}

# =================================================================
# ИНИЦИАЛИЗАЦИЯ ЗАГОЛОВКА
# =================================================================

print_test_header() {
    local suite_name="${1:-Test Suite}"
    local version="${2:-1.0.0}"

    echo ""
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo "${TEST_BOLD}     $suite_name v$version${TEST_RESET}"
    echo "${TEST_BOLD}========================================${TEST_RESET}"
    echo ""
}