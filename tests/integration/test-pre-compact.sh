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
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/scoring.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/utils.ts" \
  "1700000003|file_edit|r ${_TEST_TMPDIR}/src/lib/scoring.ts" > /dev/null
result=$(run_pre_compact "compact-files")
assert_contains "preserves_files_modified" "$result" "src/lib/scoring.ts"
assert_contains "preserves_files_modified_dedup_count" "$result" "2 unique"

# Test 3: Preserves session stats
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-stats" \
  "1700000001|commit|abc1234 feat: a" \
  "1700000002|commit|abc5678 feat: b" \
  "1700000003|commit|abc9012 feat: c" \
  "1700000004|file_edit|r ${_TEST_TMPDIR}/src/a.ts" \
  "1700000005|file_edit|r ${_TEST_TMPDIR}/src/b.ts" \
  "1700000006|test_run|vitest" \
  "1700000007|docs_edit|documentation.md" > /dev/null
result=$(run_pre_compact "compact-stats")
assert_contains "preserves_session_stats" "$result" "3 commits"
assert_contains "preserves_session_stats_tests_run" "$result" "tests_run=true"
assert_contains "preserves_session_stats_docs_updated" "$result" "docs_updated=true"

# Test 4: Warns on uncommitted edits (edits since last commit anchor)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-warn-edits" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/a.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/b.ts" \
  "1700000003|file_edit|r ${_TEST_TMPDIR}/src/c.ts" \
  "1700000004|file_edit|r ${_TEST_TMPDIR}/src/d.ts" \
  "1700000005|file_edit|r ${_TEST_TMPDIR}/src/e.ts" > /dev/null
result=$(run_pre_compact "compact-warn-edits")
assert_contains "warns_uncommitted_edits" "$result" "uncommitted edits"

# Test 5: Warns on carry-over items with no matching carry_addressed hash
# ("addressed" shares stop-gate.sh Gate 4's semantics: an item counts as
# addressed once its eio_item_hash appears among carry_addressed events)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "compact-warn-carry" \
  "1700000001|carry_over|Unfinished item" > /dev/null
result=$(run_pre_compact "compact-warn-carry")
assert_contains "warns_unaddressed_carry_over" "$result" "Carry-over"

# Test 5b: Carry-over item whose eio_item_hash appears among carry_addressed
# events is treated as addressed (same mechanism as stop-gate.sh Gate 4):
# no warning, and the item is omitted from the summary entirely.
setup_test
item_text="Fully resolved item"
item_hash=$(eio_item_hash "$item_text")
create_event_log "$_TEST_TMPDIR/.claude" "compact-addressed" \
  "1700000001|carry_over|${item_text}" \
  "1700000002|carry_addressed|${item_hash}" > /dev/null
result=$(run_pre_compact "compact-addressed")
assert_not_contains "addressed_item_no_warning" "$result" "not yet addressed"
assert_not_contains "addressed_item_absent_from_summary" "$result" "Fully resolved item"

# Test 5c: Two carry-over items, one addressed by hash — warning still fires
# and only the unaddressed item is listed in the summary.
setup_test
done_text="Resolved item"
done_hash=$(eio_item_hash "$done_text")
create_event_log "$_TEST_TMPDIR/.claude" "compact-partial" \
  "1700000001|carry_over|${done_text}" \
  "1700000002|carry_over|Still open item" \
  "1700000003|carry_addressed|${done_hash}" > /dev/null
result=$(run_pre_compact "compact-partial")
assert_contains "partial_addressed_warns" "$result" "not yet addressed"
assert_contains "partial_addressed_lists_unaddressed" "$result" "Still open item"
assert_not_contains "partial_addressed_omits_addressed" "$result" "Resolved item"

# Test 6: Handles missing event log gracefully (returns {})
setup_test
result=$(echo '{"session_id":"nonexistent-compact"}' | bash "$SANDBOX/hooks/scripts/pre-compact.sh" 2>/dev/null || true)
assert_eq "handles_missing_event_log" "{}" "$result"

