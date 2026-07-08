#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "session-end-dispatch"

# Compute today once at suite level
TODAY=$(date +%Y-%m-%d)

# Helper: create journal file manually
make_journal() {
  local dir="$1"
  local content="${2:-# Journal - $TODAY}"
  mkdir -p "$dir/memory"
  echo "$content" > "$dir/memory/${TODAY}.md"
}

# Helper: run session-end-dispatch directly (no sandbox needed — event-io
# resolves the project dir lazily via CORTEX_PROJECT_DIR_OVERRIDE, unlike
# state-io's source-time PROJECT_DIR assignment).
run_session_end() {
  local sid="$1"
  local project_dir="${2:-$_TEST_TMPDIR}"
  echo "{\"session_id\":\"${sid}\"}" | CORTEX_PROJECT_DIR_OVERRIDE="$project_dir" \
    bash "$PLUGIN_ROOT/hooks/scripts/session-end-dispatch.sh" 2>/dev/null || true
}

# Helper: count data rows in a health file (excludes header/comment lines)
count_health_rows() {
  local health_file="$1"
  local data_rows=0
  if [ -f "$health_file" ]; then
    data_rows=$(grep -c '|' "$health_file" | tr -d ' ')
    header_pipes=$(grep -c '^# Fields:' "$health_file" || true)
    data_rows=$((data_rows - header_pipes))
  fi
  echo "$data_rows"
}

# --- Test 1: Creates health file with header ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-health" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-health" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_file_exists "creates_health_file" "$health_file"
assert_file_contains "health_has_header" "$health_file" "# Cortex Health Log"

# --- Test 2: Appends data row with today's date ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-row" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-row" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_file_contains "row_has_today_date" "$health_file" "$TODAY"

# --- Test 3: Dedup by per-session flag (same session fires twice) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-dedup" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-dedup" > /dev/null
run_session_end "se-dedup" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "dedup_per_session_one_row" "1" "$(count_health_rows "$health_file")"

