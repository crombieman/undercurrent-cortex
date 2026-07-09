#!/usr/bin/env bash
set -euo pipefail
# Dual-fire overlap harness (spec §12, regression armor for Task 5's --native
# suppression protocol). Simulates the FIRST 4.0 session's overlap state:
# native-hooks.ok was just written this session (session-start writes it once
# the opt-in gate passes), but the stale ~/.claude/settings.json
# bootstrap-hooks.sh entry for the SAME event hasn't been cleaned up yet — so
# for a single real Claude Code event, TWO invocations of the same dispatcher
# fire with the SAME payload: one native (hooks.json, carries --native) and
# one stale (settings.json bootstrap entry, no --native).
#
# For each of the 6 dispatchers that accept --native, this proves the pair
# collapses to exactly ONE net effect WITH THE CORRECT DIRECTIONALITY — the
# NATIVE invocation contributes it and the STALE invocation contributes
# nothing and outputs bare {} — and that BOTH invocations independently
# satisfy the hook contract (exit 0, valid JSON).
#
# Mutation-hardening note: a pair-nets-to-one assertion ALONE is blind to an
# inverted suppression condition ([ "$NATIVE" != true ] → [ = true ]): the
# pair still nets to one (native suppressed, stale proceeding), and for
# payloads whose normal-path output is {} anyway (post-dispatch Bash echo,
# stop-gate clean approve, pre-dispatch ExitPlanMode, session-end happy
# path), even asserting OUT_STALE == "{}" stays green under the mutation.
# The load-bearing directional check is therefore the MID-PAIR discriminator
# sample: native alone must contribute exactly 1, stale alone exactly 0.
# (Verified RED against exactly that mutation — see task-7-report.md.)
#
# Scripts are invoked DIRECTLY against the real plugin (mirrors
# tests/integration/test-native-marker.sh and test-opt-in-gate.sh) —
# CORTEX_PROJECT_DIR is set inline per-invocation so each block gets an
# isolated project dir.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "dual-fire"

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

# stamp_native_marker <claude_dir> <session_id> — same contract as
# tests/integration/test-native-marker.sh's helper. The session_id 3rd token is
# now load-bearing (Codex I-2): the STALE (non-native) invocation suppresses
# ONLY when the marker's sid matches its payload's sid, so every dual-fire block
# stamps the SAME sid its payload carries — reproducing the real first-4.0-
# session overlap where session-start wrote the marker for THIS session.
stamp_native_marker() {
  local claude_dir="$1" sid="${2:-}"
  mkdir -p "$claude_dir/cortex"
  printf '3.18.1 2026-07-08T00:00:00Z %s\n' "$sid" > "$claude_dir/cortex/native-hooks.ok"
}

# run_native / run_stale <script> <proj> <json>
# Split into two calls (not one run_pair) so each block can sample its
# discriminator BETWEEN the invocations — the mid-pair sample is what makes
# the directionality assertions possible (see mutation-hardening note above).
# run_native invokes WITH --native (the hooks.json registration) and sets
# OUT_NATIVE/RC_NATIVE; run_stale invokes WITHOUT --native (the stale
# settings.json bootstrap entry) and sets OUT_STALE/RC_STALE.
run_native() {
  local script="$1" proj="$2" json="$3"
  set +e
  OUT_NATIVE=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/${script}.sh" --native 2>/dev/null)
  RC_NATIVE=$?
  set -e
}

run_stale() {
  local script="$1" proj="$2" json="$3"
  set +e
  OUT_STALE=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/${script}.sh" 2>/dev/null)
  RC_STALE=$?
  set -e
}

# assert_pair_contract <label_prefix> — both invocations of the pair exit 0
# with syntactically valid JSON (the baseline hook contract every invocation
# must satisfy, suppressed or not).
assert_pair_contract() {
  local prefix="$1"
  assert_eq "${prefix}_native_exit_0" "0" "$RC_NATIVE"
  assert_eq "${prefix}_stale_exit_0" "0" "$RC_STALE"
  assert_json_valid "${prefix}_native_valid_json" "$OUT_NATIVE"
  assert_json_valid "${prefix}_stale_valid_json" "$OUT_STALE"
}

