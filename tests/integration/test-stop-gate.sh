#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "stop-gate"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell — event-io.sh
# (unlike the sandbox's sed-patched state-io.sh copy, which stop-gate no longer
# uses) resolves the project dir from this env var at call time, so it must be
# set here explicitly (pattern: tests/integration/test-post-dispatch.sh:22).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run stop-gate with given session id against the default sandbox project dir
run_stop_gate() {
  local sid="$1"
  echo "{\"session_id\":\"${sid}\"}" | bash "$SANDBOX/hooks/scripts/stop-gate.sh" 2>/dev/null || true
}

# Helper: run stop-gate with a project dir override (for gates that inspect
# real git state — Gate 1's git-status cross-check, Gate 6's fix-commit scan).
# CORTEX_PROJECT_DIR is set inline for this single subprocess only; it does not
# leak into the suite-level default used by run_stop_gate.
run_stop_gate_in() {
  local project_dir="$1" sid="$2"
  echo "{\"session_id\":\"${sid}\"}" | CORTEX_PROJECT_DIR="$project_dir" bash "$SANDBOX/hooks/scripts/stop-gate.sh" 2>/dev/null || true
}

# Helper: real git repo for gate tests needing actual git state. Real git, not
# mocked — Gate 1 and Gate 6 run genuine `git status`/`git log` against
# PROJECT_DIR, so the tests need a real .git to exercise that code path.
init_git_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "Cortex Test"
}

# --- Gate 1: uncommitted changes ---

# Test: all gates pass on a clean event log (only session_start) - returns {}
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "clean-stop" > /dev/null
result=$(run_stop_gate "clean-stop")
assert_eq "all_gates_pass_when_clean" "{}" "$result"

# Test: block when file_edit(r) events exist with no intervening commit anchor
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "uncommitted")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/foo.ts"
result=$(run_stop_gate "uncommitted")
assert_contains "block_on_uncommitted_changes" "$result" "block"
assert_contains "block_on_uncommitted_changes_reason" "$result" "Uncommitted changes"

# Test: git-status self-heal clears a false positive — event log claims an
# edit, but the real working tree is clean (already committed), so the
# belt-and-suspenders git status cross-check resets edits to 0.
setup_test
GITDIR="$_TEST_TMPDIR/git-selfheal"
init_git_repo "$GITDIR"
echo "content" > "$GITDIR/tracked.txt"
git -C "$GITDIR" add -A
git -C "$GITDIR" commit -q -m "chore: baseline"
create_event_log "$GITDIR/.claude" "selfheal" \
  "1700000001|file_edit|r ${GITDIR}/tracked.txt" > /dev/null
result=$(run_stop_gate_in "$GITDIR" "selfheal")
assert_eq "git_status_self_heal_clears_false_positive" "{}" "$result"

# --- Gates 2 & 3: docs / tests, only fire when file_count > 3 ---

# Test: block when docs_edit is absent and > 3 unique architectural files touched
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-gate")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/engine.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/v11.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
result=$(run_stop_gate "docs-gate")
assert_contains "block_docs_not_updated" "$result" "documentation.md"

# Test: block when test_run is absent and > 3 unique .ts files touched
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "tests-gate")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/pipeline.ts"
result=$(run_stop_gate "tests-gate")
assert_contains "block_tests_not_run" "$result" "Tests not run"

# Test: docs gate skipped when unique file_count <= 3, even with a scoring path
# and no docs_edit event (avoid nagging on quick fixes)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "low-edits")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/engine.ts"
result=$(run_stop_gate "low-edits")
assert_not_contains "skip_docs_gate_low_edits" "$result" "documentation.md"
assert_contains "skip_docs_gate_low_edits_still_blocks_uncommitted" "$result" "Uncommitted changes"

# --- Gate 4: carry-over items not addressed ---

# Test: block when a carry_over item exists with no matching carry_addressed hash
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "carry-gate" \
  "1700000001|carry_over|Fix the broken pipeline" > /dev/null
result=$(run_stop_gate "carry-gate")
assert_contains "block_carry_over_unaddressed" "$result" "Carry-over"

# Test: carry-over item addressed by matching content hash clears Gate 4
setup_test
item_text="Fix the broken pipeline"
item_hash=$(eio_item_hash "$item_text")
create_event_log "$_TEST_TMPDIR/.claude" "carry-addressed" \
  "1700000001|carry_over|${item_text}" \
  "1700000002|carry_addressed|${item_hash}" > /dev/null
result=$(run_stop_gate "carry-addressed")
assert_eq "carry_over_addressed_by_hash_skips_gate4" "{}" "$result"

# Test: re-raising an addressed item (carry epoch AFTER the addressed epoch)
# resurrects it — Gate 4 re-blocks (spec §3.5 epoch-ordering amendment).
setup_test
item_text="Fix the broken pipeline"
item_hash=$(eio_item_hash "$item_text")
create_event_log "$_TEST_TMPDIR/.claude" "carry-reraise" \
  "1700000001|carry_over|${item_text}" \
  "1700000002|carry_addressed|${item_hash}" \
  "1700000003|carry_over|${item_text}" > /dev/null
