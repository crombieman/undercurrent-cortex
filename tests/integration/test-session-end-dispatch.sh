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

# Helper: build a v2 row's value for a given field (1-indexed).
v2_field() {
  local health_file="$1" n="$2"
  grep '^v2|' "$health_file" | head -1 | cut -d'|' -f"$n"
}

# --- Git sandbox helpers (rework_files / fix_ratio / reverts need REAL git
# history at controlled dates — a mocked git can't exercise --since/--until
# filtering). Mirrors tests/integration/test-post-bash-dispatch.sh's
# make_commit pattern. ---
make_git_project() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "Cortex Test"
}

# commit_at <dir> <epoch> <message> <file...> — writes/appends to each file
# then commits with author+committer date pinned to <epoch>.
commit_at() {
  local dir="$1" epoch="$2" message="$3"
  shift 3
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$dir/$f")"
    echo "content ${epoch} ${RANDOM}" >> "$dir/$f"
  done
  git -C "$dir" add -A
  GIT_AUTHOR_DATE="@${epoch}" GIT_COMMITTER_DATE="@${epoch}" \
    git -C "$dir" commit -q -m "$message"
}

# --- Test 1: Creates health file with v2 header ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-health" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-health" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_file_exists "creates_health_file" "$health_file"
assert_file_contains "health_has_header" "$health_file" "# Cortex Health Log"
assert_file_contains "health_header_has_v2_fields" "$health_file" "# Fields: v2|date|session_id"

# --- Test 2: Appends v2 data row with today's date ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-row" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-row" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_file_contains "row_has_v2_sentinel" "$health_file" "v2|${TODAY}|se-row|"

# --- Test 3: Dedup by per-session flag (same session fires twice) -> 1 row ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-dedup" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-dedup" > /dev/null
run_session_end "se-dedup" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "dedup_per_session_one_row" "1" "$(count_health_rows "$health_file")"

# --- Test 4: Per-SID dedup replaces date-wide dedup — TWO DIFFERENT sessions
# on the SAME calendar date each get their OWN row (v2 §6.1: dedup keys off
# session_id, not date). This is the opposite of the old v3 contract. ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-dedupA" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
create_event_log "$_TEST_TMPDIR/.claude" "se-dedupB" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-dedupA" > /dev/null
run_session_end "se-dedupB" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "two_sids_same_date_two_rows" "2" "$(count_health_rows "$health_file")"
assert_file_contains "row_a_present" "$health_file" "|se-dedupA|"
assert_file_contains "row_b_present" "$health_file" "|se-dedupB|"

# --- Test 5: self_misses (field 14) counted from journal [reasoning-miss] tags
# (an r-edit is seeded so the session is non-idle and actually writes a row) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-miss" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
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
assert_eq "counts_self_misses" "3" "$(v2_field "$health_file" 14)"

# --- Test 6: No event log → returns {} ---
setup_test
result=$(run_session_end "nonexistent")
assert_eq "no_event_log_empty" "{}" "$result"

# --- Test 7: Appends health_written event to the session's own log ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-flag" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts")
make_journal "$_TEST_TMPDIR"
run_session_end "se-flag" > /dev/null
hw=$(last_event health_written "$LOG")
assert_eq "sets_health_written_event" "$TODAY" "$hw"

# --- Test 8: cross-session tracker RETIRED (wave 5, locked D6): session-end
# neither creates nor updates cross-session.local.md — hot files are derived
# at read from the logs themselves (eio_hot_files). A legacy file on disk is
# inert: byte-identical after the hook runs. ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-cross" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/utils.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-cross" > /dev/null
cross_file="$_TEST_TMPDIR/.claude/cortex/cross-session.local.md"
assert_eq "no_cross_session_file_created" "" "$(ls "$cross_file" 2>/dev/null || true)"

setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-cross-legacy" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/utils.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
cross_file="$_TEST_TMPDIR/.claude/cortex/cross-session.local.md"
printf '# Cross-Session File Edit Tracker\nC:/legacy/old.ts|9|2026-07-01\n' > "$cross_file"
before=$(cat "$cross_file")
run_session_end "se-cross-legacy" > /dev/null
assert_eq "legacy_cross_session_file_untouched" "$before" "$(cat "$cross_file")"

# --- Retry-safe health row (W5 review I-2): when the row cannot be written
# (HEALTH_FILE is a directory here — unwritable on every platform), the hook
# must still exit 0 with JSON AND must NOT record health_written, so the next
# SessionEnd retries instead of skipping the row forever. ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-ro-health" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts")
make_journal "$_TEST_TMPDIR"
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$health_file"
set +e
result=$(run_session_end "se-ro-health")
rc=$?
set -e
rmdir "$health_file" 2>/dev/null || true
assert_eq "unwritable_health_exit_0" "0" "$rc"
assert_contains "unwritable_health_valid_json" "$result" "{"
assert_eq "unwritable_health_no_health_written_event" "0" "$(count_events health_written '' '' "$LOG")"

