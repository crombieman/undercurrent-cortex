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

# Test (wave review C-3): a RACY derived count of zero must not skip the
# gate — ground truth decides. Log shape: commit A → edit → duplicate A
# observation (async double-observe) puts the anchor's first-occurrence
# math at 0 edits; the tree has a genuinely dirty TRACKED file; the session
# has an r-edit. Old structure returned silently on the zero path.
setup_test
GITD="$_TEST_TMPDIR/git-racy"
init_git_repo "$GITD"
echo "base" > "$GITD/f.ts"
git -C "$GITD" add -A
git -C "$GITD" commit -q -m "feat: base"
echo "dirty" >> "$GITD/f.ts"   # tracked, modified, uncommitted
mkdir -p "$GITD/.claude/cortex/sessions/test-week"
mark_opted_in "$GITD/.claude"
RLOG="$GITD/.claude/cortex/sessions/test-week/racy.events.log"
cat > "$RLOG" <<REOF
1700000001|session_start|2026-03-14T00:00:00Z m
1700000002|commit|aaa1111 feat: base
1700000003|file_edit|r ${GITD}/f.ts
1700000004|commit|aaa1111 feat: base
REOF
result=$(run_stop_gate_in "$GITD" "racy")
assert_contains "racy_zero_count_still_blocks_on_dirty_tree" "$result" "Uncommitted changes"

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
# Gate 2 (docs) is DEMOTED to a non-blocking reminder (locked D5): it never
# emits decision:block on its own. Tests below append a trailing commit event
# after the seeded edits so Gate 1 (uncommitted) doesn't co-fire and confound
# the "does this gate block" assertion — files_modified (Gate 2/3's unique-file
# list) is unaffected by the commit anchor, only Gate 1's own counter is.

# Test: Gate 2 is INACTIVE by default (no config.local) — spec §7.1: an
# unconfigured project keeps Undercurrent-specific vocabulary out of the
# public plugin, even when paths "look" architectural under the old
# hardcoded pattern and file_count > 3 with no docs_edit event.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-gate-unconfigured")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/engine.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/v11.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
result=$(run_stop_gate "docs-gate-unconfigured")
assert_not_contains "gate2_inactive_without_config" "$result" "documentation.md"

# Test: Gate 2 demotes to a reminder — docs_edit absent, > 3 unique
# architectural files touched (architectural_patterns configured explicitly,
# spec §7.1), no other gate active: approves with a systemMessage reminder,
# never blocks.
setup_test
set_config "$_TEST_TMPDIR/.claude" "architectural_patterns" "scoring|pipeline|v10|v11|constants|middleware|cached-loader|signals"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-gate")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/engine.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/v11.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
echo "1700000100|commit|abc1234 feat: land the scoring changes" >> "$LOG"
result=$(run_stop_gate "docs-gate")
assert_not_contains "gate2_reminder_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "gate2_reminder_text" "$result" "documentation.md not updated after architectural changes"
assert_contains "gate2_reminder_systemMessage_prefix" "$result" "Reminders: "
approved=$(last_event stop_approved "$LOG")
assert_eq "gate2_reminder_appends_stop_approved" "true" "$approved"
blocked_after=$(count_events stop_blocked '' '' "$LOG")
assert_eq "gate2_reminder_does_not_append_stop_blocked" "0" "$blocked_after"

# Test: Gate 2's reminder text honors a custom docs_file config value, still
# non-blocking.
setup_test
set_config "$_TEST_TMPDIR/.claude" "architectural_patterns" "scoring"
set_config "$_TEST_TMPDIR/.claude" "docs_file" "ARCHITECTURE.md"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "docs-gate-custom")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/engine.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/other.ts"
echo "1700000100|commit|abc1234 feat: land it" >> "$LOG"
result=$(run_stop_gate "docs-gate-custom")
assert_not_contains "gate2_custom_docs_file_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "gate2_custom_docs_file_text" "$result" "ARCHITECTURE.md"
assert_not_contains "gate2_custom_docs_file_no_default_text" "$result" "documentation.md not updated"

