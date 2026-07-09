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
problem_file="${_TEST_TMPDIR}/src/lib/problem.ts"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "re-edit")
seed_file_edit "$LOG" "r" "$problem_file"
seed_file_edit "$LOG" "r" "$problem_file"
# This will be the 3rd edit (count after append = 3)
result=$(run_post_edit "re-edit" "$problem_file")
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

# Test 5b: docs_edit detection honors a custom docs_file config value —
# editing the configured file fires; editing the OLD default no longer does
# (spec §7.1 — docs_file is per-project, no longer hardcoded)
setup_test
set_config "$_TEST_TMPDIR/.claude" "docs_file" "ARCHITECTURE.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-edit-custom")
run_post_edit "docs-edit-custom" "src/ARCHITECTURE.md" > /dev/null
result=$(list_events docs_edit "$LOG")
assert_contains "docs_edit_custom_file_fires" "$result" "ARCHITECTURE.md"

setup_test
set_config "$_TEST_TMPDIR/.claude" "docs_file" "ARCHITECTURE.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-edit-custom-old-default")
run_post_edit "docs-edit-custom-old-default" "documentation.md" > /dev/null
result=$(list_events docs_edit "$LOG")
assert_eq "docs_edit_old_default_silent_when_custom_configured" "" "$result"

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

# Test 7b: lessons detection honors a custom lessons_file config value —
# editing the configured basename fires (case-insensitively); editing the
# OLD default no longer does (spec §7.1 — lessons_file is per-project)
setup_test
set_config "$_TEST_TMPDIR/.claude" "lessons_file" "docs/CHANGELOG.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "lessons-edit-custom")
run_post_edit "lessons-edit-custom" "docs/CHANGELOG.md" > /dev/null
result=$(last_event root_cause_logged "$LOG")
assert_eq "lessons_edit_custom_file_fires" "true" "$result"

setup_test
set_config "$_TEST_TMPDIR/.claude" "lessons_file" "docs/CHANGELOG.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "lessons-edit-custom-case")
run_post_edit "lessons-edit-custom-case" "docs/CHANGELOG.MD" > /dev/null
result=$(last_event root_cause_logged "$LOG")
assert_eq "lessons_edit_custom_file_case_insensitive" "true" "$result"

setup_test
set_config "$_TEST_TMPDIR/.claude" "lessons_file" "docs/CHANGELOG.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "lessons-edit-custom-old-default")
run_post_edit "lessons-edit-custom-old-default" "tasks/lessons.md" > /dev/null
result=$(last_event root_cause_logged "$LOG")
assert_eq "lessons_edit_old_default_silent_when_custom_configured" "" "$result"

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

# Test 8b: exact nudge boundary — 15 edits since last commit (== threshold)
# stays SILENT. post-edit-dispatch.sh:70 uses `-gt`, not `-ge`, so the exact
# threshold value must never fire.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "boundary-15" "1700000299|threshold_set|15")
for i in $(seq 1 14); do
  seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/boundary15_${i}.ts"
done
result=$(run_post_edit "boundary-15" "${_TEST_TMPDIR}/src/lib/boundary15_15.ts")
assert_not_contains "nudge_silent_at_exactly_15_edits" "$result" "commit"

# Test 8c: exact nudge boundary — 16 edits since last commit (one OVER
# threshold) FIRES. The counterpart to Test 8b, pinning the exact `-gt` edge.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "boundary-16" "1700000399|threshold_set|15")
for i in $(seq 1 15); do
  seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/boundary16_${i}.ts"
done
result=$(run_post_edit "boundary-16" "${_TEST_TMPDIR}/src/lib/boundary16_16.ts")
assert_contains "nudge_fires_at_exactly_16_edits" "$result" "commit"

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

# Test 9b: commit_nudge_threshold config OVERRIDES the threshold_set event
# value (spec §7.1) — event says 15, config says 3; 4 edits (> 3) fires.
setup_test
set_config "$_TEST_TMPDIR/.claude" "commit_nudge_threshold" "3"
seed=()
for i in $(seq 1 3); do
  seed+=("$((1700000200 + i))|file_edit|r ${_TEST_TMPDIR}/src/lib/cfgthresh${i}.ts")
done
seed+=("1700000299|threshold_set|15")
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cfg-thresh-override" "${seed[@]}")
result=$(run_post_edit "cfg-thresh-override" "${_TEST_TMPDIR}/src/lib/cfgthresh4.ts")
assert_contains "config_threshold_overrides_event" "$result" "commit"

# Test 9c: non-numeric commit_nudge_threshold config is IGNORED — falls back
# to the threshold_set event value (15). 15 edits (== threshold) stays silent.
setup_test
set_config "$_TEST_TMPDIR/.claude" "commit_nudge_threshold" "not-a-number"
seed=()
for i in $(seq 1 14); do
  seed+=("$((1700000300 + i))|file_edit|r ${_TEST_TMPDIR}/src/lib/nonnum${i}.ts")
done
seed+=("1700000399|threshold_set|15")
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cfg-thresh-nonnumeric" "${seed[@]}")
result=$(run_post_edit "cfg-thresh-nonnumeric" "${_TEST_TMPDIR}/src/lib/nonnum15.ts")
assert_not_contains "non_numeric_config_threshold_ignored" "$result" "commit"

# Test 10a: doc-sync reminder is INACTIVE by default (no config.local) — spec
# §7.1: an unconfigured project never fires the reminder, even on a path that
# "looks" architectural under the old hardcoded pattern.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "arch-remind-unconfigured")
result=$(run_post_edit "arch-remind-unconfigured" "src/lib/scoring/v11.ts")
assert_not_contains "arch_reminder_inactive_without_config" "$result" "documentation.md"
assert_eq "arch_reminder_inactive_without_config_empty" "{}" "$result"

# Test 10: Editing scoring file without a prior docs_edit triggers reminder
# (architectural_patterns configured explicitly — spec §7.1)
setup_test
set_config "$_TEST_TMPDIR/.claude" "architectural_patterns" "scoring|pipeline|v10|v11"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "arch-remind")
result=$(run_post_edit "arch-remind" "src/lib/scoring/v11.ts")
assert_contains "scoring_file_doc_reminder" "$result" "documentation.md"

# Test 10b: doc-sync reminder text honors a custom docs_file config value
setup_test
set_config "$_TEST_TMPDIR/.claude" "architectural_patterns" "scoring"
set_config "$_TEST_TMPDIR/.claude" "docs_file" "ARCHITECTURE.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "arch-remind-custom")
result=$(run_post_edit "arch-remind-custom" "src/lib/scoring/v11.ts")
assert_contains "arch_reminder_custom_docs_file_text" "$result" "ARCHITECTURE.md"

# Test 11: Normal edit under threshold, docs already synced, returns {}
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "normal-edit" \
  "1700000001|docs_edit|documentation.md" \
  "1700000002|threshold_set|15")
result=$(run_post_edit "normal-edit" "src/lib/simple.ts")
assert_eq "normal_edit_empty_response" "{}" "$result"

end_suite
