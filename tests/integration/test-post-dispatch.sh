#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "post-dispatch"

# Create sandbox once for the suite (fast state-io copy for post-bash-dispatch /
# pattern-template sub-handlers; event-io.sh is symlinked unpatched).
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell — event-io.sh
# (unlike the sandbox's sed-patched state-io.sh copy) resolves the project dir
# from this env var at call time, so it must be set here explicitly.
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Set up MOCK_BIN at suite level to avoid subshell PATH issues
MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"

# Helper: run post-dispatch with given JSON input
run_post_dispatch() {
  local json_input="$1"
  echo "$json_input" | bash "$SANDBOX/hooks/scripts/post-dispatch.sh" 2>/dev/null || true
}

# Test 1: Bash tool routes to post-bash-dispatch (returns {} for non-git commands)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-bash" > /dev/null
json=$(mock_json "tool_name=Bash" "session_id=pd-bash" "tool_input.command=echo hello")
result=$(run_post_dispatch "$json")
assert_eq "bash_routes_to_post_bash" "{}" "$result"

# Test 2: Edit tool routes to post-edit-dispatch (appends file_edit) AND
# post-dispatch itself appends a tool_call event. Replaces the pre-conversion
# write_increments_edit_count / edit_increments_edit_count tests, which asserted
# state-file coupling through the routing path that no longer exists.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pd-edit" "1700000001|tool_call|Read")
json=$(mock_json "tool_name=Edit" "session_id=pd-edit" "tool_input.file_path=${_TEST_TMPDIR}/src/lib/scoring.ts")
run_post_dispatch "$json" > /dev/null
tool_calls=$(count_events tool_call '' '' "$LOG")
file_edits=$(list_events file_edit "$LOG")
assert_eq "edit_appends_tool_call_event" "2" "$tool_calls"
assert_contains "edit_routes_to_post_edit_dispatch" "$file_edits" "scoring.ts"

# Test 3: Unknown tool (Read) returns {}
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-read" > /dev/null
json=$(mock_json "tool_name=Read" "session_id=pd-read" "tool_input.file_path=src/lib/utils.ts")
result=$(run_post_dispatch "$json")
assert_eq "unknown_tool_returns_empty" "{}" "$result"

# Test 4: Empty JSON returns {}
setup_test
result=$(echo '{}' | bash "$SANDBOX/hooks/scripts/post-dispatch.sh" 2>/dev/null || true)
assert_eq "empty_json_returns_empty" "{}" "$result"

# Test 5: tool_call counter increments on every dispatch, matched tool or not
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pd-counter" \
  "1700000001|tool_call|Read" \
  "1700000002|tool_call|Bash")
json=$(mock_json "tool_name=Grep" "session_id=pd-counter")
run_post_dispatch "$json" > /dev/null
result=$(count_events tool_call '' '' "$LOG")
assert_eq "tool_call_counter_increments" "3" "$result"

# Test 6: Mid-session checkpoint fires on the 25th tool_call (modulo 25) and
# short-circuits routing (matches v3's exit-on-fire behavior)
setup_test
seed=()
for i in $(seq 1 24); do
  seed+=("$((1700000000 + i))|tool_call|Read")
done
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pd-checkpoint" "${seed[@]}")
json=$(mock_json "tool_name=Read" "session_id=pd-checkpoint")
result=$(run_post_dispatch "$json")
assert_contains "checkpoint_fires_at_25_message" "$result" "Mid-session checkpoint"
assert_contains "checkpoint_fires_at_25_count" "$result" "25 tool uses since last journal entry"
after=$(count_events tool_call '' '' "$LOG")
assert_eq "checkpoint_fire_still_appends_tool_call" "25" "$after"

# Test 7: Checkpoint does not fire before the 25th use (modulo boundary)
setup_test
seed=()
for i in $(seq 1 10); do
  seed+=("$((1700000000 + i))|tool_call|Read")
done
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pd-no-checkpoint" "${seed[@]}")
json=$(mock_json "tool_name=Grep" "session_id=pd-no-checkpoint")
result=$(run_post_dispatch "$json")
assert_eq "checkpoint_does_not_fire_before_25" "{}" "$result"

# Test 8: Missing event log (session_id present, no log file on disk) still
# routes to sub-handlers — routing is the dispatcher's job regardless of state.
# Proven via pattern-template.sh (state-io based, unaffected by the missing
# event log) firing its exemplar systemMessage for a Write.
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/exemplars"
echo "export const Foo = 1;" > "$_TEST_TMPDIR/.claude/exemplars/component.ts"
json=$(mock_json "tool_name=Write" "session_id=pd-noeventlog" "tool_input.file_path=${_TEST_TMPDIR}/src/new-file.ts")
result=$(run_post_dispatch "$json")
assert_contains "missing_event_log_still_routes_to_handlers" "$result" "convention reference"

# Test 9: No session_id at all (EVENT_LOG resolves empty, not just missing-file)
# still routes cleanly without crashing.
setup_test
json=$(mock_json "tool_name=Bash" "tool_input.command=echo hi")
result=$(run_post_dispatch "$json")
assert_eq "no_session_id_routes_and_returns_empty" "{}" "$result"

export PATH="$SAVED_PATH"
end_suite