# Transcript fixtures below use the real Claude Code JSONL shapes: one entry per line, one
# content block per message line, compact JSON, and "\n" escapes inside strings. The earlier
# fixtures ({"text":"[carry-over] ..."}) matched no real line shape, so the scan's capture of
# hook text and tool output (2026-09-27: every compacted session re-minted the session-start
# boilerplate as a carry-over item) was never exercised.

# Test 7: Transcript scan appends a [carry-over] item declared in a user message as a
# carry_over event, which then appears in the preserved output (I3 fix: read-after-write)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-transcript")
transcript="$_TEST_TMPDIR/transcript.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"some message"}}' \
  '{"type":"user","message":{"role":"user","content":"[carry-over] Finish the migration"}}' \
  > "$transcript"
result=$(run_pre_compact_with_transcript "compact-transcript" "$transcript")
assert_contains "transcript_scan_carry_over_tag" "$result" "Finish the migration"
appended=$(count_events carry_over '' '' "$LOG")
assert_eq "transcript_scan_appends_carry_over_event" "1" "$appended"

# Test 8: Transcript scan also picks up a [mid-session pin] that starts a line of assistant text
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-pin")
transcript="$_TEST_TMPDIR/transcript-pin.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Noted.\n[mid-session pin] Remember the auth bug"}]}}' \
  > "$transcript"
result=$(run_pre_compact_with_transcript "compact-pin" "$transcript")
assert_contains "transcript_scan_mid_session_pin_tag" "$result" "Remember the auth bug"

# Test 9: A tag that is not a declaration is never recorded: hook output (the session-start
# boilerplate itself names the tag), tool results (journals read back), tool inputs (a journal
# write for the NEXT session), thinking, and a mid-sentence mention in message text
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-noise")
transcript="$_TEST_TMPDIR/transcript-noise.jsonl"
printf '%s\n' \
  '{"type":"attachment","attachment":{"type":"hook_success","content":"5. Housekeeping: archive previous-month journals with no open [carry-over]; clean .claude/cortex .tmp files."}}' \
  '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"# Journal\n- [carry-over] Stale item read back from an old journal"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat >> memory/j.md <<EOF\n- [carry-over] Deferred to the next session\nEOF"}}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"[carry-over] a thought, not a declaration"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The hook text mentions [carry-over] mid-sentence."}]}}' \
  > "$transcript"
result=$(run_pre_compact_with_transcript "compact-noise" "$transcript")
appended=$(count_events carry_over '' '' "$LOG")
assert_eq "transcript_scan_ignores_non_declarations" "0" "$appended"
assert_not_contains "transcript_scan_ignores_tool_results" "$result" "Stale item"
assert_not_contains "transcript_scan_ignores_hook_text" "$result" "clean .claude/cortex"

# Test 10: An item is its own logical line: capture stops at the line's end (never the rest of
# the JSONL line), the list marker is dropped, and escaped quotes come back as quotes
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-line")
transcript="$_TEST_TMPDIR/transcript-line.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Plan:\n- [carry-over] Ask Will about \"D-5\"\nThis line is not part of the item."}]}}' \
  > "$transcript"
run_pre_compact_with_transcript "compact-line" "$transcript" > /dev/null
value=$(grep '|carry_over|' "$LOG" | cut -d'|' -f3-)
assert_eq "transcript_scan_captures_one_logical_line" '[carry-over] Ask Will about "D-5"' "$value"

# Test 11: The same declaration made twice is recorded once
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "compact-dupe")
transcript="$_TEST_TMPDIR/transcript-dupe.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"[carry-over] Push the code repo"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Recorded:\n- [carry-over] Push the code repo"}]}}' \
  > "$transcript"
run_pre_compact_with_transcript "compact-dupe" "$transcript" > /dev/null
appended=$(count_events carry_over '' '' "$LOG")
assert_eq "transcript_scan_dedupes_declarations" "1" "$appended"

end_suite
