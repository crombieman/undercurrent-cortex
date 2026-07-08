#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

begin_suite "plan-file-guard"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell.
# plan-file-guard.sh now derives PROJECT_DIR via event-io.sh's
# eio_project_dir() (resolved from this env var at call time), not from the
# sandbox's sed-patched state-io.sh copy — so it must be set here explicitly
# (same pattern as tests/integration/test-post-dispatch.sh).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run plan-file-guard with given JSON
run_plan_guard() {
  local json_input="$1"
  echo "$json_input" | bash "$SANDBOX/hooks/scripts/plan-file-guard.sh" 2>/dev/null || true
}

# Test 1: Block overwrite of existing plan with >50 lines
setup_test
plan_file="$_TEST_TMPDIR/.claude/plans/design-feature.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i of the existing plan" >> "$plan_file"
done
json=$(mock_json "tool_name=Write" \
  "tool_input.file_path=$plan_file" \
  "tool_input.content=Overwritten content")
result=$(run_plan_guard "$json")
assert_contains "block_overwrite_large_plan" "$result" "deny"

# Test 2: Allow new plan file (does not exist yet)
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/plans"
json=$(mock_json "tool_name=Write" \
  "tool_input.file_path=$_TEST_TMPDIR/.claude/plans/new-plan.md" \
  "tool_input.content=Brand new plan")
result=$(run_plan_guard "$json")
assert_eq "allow_new_plan_file" "{}" "$result"

# Test 3: Allow small plan (<=50 lines)
setup_test
small_plan="$_TEST_TMPDIR/.claude/plans/small-plan.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 50); do
  echo "Line $i" >> "$small_plan"
done
json=$(mock_json "tool_name=Write" \
  "tool_input.file_path=$small_plan" \
  "tool_input.content=Overwrite small plan")
result=$(run_plan_guard "$json")
assert_eq "allow_small_plan" "{}" "$result"

# Test 4: Ignore non-plan path (src/ file)
setup_test
json=$(mock_json "tool_name=Write" \
  "tool_input.file_path=src/lib/utils.ts" \
  "tool_input.content=export const x = 1")
result=$(run_plan_guard "$json")
assert_eq "ignore_non_plan_path" "{}" "$result"

# Test 5: Handle relative plan path (resolves against PROJECT_DIR)
setup_test
# Create the plan file at the resolved path
mkdir -p "$_TEST_TMPDIR/.claude/plans"
plan_file="$_TEST_TMPDIR/.claude/plans/relative-plan.md"
for i in $(seq 1 60); do
  echo "Line $i" >> "$plan_file"
done
json=$(mock_json "tool_name=Write" \
  "tool_input.file_path=.claude/plans/relative-plan.md" \
  "tool_input.content=Overwrite")
result=$(run_plan_guard "$json")
assert_contains "handle_relative_plan_path" "$result" "deny"

end_suite
