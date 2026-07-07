#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "post-edit-dispatch"

# Helper: run post-edit-dispatch directly (no sandbox needed — event-io resolves
# the project dir lazily via CORTEX_PROJECT_DIR_OVERRIDE, unlike state-io's
# source-time PROJECT_DIR assignment).
run_post_edit() {
  local sid="$1" file_path="$2"
  local json
  json=$(mock_json "session_id=$sid" "tool_input.file_path=$file_path")
  echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/scripts/post-edit-dispatch.sh" 2>/dev/null || true
}

# Test 1: Edit increments the derived edits-since-last-commit count
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "edit-inc" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/prior1.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/prior2.ts")
run_post_edit "edit-inc" "${_TEST_TMPDIR}/src/lib/utils.ts" > /dev/null
result=$(count_events file_edit r "" "$LOG")
assert_eq "edit_increments_count" "3" "$result"

# Test 2: File path appended as a file_edit event
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "edit-track")
run_post_edit "edit-track" "src/lib/scoring.ts" > /dev/null
result=$(list_events file_edit "$LOG")
assert_contains "file_path_tracked" "$result" "src/lib/scoring.ts"

# Test 3: Same file edited 3 times triggers re-edit warning
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "re-edit" \
  "1700000001|file_edit|r src/lib/problem.ts" \
  "1700000002|file_edit|r src/lib/problem.ts")
# This will be the 3rd edit (count after append = 3)
result=$(run_post_edit "re-edit" "src/lib/problem.ts")
assert_contains "re_edit_warning_at_three" "$result" "Re-edit"

# Test 4: Plugin paths (.claude-plugin/) skip re-edit check
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "plugin-skip" \
  "1700000001|file_edit|x .claude-plugin/hooks/test.sh" \
  "1700000002|file_edit|x .claude-plugin/hooks/test.sh")
result=$(run_post_edit "plugin-skip" ".claude-plugin/hooks/test.sh")
assert_not_contains "plugin_path_skips_re_edit" "$result" "Re-edit"

# Test 5: Editing documentation.md appends a docs_edit event
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-edit")
run_post_edit "docs-edit" "documentation.md" > /dev/null
result=$(list_events docs_edit "$LOG")
assert_contains "docs_edit_sets_flag" "$result" "documentation.md"

# Test 6: Editing a memory/*.md journal file appends a journal_edit event
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "journal-edit")
run_post_edit "journal-edit" "memory/2026-07-06.md" > /dev/null
result=$(list_events journal_edit "$LOG")
assert_contains "journal_edit_tracked" "$result" "memory/2026-07-06.md"

# Test 7: Editing lessons.md appends root_cause_logged=true
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "lessons-edit")
run_post_edit "lessons-edit" "tasks/lessons.md" > /dev/null
result=$(last_event root_cause_logged "$LOG")
assert_eq "lessons_edit_logs_root_cause" "true" "$result"

# Test 8: Over 15 edits triggers commit nudge
setup_test
seed=()
for i in $(seq 1 16); do
  seed+=("$((1700000000 + i))|file_edit|r ${_TEST_TMPDIR}/src/lib/prior${i}.ts")
done
seed+=("1700000099|threshold_set|15")
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "nudge-test" "${seed[@]}")
result=$(run_post_edit "nudge-test" "${_TEST_TMPDIR}/src/lib/foo.ts")
assert_contains "commit_nudge_over_threshold" "$result" "commit"

# Test 9: Custom threshold (5) with 6 edits triggers nudge
setup_test
seed=()
for i in $(seq 1 5); do
  seed+=("$((1700000100 + i))|file_edit|r ${_TEST_TMPDIR}/src/lib/custom${i}.ts")
done
seed+=("1700000199|threshold_set|5")
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "custom-thresh" "${seed[@]}")
result=$(run_post_edit "custom-thresh" "${_TEST_TMPDIR}/src/lib/bar.ts")
assert_contains "custom_threshold_nudge" "$result" "commit"

# Test 10: Editing scoring file without a prior docs_edit triggers reminder
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "arch-remind")
result=$(run_post_edit "arch-remind" "src/lib/scoring/v11.ts")
assert_contains "scoring_file_doc_reminder" "$result" "documentation.md"

# Test 11: Normal edit under threshold, docs already synced, returns {}
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "normal-edit" \
  "1700000001|docs_edit|documentation.md" \
  "1700000002|threshold_set|15")
result=$(run_post_edit "normal-edit" "src/lib/simple.ts")
assert_eq "normal_edit_empty_response" "{}" "$result"

end_suite