# assert_net_delta <name> <expected> <before> <after> — the pair's combined
# contribution to a discriminator count.
assert_net_delta() {
  local name="$1" expected="$2" before="$3" after="$4"
  assert_eq "$name" "$expected" "$((after - before))"
}

# ============================================================================
# 1. pre-dispatch.sh — discriminator: plan_mode event (ExitPlanMode payload).
# Native suppression happens BEFORE resolve_event_log is even called, so the
# stale invocation contributes zero appends, not just a suppressed message.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-pre"
SID="df-pre"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
stamp_native_marker "$PROJ/.claude" "$SID"
json=$(mock_json "tool_name=ExitPlanMode" "session_id=$SID")

before=$(count_events plan_mode '' '' "$LOG")
run_native "pre-dispatch" "$PROJ" "$json"
mid=$(count_events plan_mode '' '' "$LOG")
run_stale "pre-dispatch" "$PROJ" "$json"
after=$(count_events plan_mode '' '' "$LOG")

assert_pair_contract "pre_dispatch"
assert_net_delta "pre_dispatch_native_contributes_the_plan_mode_event" "1" "$before" "$mid"
assert_net_delta "pre_dispatch_stale_contributes_nothing" "0" "$mid" "$after"
assert_eq "pre_dispatch_stale_suppressed_returns_empty" "{}" "$OUT_STALE"

# ============================================================================
# 2. post-dispatch.sh — discriminator: tool_call event (Bash payload).
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-post"
SID="df-post"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
stamp_native_marker "$PROJ/.claude" "$SID"
json=$(mock_json "tool_name=Bash" "session_id=$SID" "tool_input.command=echo hi")

before=$(count_events tool_call '' '' "$LOG")
run_native "post-dispatch" "$PROJ" "$json"
mid=$(count_events tool_call '' '' "$LOG")
run_stale "post-dispatch" "$PROJ" "$json"
after=$(count_events tool_call '' '' "$LOG")

assert_pair_contract "post_dispatch"
assert_net_delta "post_dispatch_native_contributes_the_tool_call_event" "1" "$before" "$mid"
assert_net_delta "post_dispatch_stale_contributes_nothing" "0" "$mid" "$after"
assert_eq "post_dispatch_stale_suppressed_returns_empty" "{}" "$OUT_STALE"

# ============================================================================
# 3. context-flow.sh — context-flow appends NO event on the "[decision]"
# path (no sub-process call), so there is no event-log discriminator to
# count. Its user-visible "net effect" is the systemMessage itself — dual
# firing here would mean the Decision-detected reminder is shown TWICE. The
# discriminator is therefore message-emission count, not event-log growth:
# the stale run must emit it zero times, the native run exactly once.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-ctx"
SID="df-ctx"
create_event_log "$PROJ/.claude" "$SID" > /dev/null
stamp_native_marker "$PROJ/.claude" "$SID"
json=$(mock_json "user_prompt=[decision] use Postgres for this" "session_id=$SID")

run_native "context-flow" "$PROJ" "$json"
run_stale "context-flow" "$PROJ" "$json"

assert_pair_contract "context_flow"
assert_eq "context_flow_stale_suppressed_returns_empty" "{}" "$OUT_STALE"
assert_contains "context_flow_native_message_shown_once" "$OUT_NATIVE" "Decision detected"

# ============================================================================
# 4. stop-gate.sh — discriminator: stop_approved + stop_blocked combined
# (whichever fires — brief's "exactly one stop_approved/stop_blocked
# appended"). Fresh clean log (no edits/carry-over) approves deterministically.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-stop"
SID="df-stop"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
stamp_native_marker "$PROJ/.claude" "$SID"
json=$(mock_json "session_id=$SID")