# --- Test 9: topology="focused" for 2 unique r-edits (<3 => domain "mixed",
# not idle — activity present, just not enough to attribute a segment) ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-topo" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-topo" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "topology_focused" "focused" "$(v2_field "$health_file" 12)"
assert_eq "domain_under_3_redits_mixed" "mixed" "$(v2_field "$health_file" 13)"

# --- Test 10: Idle session (zero r-edits) writes NO row (calibration wave,
# queue item 5: idle/twin boots were 5 of 7 live v2 rows, polluting the
# trend denominator). health_written is still appended so the skill/
# dispatcher double-fire dedup keeps working; the file is left UNTOUCHED
# (an idle session performs zero health-file mutations). ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-idle")
make_journal "$_TEST_TMPDIR"
run_session_end "se-idle" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "idle_session_writes_no_row" "0" "$(count_health_rows "$health_file")"
assert_contains "idle_session_marks_health_written" \
  "$(list_events health_written "$LOG")" "idle-skipped"
run_session_end "se-idle" > /dev/null
assert_eq "idle_session_rerun_still_no_row" "0" "$(count_health_rows "$health_file")"

# --- Test 10b: idle skip leaves an EXISTING health file byte-identical —
# prior rows survive and no header/strip mutation happens. ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-idle2")
make_journal "$_TEST_TMPDIR"
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$(dirname "$health_file")"
cat > "$health_file" <<'HEOF'
# Cortex Health Log
# Fields: v2|date|session_id|commits|material_edits|fix_ratio|reverts|rework_files|tests_pass|duration_min|max_re_edits|topology|domain|self_misses
v2|2026-06-01|prior-sid|2|5|0.00|0|0|pass|10|3|iterating|src|0
HEOF
before=$(cat "$health_file")
run_session_end "se-idle2" > /dev/null
after=$(cat "$health_file")
assert_eq "idle_skip_leaves_health_file_untouched" "$before" "$after"

# --- Test 11: High-churn topology (6+ re-edits of the same file) ---
setup_test
seed=()
for i in $(seq 1 6); do
  seed+=("$((1700000000 + i))|file_edit|r ${_TEST_TMPDIR}/src/lib/hot.ts")
done
create_event_log "$_TEST_TMPDIR/.claude" "se-churn" "${seed[@]}" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-churn" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "topology_high_churn" "high-churn" "$(v2_field "$health_file" 12)"

# --- Test 12: v2 row shape, field-by-field (no git — has_git=false path) ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-v2shape" \
  "1700000090|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000091|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000092|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" \
  "1700000093|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" \
  "1700000094|file_edit|r ${_TEST_TMPDIR}/src/lib/b.ts" \
  "1700000100|commit|abc1234 fix: one" \
  "1700000101|commit|def5678 feat: two" \
  "1700000102|test_run|vitest")
make_journal "$_TEST_TMPDIR"
run_session_end "se-v2shape" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "v2_field1_sentinel" "v2" "$(v2_field "$health_file" 1)"
assert_eq "v2_field2_date" "$TODAY" "$(v2_field "$health_file" 2)"
assert_eq "v2_field3_session_id" "se-v2shape" "$(v2_field "$health_file" 3)"
# commits + fix_ratio are GIT-derived (same-provenance, queue item 3): with
# no git repo the count is unknowable — 0 commits + null ratio, never the
# event count (event commit events remain the Gate-1 anchor only).
assert_eq "v2_field4_commits_no_git_is_zero" "0" "$(v2_field "$health_file" 4)"
assert_eq "v2_field5_material_edits" "5" "$(v2_field "$health_file" 5)"
assert_eq "v2_field6_fix_ratio_no_git_is_null" "null" "$(v2_field "$health_file" 6)"
assert_eq "v2_field7_reverts" "0" "$(v2_field "$health_file" 7)"
assert_eq "v2_field8_rework_files" "0" "$(v2_field "$health_file" 8)"
assert_eq "v2_field9_tests_pass" "pass" "$(v2_field "$health_file" 9)"
assert_eq "v2_field11_max_re_edits" "3" "$(v2_field "$health_file" 11)"
assert_eq "v2_field12_topology" "iterating" "$(v2_field "$health_file" 12)"
assert_eq "v2_field13_domain" "src" "$(v2_field "$health_file" 13)"
assert_eq "v2_field14_self_misses" "0" "$(v2_field "$health_file" 14)"