# --- Test 4: Dedup by date — a DIFFERENT session on the same day is blocked
# by the global health-file date check, even though its own log has no
# health_written event yet (Bug 2 fix, preserved). ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-dedupA" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
LOG_B=$(create_event_log "$_TEST_TMPDIR/.claude" "se-dedupB" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts")
make_journal "$_TEST_TMPDIR"
run_session_end "se-dedupA" > /dev/null
run_session_end "se-dedupB" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "dedup_by_date_blocks_different_session" "1" "$(count_health_rows "$health_file")"
hw_b=$(count_events health_written '' '' "$LOG_B")
assert_eq "dedup_by_date_still_flags_blocked_session" "1" "$hw_b"

# --- Test 5: Counts reasoning_misses from journal ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-miss" > /dev/null
mkdir -p "$_TEST_TMPDIR/memory"
cat > "$_TEST_TMPDIR/memory/${TODAY}.md" << 'JEOF'
# Journal
## 10:00 - task
- Did something [reasoning-miss]
## 11:00 - another
- Another thing [reasoning-miss]
- Third one [reasoning-miss]
JEOF
run_session_end "se-miss" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
if [ -f "$health_file" ]; then
  data_line=$(grep "^${TODAY}" "$health_file" | head -1)
  reasoning_misses=$(echo "$data_line" | cut -d'|' -f2)
else
  reasoning_misses="0"
fi
assert_eq "counts_reasoning_misses" "3" "$reasoning_misses"

# --- Test 6: Computes edits_per_commit (4 files, 2 commits = 2.0) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-epc" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" \
  "1700000003|file_edit|r ${_TEST_TMPDIR}/src/lib/c.ts" \
  "1700000004|file_edit|r ${_TEST_TMPDIR}/src/lib/d.ts" \
  "1700000005|commit|abc1234 feat: one" \
  "1700000006|commit|def5678 feat: two" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-epc" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
if [ -f "$health_file" ]; then
  data_line=$(grep "^${TODAY}" "$health_file" | head -1)
  epc=$(echo "$data_line" | cut -d'|' -f3)
else
  epc="0"
fi
assert_eq "edits_per_commit_computed" "2.0" "$epc"

# --- Test 7: No event log → returns {} ---
setup_test
result=$(run_session_end "nonexistent")
assert_eq "no_event_log_empty" "{}" "$result"

# --- Test 8: Appends health_written event to the session's own log ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-flag" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts")
make_journal "$_TEST_TMPDIR"
run_session_end "se-flag" > /dev/null
hw=$(last_event health_written "$LOG")
assert_eq "sets_health_written_event" "$TODAY" "$hw"

# --- Test 9: Creates cross-session file ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-cross" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/utils.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-cross" > /dev/null
cross_file="$_TEST_TMPDIR/.claude/cortex/cross-session.local.md"
assert_file_exists "creates_cross_session_file" "$cross_file"

# --- Test 10: Topology = "focused" + domain_tag = project basename for 2
# unique files (each edited once) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-topo" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-topo" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
if [ -f "$health_file" ]; then
  data_line=$(grep "^${TODAY}" "$health_file" | head -1)
  topology=$(echo "$data_line" | cut -d'|' -f11)
  domain_tag=$(echo "$data_line" | cut -d'|' -f12)
else
  topology="unknown"
  domain_tag="unknown"
fi
assert_eq "topology_focused" "focused" "$topology"
assert_eq "domain_tag_basename" "$(basename "$_TEST_TMPDIR")" "$domain_tag"

# --- Test 11: Idle session (zero activity, empty journal) → topology=idle,
# domain_tag=idle ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-idle" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-idle" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
if [ -f "$health_file" ]; then
  data_line=$(grep "^${TODAY}" "$health_file" | head -1)
  topology=$(echo "$data_line" | cut -d'|' -f11)
  domain_tag=$(echo "$data_line" | cut -d'|' -f12)
else
  topology="unknown"
  domain_tag="unknown"
fi
assert_eq "topology_idle" "idle" "$topology"
assert_eq "domain_tag_idle" "idle" "$domain_tag"

# --- Test 12: High-churn topology (6+ re-edits of the same file) ---
setup_test
seed=()
for i in $(seq 1 6); do
  seed+=("$((1700000000 + i))|file_edit|r ${_TEST_TMPDIR}/src/lib/hot.ts")
done
create_event_log "$_TEST_TMPDIR/.claude" "se-churn" "${seed[@]}" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-churn" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
data_line=$(grep "^${TODAY}" "$health_file" | head -1)
topology=$(echo "$data_line" | cut -d'|' -f11)
assert_eq "topology_high_churn" "high-churn" "$topology"

# --- Test 13: Rolling averages + trend detection (6+ data rows required) ---
# Seed 5 prior (non-idle) rows with reasoning_misses=0, then let the script
# append a 6th row for today with reasoning_misses=3 (via journal tags).
# recent_3 = avg(rows 4,5,6) = (0+0+3)/3 = 1.0; prior = avg(rows 1,2,3) = 0.0;
# diff = 1.0 > 0.5 => "degrading". avg_reasoning_misses over all 6 = 3/6 = 0.5.
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-trend" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
create_health_file "$health_file" \
  "2026-06-01|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-06-02|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-06-03|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-06-04|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-06-05|0|1.0|true|0|0|0|0|10|1|focused|proj"
mkdir -p "$_TEST_TMPDIR/memory"
cat > "$_TEST_TMPDIR/memory/${TODAY}.md" << 'JEOF'
# Journal
- Did something [reasoning-miss]
- Another thing [reasoning-miss]
- Third one [reasoning-miss]
JEOF
run_session_end "se-trend" > /dev/null
trend=$(grep '^trend_direction=' "$health_file" | cut -d= -f2 | tr -d '\r')
avg_rm=$(grep '^avg_reasoning_misses=' "$health_file" | cut -d= -f2 | tr -d '\r')
assert_eq "rolling_trend_degrading" "degrading" "$trend"
assert_eq "rolling_avg_reasoning_misses" "0.5" "$avg_rm"

# --- Test 14: lessons_created counted via real git diff (needs a real repo —
# git status/diff genuinely runs against PROJECT_DIR) ---
setup_test
GITDIR="$_TEST_TMPDIR/git-proj"
rm -rf "$GITDIR"
mkdir -p "$GITDIR/tasks"
git -C "$GITDIR" init -q
git -C "$GITDIR" config user.email "test@test.local"
git -C "$GITDIR" config user.name "Cortex Test"
echo "# Lessons" > "$GITDIR/tasks/lessons.md"
git -C "$GITDIR" add -A
git -C "$GITDIR" commit -q -m "chore: baseline"
mkdir -p "$GITDIR/memory"
echo "# Journal" > "$GITDIR/memory/${TODAY}.md"
cat >> "$GITDIR/tasks/lessons.md" << 'EOF'
## New lesson
- pattern one
- pattern two
EOF
create_event_log "$GITDIR/.claude" "se-lessons" > /dev/null
run_session_end "se-lessons" "$GITDIR" > /dev/null
health_file="$GITDIR/.claude/cortex/health.local.md"
data_line=$(grep "^${TODAY}" "$health_file" | head -1)
lessons_created=$(echo "$data_line" | cut -d'|' -f6)
assert_eq "lessons_created_counted_via_git_diff" "3" "$lessons_created"

# --- Test 15: proposals_need_archiving is NOT in the closed v4 event
# vocabulary (spec §3.3) — even with >50 proposal ids, the v3 write-only-dead
# flag must not be emitted as an event. Guards against reintroduction. ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-noarch" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts")
make_journal "$_TEST_TMPDIR"
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
proposals_file="$_TEST_TMPDIR/.claude/cortex/proposals.local.md"
> "$proposals_file"
for i in $(seq 1 51); do
  printf 'id=20260101-p%s\nstatus=pending\n---\n' "$i" >> "$proposals_file"
done
run_session_end "se-noarch" > /dev/null
arch_events=$(count_events proposals_need_archiving '' '' "$LOG")
assert_eq "no_proposals_need_archiving_event" "0" "$arch_events"

end_suite
