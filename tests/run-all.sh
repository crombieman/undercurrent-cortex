#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args
FILTER="${1:-}"
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
  esac
done

# Discover test files in order: unit, integration, edge, regression
test_files=()
for dir in unit integration edge regression; do
  for f in "$TESTS_DIR/$dir"/test-*.sh; do
    [ -f "$f" ] || continue
    if [ -n "$FILTER" ] && [ "$FILTER" != "--verbose" ] && [ "$FILTER" != "-v" ]; then
      case "$(basename "$f")" in
        *"$FILTER"*) test_files+=("$f") ;;
      esac
    else
      test_files+=("$f")
    fi
  done
done

echo "================================="
echo "  Cortex Plugin Test Suite"
echo "  $(date +%Y-%m-%d\ %H:%M:%S)"
echo "  ${#test_files[@]} test files found"
echo "================================="
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_SUITES=()
start_time=$(date +%s)

for tf in "${test_files[@]}"; do
  suite_name=$(basename "$tf" .sh | sed 's/^test-//')

  # Reset per-suite counters (prevent stale values from previous suite)
  s_pass=0
  s_fail=0
  s_skip=0

  # Run in subshell, capture output
  result=$(bash "$tf" 2>&1) || true

  # Parse SUITE summary line
  summary_line=$(echo "$result" | grep '^SUITE ' | tail -1) || true
  if [ -n "$summary_line" ]; then
    s_pass=$(echo "$summary_line" | sed 's/.*PASS=\([0-9]*\).*/\1/') || true
    s_fail=$(echo "$summary_line" | sed 's/.*FAIL=\([0-9]*\).*/\1/') || true
    s_skip=$(echo "$summary_line" | sed 's/.*SKIP=\([0-9]*\).*/\1/') || true
    TOTAL_PASS=$((TOTAL_PASS + ${s_pass:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${s_fail:-0}))
    TOTAL_SKIP=$((TOTAL_SKIP + ${s_skip:-0}))
    if [ "${s_fail:-0}" -gt 0 ]; then
      FAILED_SUITES+=("$suite_name")
    fi
  else
    # No SUITE line — suite crashed
    FAILED_SUITES+=("$suite_name (CRASHED)")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi

  # Print output
  if [ -z "$summary_line" ]; then
    # No SUITE line means the suite crashed before reaching end_suite — must
    # never fall through to the "0 tests" branch below, which would render
    # it as a green PASS even though it's counted as a failure above.
    printf "  \033[31mCRASHED\033[0m  %s (no SUITE line)\n" "$suite_name"
    if [ "$VERBOSE" = true ]; then
      echo "$result"
    fi
  elif [ "$VERBOSE" = true ] || echo "$result" | grep -qF 'FAIL'; then
    echo "$result" | grep -v '^SUITE ' || true
  else
    if [ "${s_fail:-0}" -gt 0 ]; then
      printf "  \033[31mFAIL\033[0m  %s (%s passed, %s failed)\n" "$suite_name" "${s_pass:-0}" "${s_fail:-0}"
    else
      printf "  \033[32mPASS\033[0m  %s (%s tests)\n" "$suite_name" "${s_pass:-0}"
    fi
  fi
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))

echo ""
echo "================================="
printf "  \033[32m%d passed\033[0m" "$TOTAL_PASS"
[ "$TOTAL_FAIL" -gt 0 ] && printf ", \033[31m%d failed\033[0m" "$TOTAL_FAIL"
[ "$TOTAL_SKIP" -gt 0 ] && printf ", \033[33m%d skipped\033[0m" "$TOTAL_SKIP"
echo ""
echo "  ${elapsed}s elapsed"
if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
  echo ""
  echo "  Failed suites:"
  for ft in "${FAILED_SUITES[@]}"; do
    printf "    \033[31m- %s\033[0m\n" "$ft"
  done
fi
echo "================================="

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