# --- Test 13: fix_ratio is the literal string "null" when commits==0 ---
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "se-nullratio" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-nullratio" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "fix_ratio_null_when_no_commits" "null" "$(v2_field "$health_file" 6)"
assert_eq "commits_zero" "0" "$(v2_field "$health_file" 4)"

# --- Domain matrix (spec §6.1) ---

# Test 14: dominant segment wins (3 under src/, 1 under docs/ — no tie)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-dom-dominant")
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/a.ts"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/b.ts"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/app/c.ts"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/docs/readme.md"
make_journal "$_TEST_TMPDIR"
run_session_end "se-dom-dominant" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "domain_dominant_segment" "src" "$(v2_field "$health_file" 13)"

# Test 15: tie between two segments (2 under src/, 2 under docs/) -> mixed
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-dom-tie")
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/a.ts"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/b.ts"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/docs/one.md"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/docs/two.md"
make_journal "$_TEST_TMPDIR"
run_session_end "se-dom-tie" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "domain_tie_is_mixed" "mixed" "$(v2_field "$health_file" 13)"

# Test 16: fewer than 3 r-edits -> mixed even with a clear single segment
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-dom-under3")
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/a.ts"
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/b.ts"
make_journal "$_TEST_TMPDIR"
run_session_end "se-dom-under3" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "domain_under_3_is_mixed" "mixed" "$(v2_field "$health_file" 13)"

# Test 17: zero r-edits -> idle (x-flagged edits don't count toward domain)
# -> the idle classification now means NO ROW (queue item 5): a session of
# purely external/gitignored edits is still idle from the repo's viewpoint.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "se-dom-zero")
seed_file_edit "$LOG" x "${_TEST_TMPDIR}/.claude/plans/scratch.md"
make_journal "$_TEST_TMPDIR"
run_session_end "se-dom-zero" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "x_only_session_is_idle_no_row" "0" "$(count_health_rows "$health_file")"
assert_contains "x_only_session_marks_health_written" \
  "$(list_events health_written "$LOG")" "idle-skipped"

# --- Test 18: APPEND-ONLY health file (calibration wave, queue item 7): the
# v3 header-strip rewrite is DELETED with the healer — session-end performs
# create-with-header + row append and NOTHING else. Pre-existing v3-era lines
# (trend_direction=/avg_*=/---) SURVIVE untouched — every reader already
# filters them, and with both rewriters gone the two-writer race class is
# structurally over. ---
setup_test
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$(dirname "$health_file")"
create_health_file "$health_file" "2026-06-01|0|1.0|true|0|0|0|0|10|1|focused|proj"
create_event_log "$_TEST_TMPDIR/.claude" "se-strip1" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
make_journal "$_TEST_TMPDIR"
run_session_end "se-strip1" > /dev/null
assert_file_contains "append_only_v3_lines_survive" "$health_file" "trend_direction="
assert_file_contains "append_only_avg_lines_survive" "$health_file" "avg_reasoning_misses="
assert_file_contains "append_only_row_still_appended" "$health_file" "|se-strip1|"
assert_file_contains "append_only_legacy_row_survives" "$health_file" "2026-06-01|0|1.0"
# A second session-end (new sid, avoids per-sid dedup) appends its own row
# and still mutates nothing else.
create_event_log "$_TEST_TMPDIR/.claude" "se-strip2" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
run_session_end "se-strip2" > /dev/null
assert_file_contains "append_only_second_run_v3_lines_survive" "$health_file" "trend_direction="
assert_eq "append_only_all_rows_survive" "3" "$(count_health_rows "$health_file")"

