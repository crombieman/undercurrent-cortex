#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

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

# Fail-open when deny-once state can't persist (W5 review I-1): a read-only
# log means plan_guard_denied never lands, so "blocks once" would become an
# INDEFINITE deny. Warn without blocking instead.
setup_test
plan_file="$_TEST_TMPDIR/.claude/plans/ro-plan.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i of the existing plan" >> "$plan_file"
done
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pg-ro")
chmod 444 "$LOG" 2>/dev/null || true
json=$(mock_json "tool_name=Write" "session_id=pg-ro" \
  "tool_input.file_path=$plan_file" \
  "tool_input.content=Overwritten content")
result=$(run_plan_guard "$json")
chmod 644 "$LOG" 2>/dev/null || true
assert_not_contains "readonly_log_no_deny" "$result" "\"permissionDecision\":\"deny\""
assert_contains "readonly_log_warns_instead" "$result" "WARNING"

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

# --- Deny-once escape hatch (spec §3.3 vocabulary: plan_guard_denied) ---

# Test 6: First deny on a path appends a plan_guard_denied event for that path
setup_test
plan_file="$_TEST_TMPDIR/.claude/plans/escape-plan.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i of the existing plan" >> "$plan_file"
done
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pfg-test")
json=$(mock_json "tool_name=Write" "session_id=pfg-test" \
  "tool_input.file_path=$plan_file" \
  "tool_input.content=Overwritten content")
result=$(run_plan_guard "$json")
assert_contains "first_deny_still_blocks" "$result" "deny"
denied_value=$(last_event plan_guard_denied "$LOG")
assert_eq "first_deny_appends_plan_guard_denied_event" "$plan_file" "$denied_value"

# Test 7: Second Write attempt on the SAME path in the SAME session is
# ALLOWED — the deny-once escape hatch (a plan_guard_denied event for this
# exact path already exists in the session log).
setup_test
plan_file="$_TEST_TMPDIR/.claude/plans/escape-plan2.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i of the existing plan" >> "$plan_file"
done
create_event_log "$_TEST_TMPDIR/.claude" "pfg-escape" \
  "1700000001|plan_guard_denied|${plan_file}" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pfg-escape" \
  "tool_input.file_path=$plan_file" \
  "tool_input.content=Overwritten again, this time on purpose")
result=$(run_plan_guard "$json")
assert_eq "second_write_same_path_allowed" "{}" "$result"

# Test 8: A plan_guard_denied event for a DIFFERENT path does not unlock this
# one — still denies (and appends its own plan_guard_denied event).
setup_test
plan_file_a="$_TEST_TMPDIR/.claude/plans/escape-plan-a.md"
plan_file_b="$_TEST_TMPDIR/.claude/plans/escape-plan-b.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i" >> "$plan_file_b"
done
create_event_log "$_TEST_TMPDIR/.claude" "pfg-diffpath" \
  "1700000001|plan_guard_denied|${plan_file_a}" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pfg-diffpath" \
  "tool_input.file_path=$plan_file_b" \
  "tool_input.content=Overwritten content")
result=$(run_plan_guard "$json")
assert_contains "different_path_prior_denial_does_not_unlock" "$result" "deny"

# Test 9: No resolvable event log (session_id present but no log on disk) —
# deny-once semantics degrade to always-deny (pre-v4 behavior, unchanged).
setup_test
plan_file="$_TEST_TMPDIR/.claude/plans/escape-plan-nolog.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i" >> "$plan_file"
done
json=$(mock_json "tool_name=Write" "session_id=pfg-nolog" \
  "tool_input.file_path=$plan_file" \
  "tool_input.content=Overwritten content")
result=$(run_plan_guard "$json")
assert_contains "no_event_log_always_denies" "$result" "deny"
json2=$(mock_json "tool_name=Write" "session_id=pfg-nolog" \
  "tool_input.file_path=$plan_file" \
  "tool_input.content=Overwritten content again")
result2=$(run_plan_guard "$json2")
assert_contains "no_event_log_always_denies_repeat" "$result2" "deny"

end_suite