result=$(run_stop_gate "carry-reraise")
assert_contains "reraised_carry_over_reblocks_gate4" "$result" "Carry-over"

# --- Gate 5: stale carry-over ---

# Test: block when carry_over_age >= 3 (session-start-written, stop-gate only reads it)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "stale-carry" \
  "1700000001|carry_over_age|3" > /dev/null
result=$(run_stop_gate "stale-carry")
assert_contains "block_stale_carry_over" "$result" "Stale carry-over"

# --- Gate 6: root cause documentation after fix: commits ---

# Test: block when a fix: commit landed this session and no root_cause_logged event exists
setup_test
GITDIR="$_TEST_TMPDIR/git-rootcause"
init_git_repo "$GITDIR"
echo "x" > "$GITDIR/f.txt"
git -C "$GITDIR" add -A
git -C "$GITDIR" commit -q -m "fix: something broke"
create_event_log "$GITDIR/.claude" "rootcause" \
  "1700000001|commit|abc1234 fix: something broke" > /dev/null
result=$(run_stop_gate_in "$GITDIR" "rootcause")
assert_contains "block_root_cause_not_documented" "$result" "Root cause not documented"

# Test: root-cause gate exempt under the minimal profile
setup_test
GITDIR="$_TEST_TMPDIR/git-rootcause-minimal"
init_git_repo "$GITDIR"
echo "x" > "$GITDIR/f.txt"
git -C "$GITDIR" add -A
git -C "$GITDIR" commit -q -m "fix: something broke"
mkdir -p "$GITDIR/.claude/cortex"
echo "minimal" > "$GITDIR/.claude/cortex/profile.local"
create_event_log "$GITDIR/.claude" "rootcause-min" \
  "1700000001|commit|abc1234 fix: something broke" > /dev/null
result=$(run_stop_gate_in "$GITDIR" "rootcause-min")
assert_eq "root_cause_gate_exempt_under_minimal_profile" "{}" "$result"

# --- Gate 7: decisions captured after plan-mode session ---

# Test: block when plan_mode was used, a commit landed, but no decision_logged event
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "decisions-gate" \
  "1700000001|plan_mode|used" \
  "1700000002|commit|abc1234 feat: something" > /dev/null
result=$(run_stop_gate "decisions-gate")
assert_contains "block_decisions_not_captured" "$result" "Decisions not captured"

# --- Escape hatch: consecutive stop_blocked events since last approve/force ---

# Test: first block appends exactly one stop_blocked event (no force-approve yet)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "first-block" \
  "1700000001|carry_over|Fix the thing")
result=$(run_stop_gate "first-block")
assert_contains "first_block_result_is_block" "$result" "block"
assert_not_contains "first_block_not_force_approved" "$result" "force-approved"
consec=$(count_events stop_blocked '' '' "$LOG")
assert_eq "first_block_appends_one_stop_blocked_event" "1" "$consec"

# Test: two prior consecutive stop_blocked events force-approve on the third call
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "force-approve" \
  "1700000001|stop_blocked|carry_over" \
  "1700000002|stop_blocked|carry_over")
result=$(run_stop_gate "force-approve")
assert_contains "force_approve_after_two_blocks" "$result" "force-approved"
forced=$(count_events stop_forced '' '' "$LOG")
assert_eq "force_approve_appends_stop_forced_event" "1" "$forced"

# Test (spec-required sequence): block, block, pass, block => the last block
# does NOT force-approve. The escape hatch fires on the 3rd call (2 prior
# consecutive blocks => forced pass, appends stop_forced as the reset anchor);
# the 4th call re-evaluates gates fresh against a still-failing condition and
# blocks again without forcing, since only 1 block has occurred since the anchor.
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "seq-test" \
  "1700000001|carry_over|Fix the thing" > /dev/null
r1=$(run_stop_gate "seq-test")
r2=$(run_stop_gate "seq-test")
r3=$(run_stop_gate "seq-test")
r4=$(run_stop_gate "seq-test")
assert_contains "sequence_call1_blocks" "$r1" "block"
assert_contains "sequence_call2_blocks" "$r2" "block"
assert_contains "sequence_call3_force_approves" "$r3" "force-approved"
assert_contains "sequence_call4_blocks_again" "$r4" "block"
assert_not_contains "sequence_call4_does_not_force_approve" "$r4" "force-approved"

# --- No event log: nothing to gate (no legacy state-file fallback in v4) ---

# Test: unresolvable session_id (no event log on disk) returns {}
setup_test
result=$(echo '{"session_id":"totally-missing"}' | bash "$SANDBOX/hooks/scripts/stop-gate.sh" 2>/dev/null || true)
assert_eq "missing_event_log_returns_empty" "{}" "$result"

end_suite