# --- Test 19: fix_ratio + reverts computed from REAL git log subjects since
# session_start (real git sandbox — a mocked git can't exercise --since) ---
setup_test
GITDIR="$_TEST_TMPDIR/git-fixratio"
make_git_project "$GITDIR"
mkdir -p "$GITDIR/memory"
echo "# Journal" > "$GITDIR/memory/${TODAY}.md"
now_epoch=$(date +%s)
session_start_epoch=$((now_epoch - 300))
session_start_iso=$(date -u -d "@${session_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
commit_at "$GITDIR" "$((now_epoch - 200))" "fix: the parser" "a.ts"
commit_at "$GITDIR" "$((now_epoch - 150))" 'Revert "something"' "b.ts"
commit_at "$GITDIR" "$((now_epoch - 100))" "chore: cleanup" "c.ts"
create_event_log "$GITDIR/.claude" "se-fixratio" \
  "$((now_epoch + 1))|session_start|${session_start_iso} test-model" \
  "$((now_epoch + 2))|commit|c1 fix: the parser" \
  "$((now_epoch + 3))|commit|c2 revert: something" \
  "$((now_epoch + 4))|commit|c3 chore: cleanup" > /dev/null
run_session_end "se-fixratio" "$GITDIR" > /dev/null
health_file="$GITDIR/.claude/cortex/health.local.md"
assert_eq "fix_ratio_two_of_three" "0.67" "$(v2_field "$health_file" 6)"
assert_eq "reverts_counts_capital_revert_no_colon" "1" "$(v2_field "$health_file" 7)"

# --- Test 19b: SAME-PROVENANCE invariant (calibration wave, queue item 3):
# the commits field and fix_ratio denominator come from the SAME git window
# as the numerator — NEVER from event-log commit counts. Five seeded commit
# events over a 2-commit git window must yield commits=2, fix_ratio=0.50
# (the old event-count denominator produced impossible ratios like 5.00
# live, from mixed provenance). ---
setup_test
GITDIR="$_TEST_TMPDIR/git-provenance"
make_git_project "$GITDIR"
mkdir -p "$GITDIR/memory"
echo "# Journal" > "$GITDIR/memory/${TODAY}.md"
now_epoch=$(date +%s)
session_start_epoch=$((now_epoch - 300))
session_start_iso=$(date -u -d "@${session_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
commit_at "$GITDIR" "$((now_epoch - 200))" "fix: real one" "a.ts"
commit_at "$GITDIR" "$((now_epoch - 100))" "chore: real two" "b.ts"
create_event_log "$GITDIR/.claude" "se-provenance" \
  "$((now_epoch + 1))|session_start|${session_start_iso} test-model" \
  "$((now_epoch + 2))|commit|e1 fix: real one" \
  "$((now_epoch + 3))|commit|e2 chore: real two" \
  "$((now_epoch + 4))|commit|e3 phantom duplicate" \
  "$((now_epoch + 5))|commit|e4 phantom duplicate" \
  "$((now_epoch + 6))|commit|e5 phantom duplicate" > /dev/null
run_session_end "se-provenance" "$GITDIR" > /dev/null
health_file="$GITDIR/.claude/cortex/health.local.md"
assert_eq "commits_field_is_git_window_count" "2" "$(v2_field "$health_file" 4)"
assert_eq "fix_ratio_same_provenance" "0.50" "$(v2_field "$health_file" 6)"

# --- Test 20: rework_files — intersection of files committed THIS session
# with files touched by a commit in the 14 days before session_start ---
setup_test
GITDIR="$_TEST_TMPDIR/git-rework"
make_git_project "$GITDIR"
mkdir -p "$GITDIR/memory"
echo "# Journal" > "$GITDIR/memory/${TODAY}.md"
now_epoch=$(date +%s)
session_start_epoch=$((now_epoch - 300))
session_start_iso=$(date -u -d "@${session_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
prior_epoch=$((session_start_epoch - 10 * 86400))
commit_at "$GITDIR" "$prior_epoch" "chore: prior work" "rework.ts" "untouched.ts"
commit_at "$GITDIR" "$((now_epoch - 60))" "feat: session work" "rework.ts" "fresh.ts"
create_event_log "$GITDIR/.claude" "se-rework" \
  "$((now_epoch + 1))|session_start|${session_start_iso} test-model" \
  "$((now_epoch + 2))|commit|c1 feat: session work" > /dev/null
run_session_end "se-rework" "$GITDIR" > /dev/null
health_file="$GITDIR/.claude/cortex/health.local.md"
assert_eq "rework_files_intersection" "1" "$(v2_field "$health_file" 8)"

# --- Test 21: rework_files stays 0 when there are no prior-window commits
# (fresh repo, session's first-ever commits) ---
setup_test
GITDIR="$_TEST_TMPDIR/git-norework"
make_git_project "$GITDIR"
mkdir -p "$GITDIR/memory"
echo "# Journal" > "$GITDIR/memory/${TODAY}.md"
now_epoch=$(date +%s)
session_start_epoch=$((now_epoch - 300))
session_start_iso=$(date -u -d "@${session_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
commit_at "$GITDIR" "$((now_epoch - 60))" "feat: first ever commit" "only.ts"
create_event_log "$GITDIR/.claude" "se-norework" \
  "$((now_epoch + 1))|session_start|${session_start_iso} test-model" \
  "$((now_epoch + 2))|commit|c1 feat: first ever commit" > /dev/null
run_session_end "se-norework" "$GITDIR" > /dev/null
health_file="$GITDIR/.claude/cortex/health.local.md"
assert_eq "rework_files_zero_no_prior_window" "0" "$(v2_field "$health_file" 8)"

# --- Test 22: proposals_need_archiving is NOT in the closed v4 event
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
