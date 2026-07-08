#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "pre-compact"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell — event-io.sh
# resolves the project dir from this env var at call time, so it must be set
# here explicitly (pattern: tests/integration/test-post-dispatch.sh:22).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run pre-compact with given session id (no transcript_path)
run_pre_compact() {
  local sid="$1"
  echo "{\"session_id\":\"${sid}\"}" | bash "$SANDBOX/hooks/scripts/pre-compact.sh" 2>/dev/null || true
}

# Helper: run pre-compact with a transcript_path for the tag-scan path
run_pre_compact_with_transcript() {
  local sid="$1" transcript="$2"
  json=$(mock_json "session_id=$sid" "transcript_path=$transcript")
  echo "$json" | bash "$SANDBOX/hooks/scripts/pre-compact.sh" 2>/dev/null || true
}

# Test 1: Preserves carry-over already in the event log
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-carry" \
  "1700000001|carry_over|Fix broken pipeline" > /dev/null
result=$(run_pre_compact "compact-carry")
assert_contains "preserves_carry_over" "$result" "Fix broken pipeline"

# Test 2: Preserves files-modified list (dedup, flag stripped)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-files" \
  "1700000001|file_edit|r src/lib/scoring.ts" \
  "1700000002|file_edit|r src/lib/utils.ts" \
  "1700000003|file_edit|r src/lib/scoring.ts" > /dev/null
result=$(run_pre_compact "compact-files")
assert_contains "preserves_files_modified" "$result" "src/lib/scoring.ts"
assert_contains "preserves_files_modified_dedup_count" "$result" "2 unique"

# Test 3: Preserves session stats
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-stats" \
  "1700000001|commit|abc1234 feat: a" \
  "1700000002|commit|abc5678 feat: b" \
  "1700000003|commit|abc9012 feat: c" \
  "1700000004|file_edit|r src/a.ts" \
  "1700000005|file_edit|r src/b.ts" \
  "1700000006|test_run|vitest" \
  "1700000007|docs_edit|documentation.md" > /dev/null
result=$(run_pre_compact "compact-stats")
assert_contains "preserves_session_stats" "$result" "3 commits"
assert_contains "preserves_session_stats_tests_run" "$result" "tests_run=true"
assert_contains "preserves_session_stats_docs_updated" "$result" "docs_updated=true"

# Test 4: Warns on uncommitted edits (edits since last commit anchor)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-warn-edits" \
  "1700000001|file_edit|r src/a.ts" \
  "1700000002|file_edit|r src/b.ts" \
  "1700000003|file_edit|r src/c.ts" \
  "1700000004|file_edit|r src/d.ts" \
  "1700000005|file_edit|r src/e.ts" > /dev/null
result=$(run_pre_compact "compact-warn-edits")
assert_contains "warns_uncommitted_edits" "$result" "uncommitted edits"

# Test 5: Warns on carry-over items (v3-equivalent: always warns when items
# exist — "addressed" tracking isn't derivable this wave, see script comment)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-warn-carry" \
  "1700000001|carry_over|Unfinished item" > /dev/null
result=$(run_pre_compact "compact-warn-carry")
assert_contains "warns_unaddressed_carry_over" "$result" "Carry-over"

# Test 6: Handles missing event log gracefully (returns {})
setup_test
result=$(echo '{"session_id":"nonexistent-compact"}' | bash "$SANDBOX/hooks/scripts/pre-compact.sh" 2>/dev/null || true)
assert_eq "handles_missing_event_log" "{}" "$result"

# Test 7: Transcript scan appends [carry-over]-tagged lines as carry_over
# events, which then appear in the preserved output (I3 fix — read-after-write)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-transcript")
transcript="$_TEST_TMPDIR/transcript.jsonl"
printf '%s\n' '{"text":"some message"}' '{"text":"[carry-over] Finish the migration"}' > "$transcript"
result=$(run_pre_compact_with_transcript "compact-transcript" "$transcript")
assert_contains "transcript_scan_carry_over_tag" "$result" "Finish the migration"
appended=$(count_events carry_over '' '' "$LOG")
assert_eq "transcript_scan_appends_carry_over_event" "1" "$appended"

# Test 8: Transcript scan also picks up [mid-session pin]-tagged lines
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-pin")
transcript="$_TEST_TMPDIR/transcript-pin.jsonl"
printf '%s\n' '{"text":"[mid-session pin] Remember the auth bug"}' > "$transcript"
result=$(run_pre_compact_with_transcript "compact-pin" "$transcript")
assert_contains "transcript_scan_mid_session_pin_tag" "$result" "Remember the auth bug"

end_suite