# Test: Gate 3 demotes to a reminder when no test ecosystem is detectable this
# session (no test-pattern file among the edits, no language marker file at
# the project root, no config test_command) — locked D5: verified-blocking
# only when a test ecosystem is actually detectable.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "tests-gate-undetected")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/pipeline.ts"
echo "1700000100|commit|abc1234 feat: land it" >> "$LOG"
result=$(run_stop_gate "tests-gate-undetected")
assert_not_contains "gate3_no_ecosystem_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "gate3_no_ecosystem_reminder_text" "$result" "Tests not run after modifying source files"

# Test: Gate 3 BLOCKS (verified) when a language marker file (package.json)
# is present at the project root — a detectable test ecosystem — and no
# test_run event exists this session. Language-neutral reason text (no more
# TypeScript-only wording/regex).
setup_test
touch "$_TEST_TMPDIR/package.json"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "tests-gate-marker")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/pipeline.ts"
echo "1700000100|commit|abc1234 feat: land it" >> "$LOG"
result=$(run_stop_gate "tests-gate-marker")
rm -f "$_TEST_TMPDIR/package.json"
assert_contains "gate3_blocks_via_language_marker" "$result" "\"decision\":\"block\""
assert_contains "gate3_blocks_language_neutral_text" "$result" "Tests not run after modifying source files"

# Test: Gate 3 BLOCKS via a test-file-pattern match among the session's edits
# (no marker file, no config — an edited path itself looks like a test file
# that was never actually run).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "tests-gate-pattern")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.test.ts"
echo "1700000100|commit|abc1234 feat: land it" >> "$LOG"
result=$(run_stop_gate "tests-gate-pattern")
assert_contains "gate3_blocks_via_test_file_pattern" "$result" "\"decision\":\"block\""

# Test: Gate 3 BLOCKS via a configured test_command marker (no other
# ecosystem signal present).
setup_test
set_config "$_TEST_TMPDIR/.claude" "test_command" "make test"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "tests-gate-config")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/utils.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/constants.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/pipeline.ts"
echo "1700000100|commit|abc1234 feat: land it" >> "$LOG"
result=$(run_stop_gate "tests-gate-config")
assert_contains "gate3_blocks_via_config_test_command" "$result" "\"decision\":\"block\""

# Test: docs/tests gates skipped when unique file_count <= 3, even with a
# scoring path and no docs_edit event (avoid nagging on quick fixes)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "low-edits")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/scoring/engine.ts"
result=$(run_stop_gate "low-edits")
assert_not_contains "skip_docs_gate_low_edits" "$result" "documentation.md"
assert_contains "skip_docs_gate_low_edits_still_blocks_uncommitted" "$result" "Uncommitted changes"

# Test: mixed session — Gate 1 (uncommitted) blocks while Gate 7 (decisions)
# is independently reminder-eligible. The block JSON's reason gets a
# "Reminders (non-blocking):" tail, and the appended stop_blocked event value
# lists ONLY the blocking gate name ("uncommitted"), never the reminder gate.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "mixed-block-reminder" \
  "1700000001|plan_mode|used" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/before.ts" \
  "1700000003|commit|abc1234 feat: bar" \
  "1700000004|file_edit|r ${_TEST_TMPDIR}/src/lib/after.ts")
result=$(run_stop_gate "mixed-block-reminder")
assert_contains "mixed_block_reminder_decision_blocks" "$result" "\"decision\":\"block\""
assert_contains "mixed_block_reminder_reason_has_uncommitted" "$result" "Uncommitted changes"
assert_contains "mixed_block_reminder_reason_has_reminder_tail" "$result" "Reminders (non-blocking):"
assert_contains "mixed_block_reminder_reason_has_decisions_reminder" "$result" "Decisions not captured"
blocked_value=$(last_event stop_blocked "$LOG")
assert_eq "stop_blocked_value_excludes_reminder_gates" "uncommitted" "$blocked_value"

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
# Demoted to a non-blocking reminder (locked D5) — a fix: commit with no
# root_cause_logged event now approves with a systemMessage, never blocks.

