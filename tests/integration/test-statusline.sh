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
# No intervention data anywhere → EXACTLY two lines (the 🔁 line is optional,
# spec §6.3: "a third line when data exists")
assert_eq "no_interventions_two_lines_only" "2" "$(echo "$result" | wc -l | tr -d ' ')"

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

# --- Test 5: trend arrow (>=10 non-idle v2 rows, improving verdict) +
# lessons/proposals counts read from health file, lessons.md, and proposals
# file (unchanged read paths). Improving requires BOTH mirror signals: a
# fix_ratio median that FELL by more than 0.15 (last-5 vs prior-5) and zero
# high-rework rows among the last 5 (spec §6.2). ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-trend" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
create_health_file "$health_file" \
  "v2|2026-06-01|old-sid-1|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-02|old-sid-2|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-03|old-sid-3|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-04|old-sid-4|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-05|old-sid-5|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-06|old-sid-6|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-07|old-sid-7|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-08|old-sid-8|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-09|old-sid-9|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-10|old-sid-10|2|5|0.00|0|0|pass|10|3|iterating|src|0"
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

# --- Test 5b: >=10 non-idle v2 rows with a degrading rework signal (>=3 of
# the last 5 rows have rework_files >= 3) shows the degrading arrow + a
# stressed heart. ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-degrading" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
create_health_file "$health_file" \
  "v2|2026-06-01|old-sid-1|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-02|old-sid-2|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-03|old-sid-3|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-04|old-sid-4|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-05|old-sid-5|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-06|old-sid-6|2|5|0.00|3|3|pass|10|3|iterating|src|0" \
  "v2|2026-06-07|old-sid-7|2|5|0.00|3|3|pass|10|3|iterating|src|0" \
  "v2|2026-06-08|old-sid-8|2|5|0.00|3|3|pass|10|3|iterating|src|0" \
  "v2|2026-06-09|old-sid-9|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-10|old-sid-10|2|5|0.00|0|0|pass|10|3|iterating|src|0"
result=$(run_statusline "{\"session_id\":\"sl-degrading\"}")
line2=$(echo "$result" | tail -1)
assert_contains "trend_arrow_degrading" "$line2" "↘ degrading"
assert_contains "degrading_trend_stressed_heart" "$line2" "stressed"

# --- Test 6: no event log, no health file — 0 total rows is below the
# trend-readiness threshold, so line 2 shows the raw-count line instead of
# an arrow, and the heart defaults to the neutral "adapting" state (v2:
# self-report avg_misses is gone, no more zero-misses-implies-thriving
# default). ---
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
touch "$_TEST_TMPDIR/.claude/cortex/enabled"
result=$(run_statusline "{\"session_id\":\"sl-missing\"}")
line1=$(echo "$result" | head -1)
line2=$(echo "$result" | tail -1)
assert_contains "no_log_zero_edits" "$line1" "0 edits"
assert_contains "no_log_zero_commits" "$line1" "0 commits"
assert_contains "no_log_default_adapting" "$line2" "💛 adapting"
assert_contains "no_log_eligible_count_below_threshold" "$line2" "📊 trend: 0/10 eligible sessions"

# --- Test 6b: SOME rows present (legacy + v2 + an idle v2) but still below
# the >=10 non-idle-v2 threshold — the segment shows the ELIGIBLE count (the
# number the predicate actually consumes), NOT the raw total (calibration
# wave, queue item 4: '9 tracked — trend at 10' displayed while the real
# state was 2/10 — the raw total answered a question nobody asked and misled
# the one that mattered). Legacy and idle rows are visible in the file but
# never eligible. ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-belowten" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
create_health_file "$health_file" \
  "2026-05-01|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-05-02|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "v2|2026-06-01|old-sid-1|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-02|old-sid-2|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-03|old-sid-3|0|0|null|0|0|none|5|0|focused|idle|0"
result=$(run_statusline "{\"session_id\":\"sl-belowten\"}")
line2=$(echo "$result" | tail -1)
assert_contains "below_threshold_shows_eligible_count" "$line2" "📊 trend: 2/10 eligible sessions"

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

# --- Test 8: intervention follow-through third line (spec §6.3, T5p2) ---
# One nudge followed by a commit (followed 1/1), one codex reminder never
# harvested (0/1). Labels are the statusline short forms; format is
# "<label> <followed>/<fired>"; kinds render in the report's sorted order.
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sl-interventions" \
  "1700000002|intervention|commit_nudge" \
  "1700000003|commit|abc1 fix: x" \
  "1700000004|intervention|codex_reminder" > /dev/null
result=$(run_statusline "{\"session_id\":\"sl-interventions\"}")
line3=$(echo "$result" | sed -n '3p')
assert_contains "interventions_line_present" "$line3" "🔁 interventions:"
assert_contains "interventions_nudge_followed_over_fired" "$line3" "nudge 1/1"
assert_contains "interventions_codex_not_followed" "$line3" "codex 0/1"

end_suite
