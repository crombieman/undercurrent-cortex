#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

begin_suite "drift-detector"

SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell.
# drift-detector.sh now sources event-io.sh (not the sandbox's sed-patched
# state-io.sh copy — see hooks/scripts/drift-detector.sh's opt-in gate
# comment), which resolves the project dir from this env var at call time, so
# it must be set here explicitly (pattern: tests/integration/test-post-dispatch.sh:22).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"

run_drift() {
  local day_of_year="$1"
  create_mock_date "$MOCK_BIN" "$day_of_year"
  create_mock_git "$MOCK_BIN" "clean"
  create_state_file "$_TEST_TMPDIR/.claude" "drift-test" > /dev/null
  echo '{}' | bash "$SANDBOX/hooks/scripts/drift-detector.sh" 2>/dev/null || true
}

# Check 0 (even day): process.env usage

# Test 1: Clean � no bare process.env
setup_test
rm -rf "$_TEST_TMPDIR/src" && mkdir -p "$_TEST_TMPDIR/src/lib" "$_TEST_TMPDIR/src/__tests__"
echo 'export const env = process.env.MY_VAR;' > "$_TEST_TMPDIR/src/lib/env.ts"
echo 'import { env } from "./env";' > "$_TEST_TMPDIR/src/lib/utils.ts"
result=$(run_drift 2)
assert_eq "check0_clean_no_process_env" "{}" "$result"

# Test 2: process.env drift detected
setup_test
rm -rf "$_TEST_TMPDIR/src" && mkdir -p "$_TEST_TMPDIR/src/lib" "$_TEST_TMPDIR/src/__tests__"
echo 'export const env = process.env.MY_VAR;' > "$_TEST_TMPDIR/src/lib/env.ts"
echo 'const key = process.env.SECRET_KEY;' > "$_TEST_TMPDIR/src/lib/bad.ts"
result=$(run_drift 2)
assert_contains "check0_process_env_drift" "$result" "Drift"

# Test 3: Exempt vars (NEXT_PUBLIC_, NODE_ENV) � no drift
setup_test
rm -rf "$_TEST_TMPDIR/src" && mkdir -p "$_TEST_TMPDIR/src/lib" "$_TEST_TMPDIR/src/__tests__"
echo 'export const env = process.env.MY_VAR;' > "$_TEST_TMPDIR/src/lib/env.ts"
echo 'const x = process.env.NEXT_PUBLIC_URL;' > "$_TEST_TMPDIR/src/lib/client.ts"
echo 'const y = process.env.NODE_ENV;' > "$_TEST_TMPDIR/src/lib/config.ts"
result=$(run_drift 2)
assert_eq "check0_exempt_vars_no_drift" "{}" "$result"

# Check 1 (odd day): docs freshness (needs real git, skip in sandbox)

# Test 4: No git � returns {}
setup_test
result=$(run_drift 1)
assert_eq "check1_no_git" "{}" "$result"

# Test 5: Output has additional_context when drift found
setup_test
rm -rf "$_TEST_TMPDIR/src" && mkdir -p "$_TEST_TMPDIR/src/lib" "$_TEST_TMPDIR/src/__tests__"
echo 'export const env = process.env.MY_VAR;' > "$_TEST_TMPDIR/src/lib/env.ts"
echo 'const key = process.env.SECRET_KEY;' > "$_TEST_TMPDIR/src/lib/bad.ts"
result=$(run_drift 2)
assert_contains "output_has_additional_context" "$result" "additional_context"

# Test 6: Output is valid JSON when drift found
setup_test
rm -rf "$_TEST_TMPDIR/src" && mkdir -p "$_TEST_TMPDIR/src/lib" "$_TEST_TMPDIR/src/__tests__"
echo 'export const env = process.env.MY_VAR;' > "$_TEST_TMPDIR/src/lib/env.ts"
echo 'const key = process.env.SECRET_KEY;' > "$_TEST_TMPDIR/src/lib/bad.ts"
result=$(run_drift 2)
assert_json_valid "output_valid_json" "$result"

export PATH="$SAVED_PATH"
end_suite