# Test: Gate 6 demotes to a reminder — fix: commit landed this session, no
# root_cause_logged event exists, standard profile.
setup_test
GITDIR="$_TEST_TMPDIR/git-rootcause"
init_git_repo "$GITDIR"
echo "x" > "$GITDIR/f.txt"
git -C "$GITDIR" add -A
git -C "$GITDIR" commit -q -m "fix: something broke"
LOG=$(create_event_log "$GITDIR/.claude" "rootcause" \
  "1700000001|commit|abc1234 fix: something broke")
result=$(run_stop_gate_in "$GITDIR" "rootcause")
assert_not_contains "root_cause_reminder_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "root_cause_reminder_text" "$result" "Root cause not documented"
assert_contains "root_cause_reminder_default_lessons_file_text" "$result" "tasks/lessons.md"
approved=$(last_event stop_approved "$LOG")
assert_eq "root_cause_reminder_appends_stop_approved" "true" "$approved"

# Test: Gate 6's reminder text honors a custom lessons_file config value,
# still non-blocking.
setup_test
GITDIR="$_TEST_TMPDIR/git-rootcause-custom"
init_git_repo "$GITDIR"
echo "x" > "$GITDIR/f.txt"
git -C "$GITDIR" add -A
git -C "$GITDIR" commit -q -m "fix: something broke"
set_config "$GITDIR/.claude" "lessons_file" "docs/CHANGELOG.md"
create_event_log "$GITDIR/.claude" "rootcause-custom" \
  "1700000001|commit|abc1234 fix: something broke" > /dev/null
result=$(run_stop_gate_in "$GITDIR" "rootcause-custom")
assert_not_contains "gate6_custom_lessons_file_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "gate6_custom_lessons_file_text" "$result" "docs/CHANGELOG.md"
assert_not_contains "gate6_custom_lessons_file_no_default_text" "$result" "tasks/lessons.md"

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
# Demoted to a non-blocking reminder (locked D5).

# Test: Gate 7 demotes to a reminder — plan_mode was used, a commit landed,
# but no decision_logged event exists.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "decisions-gate" \
  "1700000001|plan_mode|used" \
  "1700000002|commit|abc1234 feat: something")
result=$(run_stop_gate "decisions-gate")
assert_not_contains "gate7_reminder_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "gate7_reminder_text" "$result" "Decisions not captured"
approved=$(last_event stop_approved "$LOG")
assert_eq "gate7_reminder_appends_stop_approved" "true" "$approved"

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

# --- Gate 3 honesty predicate (review F1): docs-only sessions never trip a
# gate whose reason text says "source files", even when an ecosystem marker
# (package.json) exists at the project root ---
setup_test
touch "$_TEST_TMPDIR/package.json"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "tests-gate-docs-only")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/README.md"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/docs/guide.md"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/docs/api.md"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/docs/faq.md"
echo "1700000100|commit|abc1234 docs: refresh" >> "$LOG"
result=$(run_stop_gate "tests-gate-docs-only")
assert_not_contains "gate3_docs_only_never_blocks" "$result" "\"decision\":\"block\""
assert_not_contains "gate3_docs_only_no_reminder_either" "$result" "Tests not run"

# --- Gate 3 after-anchor (Codex W4 review I-1, spec §5.1): the gate requires
# a test_run AFTER the last source file_edit — a stale early-session test run
# must not satisfy it forever ---

# Stale test_run before a later source edit → blocks
setup_test
touch "$_TEST_TMPDIR/package.json"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "g3-stale-testrun")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/a.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/b.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/c.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/d.ts"
echo "1700009001|test_run|vitest" >> "$LOG"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/core.ts"
result=$(run_stop_gate "g3-stale-testrun")
assert_contains "gate3_stale_test_run_blocks" "$result" "Tests not run after modifying source files"
assert_contains "gate3_stale_test_run_decision_block" "$result" "\"decision\":\"block\""

# test_run after the last source edit → Gate 3 quiet (Gate 1 anchored quiet too)
setup_test
touch "$_TEST_TMPDIR/package.json"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "g3-fresh-testrun")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/a.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/b.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/c.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/d.ts"
echo "1700009001|commit|abc1234 feat: four files" >> "$LOG"
echo "1700009002|test_run|vitest" >> "$LOG"
result=$(run_stop_gate "g3-fresh-testrun")
assert_not_contains "gate3_fresh_test_run_quiet" "$result" "Tests not run"

