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
# collapses to exactly ONE net effect (not zero, not two) regardless of which
# one contributes it, and that BOTH invocations independently satisfy the
# hook contract (exit 0, valid JSON) — a stale invocation must degrade
# gracefully to {}, never crash or emit malformed output.
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

# stamp_native_marker <claude_dir> — same contract as
# tests/integration/test-native-marker.sh's helper (content format doesn't
# matter to the dispatchers, only existence).
stamp_native_marker() {
  local claude_dir="$1"
  mkdir -p "$claude_dir/cortex"
  printf '3.18.1 2026-07-08T00:00:00Z\n' > "$claude_dir/cortex/native-hooks.ok"
}

# run_pair <script> <proj> <json> [extra-args...]
# Invokes <script>.sh WITH --native, then WITHOUT --native (the stale
# settings.json bootstrap entry), same payload both times, in that order.
# Sets OUT_NATIVE/RC_NATIVE/OUT_STALE/RC_STALE globals.
run_pair() {
  local script="$1" proj="$2" json="$3"
  set +e
  OUT_NATIVE=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/${script}.sh" --native 2>/dev/null)
  RC_NATIVE=$?
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
stamp_native_marker "$PROJ/.claude"
json=$(mock_json "tool_name=ExitPlanMode" "session_id=$SID")

before=$(count_events plan_mode '' '' "$LOG")
run_pair "pre-dispatch" "$PROJ" "$json"
after=$(count_events plan_mode '' '' "$LOG")

assert_pair_contract "pre_dispatch"
assert_net_delta "pre_dispatch_pair_exactly_one_plan_mode_event" "1" "$before" "$after"

# ============================================================================
# 2. post-dispatch.sh — discriminator: tool_call event (Bash payload).
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-post"
SID="df-post"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
stamp_native_marker "$PROJ/.claude"
json=$(mock_json "tool_name=Bash" "session_id=$SID" "tool_input.command=echo hi")

before=$(count_events tool_call '' '' "$LOG")
run_pair "post-dispatch" "$PROJ" "$json"
after=$(count_events tool_call '' '' "$LOG")

assert_pair_contract "post_dispatch"
assert_net_delta "post_dispatch_pair_exactly_one_tool_call_event" "1" "$before" "$after"

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
stamp_native_marker "$PROJ/.claude"
json=$(mock_json "user_prompt=[decision] use Postgres for this" "session_id=$SID")

run_pair "context-flow" "$PROJ" "$json"

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
stamp_native_marker "$PROJ/.claude"
json=$(mock_json "session_id=$SID")

before=$(( $(count_events stop_approved '' '' "$LOG") + $(count_events stop_blocked '' '' "$LOG") ))
run_pair "stop-gate" "$PROJ" "$json"
after=$(( $(count_events stop_approved '' '' "$LOG") + $(count_events stop_blocked '' '' "$LOG") ))

assert_pair_contract "stop_gate"
assert_net_delta "stop_gate_pair_exactly_one_decision_event" "1" "$before" "$after"

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
stamp_native_marker "$PROJ/.claude"
json=$(mock_json "session_id=$SID")
HEALTH_FILE="$PROJ/.claude/cortex/health.local.md"
TODAY=$(date +%Y-%m-%d)

before=$(grep -c "^${TODAY}|" "$HEALTH_FILE" 2>/dev/null || echo 0)
run_pair "session-end-dispatch" "$PROJ" "$json"
after=$(grep -c "^${TODAY}|" "$HEALTH_FILE" 2>/dev/null || echo 0)

assert_pair_contract "session_end"
assert_net_delta "session_end_pair_exactly_one_health_row" "1" "$before" "$after"

# ============================================================================
# 6. pre-compact.sh — discriminator: carry_over event appended by the
# transcript scan (a "[carry-over] ..." tagged line in transcript_path).
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-compact"
SID="df-compact"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
stamp_native_marker "$PROJ/.claude"
TRANSCRIPT="$_TEST_TMPDIR/transcript-compact.txt"
echo "[carry-over] Finish the dual-fire harness" > "$TRANSCRIPT"
json=$(mock_json "session_id=$SID" "transcript_path=$TRANSCRIPT")

before=$(count_events carry_over '' '' "$LOG")
run_pair "pre-compact" "$PROJ" "$json"
after=$(count_events carry_over '' '' "$LOG")

assert_pair_contract "pre_compact"
assert_net_delta "pre_compact_pair_exactly_one_carry_over_event" "1" "$before" "$after"

export PATH="$SAVED_PATH"
end_suite