before=$(( $(count_events stop_approved '' '' "$LOG") + $(count_events stop_blocked '' '' "$LOG") ))
run_native "stop-gate" "$PROJ" "$json"
mid=$(( $(count_events stop_approved '' '' "$LOG") + $(count_events stop_blocked '' '' "$LOG") ))
run_stale "stop-gate" "$PROJ" "$json"
after=$(( $(count_events stop_approved '' '' "$LOG") + $(count_events stop_blocked '' '' "$LOG") ))

assert_pair_contract "stop_gate"
assert_net_delta "stop_gate_native_contributes_the_decision_event" "1" "$before" "$mid"
assert_net_delta "stop_gate_stale_contributes_nothing" "0" "$mid" "$after"
assert_eq "stop_gate_stale_suppressed_returns_empty" "{}" "$OUT_STALE"

# ============================================================================
# 5. session-end-dispatch.sh — discriminator: exactly one health row for
# today in health.local.md (brief's explicit "session-end: exactly one
# health row"). Fresh clean log — session gets tagged idle but a row is
# still written (idle sessions are tracked, not skipped).
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-end"
SID="df-end"
create_event_log "$PROJ/.claude" "$SID" > /dev/null
stamp_native_marker "$PROJ/.claude" "$SID"
json=$(mock_json "session_id=$SID")
HEALTH_FILE="$PROJ/.claude/cortex/health.local.md"
TODAY=$(date +%Y-%m-%d)

# count_today_rows — v2 rows are prefixed "v2|<date>|..." (spec §6.1), not
# date-first like the old v3 shape. grep -c both prints "0" AND exits
# non-zero on a no-match file (the "0\n0" double-output gotcha documented in
# session-end-dispatch.sh); guard with grep -q first, and treat a missing
# file as 0.
count_today_rows() {
  if [ -f "$HEALTH_FILE" ] && grep -q "^v2|${TODAY}|" "$HEALTH_FILE" 2>/dev/null; then
    grep -c "^v2|${TODAY}|" "$HEALTH_FILE" 2>/dev/null
  else
    echo 0
  fi
}

before=$(count_today_rows)
run_native "session-end-dispatch" "$PROJ" "$json"
mid=$(count_today_rows)
run_stale "session-end-dispatch" "$PROJ" "$json"
after=$(count_today_rows)

assert_pair_contract "session_end"
assert_net_delta "session_end_native_contributes_the_health_row" "1" "$before" "$mid"
assert_net_delta "session_end_stale_contributes_nothing" "0" "$mid" "$after"
assert_eq "session_end_stale_suppressed_returns_empty" "{}" "$OUT_STALE"

# ============================================================================
# 6. pre-compact.sh — discriminator: carry_over event appended by the
# transcript scan (a "[carry-over] ..." tagged line in transcript_path).
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-compact"
SID="df-compact"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
stamp_native_marker "$PROJ/.claude" "$SID"
TRANSCRIPT="$_TEST_TMPDIR/transcript-compact.txt"
echo "[carry-over] Finish the dual-fire harness" > "$TRANSCRIPT"
json=$(mock_json "session_id=$SID" "transcript_path=$TRANSCRIPT")

before=$(count_events carry_over '' '' "$LOG")
run_native "pre-compact" "$PROJ" "$json"
mid=$(count_events carry_over '' '' "$LOG")
run_stale "pre-compact" "$PROJ" "$json"
after=$(count_events carry_over '' '' "$LOG")

assert_pair_contract "pre_compact"
assert_net_delta "pre_compact_native_contributes_the_carry_over_event" "1" "$before" "$mid"
assert_net_delta "pre_compact_stale_contributes_nothing" "0" "$mid" "$after"
assert_eq "pre_compact_stale_suppressed_returns_empty" "{}" "$OUT_STALE"

export PATH="$SAVED_PATH"
end_suite
