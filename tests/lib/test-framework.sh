#!/usr/bin/env bash
# Cortex Plugin Test Framework
# Core assertion functions + colored output + SUITE reporting.
# Sourced by every test file.

_PASS_COUNT=0
_FAIL_COUNT=0
_SKIP_COUNT=0
_SUITE_NAME=""
_TEST_TMPDIR=""

# Colors
_GREEN='\033[32m'
_RED='\033[31m'
_YELLOW='\033[33m'
_RESET='\033[0m'

# Called once per test file
begin_suite() {
  _SUITE_NAME="$1"
  _PASS_COUNT=0
  _FAIL_COUNT=0
  _SKIP_COUNT=0

  # Create isolated temp directory. Priority: TEST_TMPDIR (explicit test-run
  # override) > TMPDIR (standard env convention) > /tmp (default). If mktemp
  # -d fails against that base entirely (no writable system temp dir at
  # all — sandboxed CI, restricted container, a bogus override), fall back
  # to a project-local .superpowers/tmp/ (created if needed) so the suite
  # can still run instead of crashing under set -e before its first test.
  local _base_tmpdir="${TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  _TEST_TMPDIR=$(mktemp -d "${_base_tmpdir}/cortex-test-XXXXXX" 2>/dev/null) || true
  if [ -z "$_TEST_TMPDIR" ] || [ ! -d "$_TEST_TMPDIR" ]; then
    local _fallback_dir
    _fallback_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.superpowers/tmp"
    mkdir -p "$_fallback_dir"
    _TEST_TMPDIR=$(mktemp -d "${_fallback_dir}/cortex-test-XXXXXX")
  fi

  # Create mock project structure
  mkdir -p "$_TEST_TMPDIR/.claude"
  mkdir -p "$_TEST_TMPDIR/memory"
  mkdir -p "$_TEST_TMPDIR/tasks"
  mkdir -p "$_TEST_TMPDIR/src/__tests__"
  mkdir -p "$_TEST_TMPDIR/supabase/migrations"
  mkdir -p "$_TEST_TMPDIR/src/app/api"
  mkdir -p "$_TEST_TMPDIR/.claude/plans"

  printf "\n  %-40s\n" "$_SUITE_NAME"
  printf "  %s\n" "----------------------------------------"
}

# Called at end of test file
end_suite() {
  rm -rf "$_TEST_TMPDIR" 2>/dev/null || true
  echo "SUITE $_SUITE_NAME PASS=$_PASS_COUNT FAIL=$_FAIL_COUNT SKIP=$_SKIP_COUNT"
}

# Run before each test to reset temp dir state
setup_test() {
  rm -rf "$_TEST_TMPDIR/.claude/"* 2>/dev/null || true
  rm -rf "$_TEST_TMPDIR/memory/"* 2>/dev/null || true
  rm -rf "$_TEST_TMPDIR/tasks/"* 2>/dev/null || true
  mkdir -p "$_TEST_TMPDIR/.claude"
}

# --- Assertions ---

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          expected: %s\n" "$expected"
    printf "          actual:   %s\n" "$actual"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local test_name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          expected to contain: %s\n" "$needle"
    printf "          actual: %.200s\n" "$haystack"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local test_name="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          expected NOT to contain: %s\n" "$needle"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_file_exists() {
  local test_name="$1" filepath="$2"
  if [ -f "$filepath" ]; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          file not found: %s\n" "$filepath"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_file_contains() {
  local test_name="$1" filepath="$2" pattern="$3"
  if [ -f "$filepath" ] && grep -qF "$pattern" "$filepath" 2>/dev/null; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          file: %s\n" "$filepath"
    printf "          expected to contain: %s\n" "$pattern"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_file_not_contains() {
  local test_name="$1" filepath="$2" pattern="$3"
  if [ -f "$filepath" ] && ! grep -qF "$pattern" "$filepath" 2>/dev/null; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          file: %s\n" "$filepath"
    printf "          expected NOT to contain: %s\n" "$pattern"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_json_valid() {
  local test_name="$1" json_str="$2"
  local trimmed
  trimmed=$(echo "$json_str" | tr -d '[:space:]')
  if [[ "$trimmed" == "{"* && "$trimmed" == *"}" ]]; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$test_name"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$test_name"
    printf "          not valid JSON: %.100s\n" "$json_str"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

assert_exit_code() {
  local test_name="$1" expected="$2" actual="$3"
  assert_eq "$test_name" "$expected" "$actual"
}

skip_test() {
  local test_name="$1" reason="${2:-}"
  printf "    ${_YELLOW}SKIP${_RESET}  %s" "$test_name"
  [ -n "$reason" ] && printf " (%s)" "$reason"
  printf "\n"
  _SKIP_COUNT=$((_SKIP_COUNT + 1))
}