# A NON-source edit (docs) after the test run must not re-trip the gate —
# the anchor is the last SOURCE file_edit, not the last file_edit of any kind
setup_test
touch "$_TEST_TMPDIR/package.json"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "g3-docs-after-tests")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/a.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/b.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/c.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/d.ts"
echo "1700009001|test_run|vitest" >> "$LOG"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/README.md"
echo "1700009002|commit|abc1234 feat: all done" >> "$LOG"
result=$(run_stop_gate "g3-docs-after-tests")
assert_not_contains "gate3_docs_edit_after_tests_does_not_retrip" "$result" "Tests not run"

# --- NEW Codex-review gate (spec §5.6, D7/L9, T6): reminder-only ---

# Trigger A: plan_mode used, no codex_review → approve path carries the
# reminder (pre-authorized + two-step wording) and logs the intervention
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-gate-plan" \
  "1700000002|plan_mode|used")
result=$(run_stop_gate "codex-gate-plan")
assert_not_contains "codex_gate_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "codex_gate_reminder_text" "$result" "Codex review not dispatched"
assert_contains "codex_gate_preauthorized_text" "$result" "pre-authorized"
assert_contains "codex_gate_two_step_text" "$result" "harvest"
assert_contains "codex_gate_intervention_logged" "$(list_events intervention "$LOG")" "codex_reminder"

# Trigger B: >= 4 distinct r-flagged files (commit-anchored so Gate 1 stays
# quiet; test_run seeded so Gate 3 stays quiet regardless of stray ecosystem
# markers left in the suite tmpdir — setup_test only wipes .claude/*), no
# plan_mode → reminder still fires
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-gate-files")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/a.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/b.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/c.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/d.ts"
echo "1700000100|commit|abc1234 feat: four files" >> "$LOG"
echo "1700000101|test_run|vitest" >> "$LOG"
result=$(run_stop_gate "codex-gate-files")
assert_not_contains "codex_gate_files_does_not_block" "$result" "\"decision\":\"block\""
assert_contains "codex_gate_files_reminder_text" "$result" "Codex review not dispatched"
assert_contains "codex_gate_files_intervention_logged" "$(list_events intervention "$LOG")" "codex_reminder"

# Satisfied: codex_review event present → silent, no intervention
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-gate-satisfied" \
  "1700000002|plan_mode|used" \
  "1700000003|codex_review|cli")
result=$(run_stop_gate "codex-gate-satisfied")
assert_not_contains "codex_gate_silent_when_reviewed" "$result" "Codex review not dispatched"
assert_eq "codex_gate_no_intervention_when_reviewed" "0" "$(count_events intervention codex_reminder '' "$LOG")"

# Under both triggers: 3 distinct r files, no plan_mode → silent
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-gate-under")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/a.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/b.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/c.ts"
echo "1700000100|commit|abc1234 feat: three files" >> "$LOG"
result=$(run_stop_gate "codex-gate-under")
assert_not_contains "codex_gate_silent_under_thresholds" "$result" "Codex review not dispatched"

# Once per session: a second Stop re-reminds but does NOT duplicate the
# intervention event (the fired denominator counts sessions, not Stop attempts)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-gate-once" \
  "1700000002|plan_mode|used")
run_stop_gate "codex-gate-once" > /dev/null
result=$(run_stop_gate "codex-gate-once")
assert_contains "codex_gate_second_stop_still_reminds" "$result" "Codex review not dispatched"
assert_eq "codex_intervention_once_per_session" "1" "$(count_events intervention codex_reminder '' "$LOG")"

# --- Fail-open when block state can't persist (W5 review I-1): a read-only
# log means stop_blocked never lands, so the 2-block escape hatch could never
# fire and decision:block would repeat FOREVER. Degrade to a non-blocking
# systemMessage instead. ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "ro-log-failopen")
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/blocked.ts"
chmod 444 "$LOG" 2>/dev/null || true
result=$(run_stop_gate "ro-log-failopen")
chmod 644 "$LOG" 2>/dev/null || true
assert_not_contains "readonly_log_never_blocks" "$result" "\"decision\":\"block\""
assert_contains "readonly_log_warns_instead" "$result" "systemMessage"

end_suite
