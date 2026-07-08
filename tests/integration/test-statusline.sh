#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "statusline"

# Helper: run statusline.sh directly (no sandbox needed — event-io resolves
# the project dir lazily via CORTEX_PROJECT_DIR_OVERRIDE). statusline.sh
# takes hook JSON as $1, not stdin — < /dev/null keeps it from blocking on
# an inherited stdin it never reads.
run_statusline() {
  local json_arg="${1:-}"
  local project_dir="${2:-$_TEST_TMPDIR}"
  CORTEX_PROJECT_DIR_OVERRIDE="$project_dir" \
    bash "$PLUGIN_ROOT/hooks/scripts/statusline.sh" "$json_arg" < /dev/null
}

# --- Test 1: edits (since last commit) and commits counts ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-counts" \
  "1700000001|commit|abc1234 feat: x" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000003|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" > /dev/null
result=$(run_statusline "{\"session_id\":\"sl-counts\"}")
line1=$(echo "$result" | head -1)
assert_contains "edits_count_since_last_commit" "$line1" "2 edits"
assert_contains "commits_count" "$line1" "1 commits"

# --- Test 2: tests/docs icons default to X when no events present ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-noicons" > /dev/null
result=$(run_statusline "{\"session_id\":\"sl-noicons\"}")
line1=$(echo "$result" | head -1)
assert_contains "tests_icon_default_x" "$line1" "🧪❌"
assert_contains "docs_icon_default_x" "$line1" "📄❌"

# --- Test 3: tests/docs icons show checkmark when events present ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-icons" \
  "1700000001|test_run|vitest" \
  "1700000002|docs_edit|documentation.md" > /dev/null
result=$(run_statusline "{\"session_id\":\"sl-icons\"}")
line1=$(echo "$result" | head -1)
assert_contains "tests_icon_check" "$line1" "🧪✅"
assert_contains "docs_icon_check" "$line1" "📄✅"

# --- Test 4: mode_set cautious shows orange heart + cautious status.
# Closes the known transient where degrading-trend previously overrode
# cautious mode; mode is read directly from the event log now. ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-cautious" \
  "1700000001|mode_set|cautious trend" > /dev/null
result=$(run_statusline "{\"session_id\":\"sl-cautious\"}")
line2=$(echo "$result" | tail -1)
assert_contains "cautious_mode_orange_heart" "$line2" "🧡 cautious"

# --- Test 5: trend arrow + lessons/proposals counts read from health file,
# lessons.md, and proposals file (unchanged read paths) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-trend" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
create_health_file "$health_file" "2026-07-01|0|1.0|true|0|0|0|0|10|1|focused|proj"
sed -i 's/^trend_direction=.*/trend_direction=improving/' "$health_file"
mkdir -p "$_TEST_TMPDIR/tasks"
printf '## Lesson one\nbody\n## Lesson two\nbody\n' > "$_TEST_TMPDIR/tasks/lessons.md"
proposals_file="$_TEST_TMPDIR/.claude/cortex/proposals.local.md"
create_proposals_file "$proposals_file" "20260101-a|pending|type|target|summary|body"
result=$(run_statusline "{\"session_id\":\"sl-trend\"}")
line2=$(echo "$result" | tail -1)
assert_contains "trend_arrow_improving" "$line2" "↗ improving"
assert_contains "lessons_absorbed_count" "$line2" "2 absorbed"
assert_contains "mutations_queued_count" "$line2" "1 mutations queued"
assert_contains "improving_trend_thriving_heart" "$line2" "💚 thriving"

# --- Test 6: no event log, no health file — graceful defaults (stable
# trend, thriving heart from zero avg_misses default, zero counts). Opted-in
# project (sentinel stamped directly — no create_event_log call, since this
# test is specifically about the absence of a log/health file). ---
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
touch "$_TEST_TMPDIR/.claude/cortex/enabled"
result=$(run_statusline "{\"session_id\":\"sl-missing\"}")
line1=$(echo "$result" | head -1)
line2=$(echo "$result" | tail -1)
assert_contains "no_log_zero_edits" "$line1" "0 edits"
assert_contains "no_log_zero_commits" "$line1" "0 commits"
assert_contains "no_log_default_thriving" "$line2" "💚 thriving"
assert_contains "no_log_default_stable_trend" "$line2" "→ stable"

# --- Test 7: readonly resolver falls back to current-session.id marker when
# the hook JSON arg has no session_id (statusline polled without full context) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-marker" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" \
  "1700000003|file_edit|r ${_TEST_TMPDIR}/src/lib/c.ts" > /dev/null
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
echo "sl-marker" > "$_TEST_TMPDIR/.claude/cortex/current-session.id"
result=$(run_statusline "")
line1=$(echo "$result" | head -1)
assert_contains "readonly_fallback_to_marker" "$line1" "3 edits"

end_suite
