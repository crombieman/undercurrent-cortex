#!/usr/bin/env bash
set -euo pipefail
# Hook-contract matrix (spec §12, W8). The 8 top-level hook entry points —
# session-start, pre-dispatch, post-dispatch, context-flow, stop-gate,
# session-end-dispatch, pre-compact, drift-detector — are ALL JSON-output
# surfaces: Claude Code parses their stdout as JSON regardless of what
# triggered the invocation. This proves, for each entry point, that ALL 3
# stdin shapes it can ever actually receive (empty, malformed non-JSON, a
# normal well-formed payload) produce exit 0 + syntactically valid JSON — the
# one invariant every hook must hold no matter what. 8 x 3 = 24 cells, one
# nested loop.
#
# Every cell runs against an OPTED fixture (sentinel present, event log
# present for the 7 dispatchers that key off session_id). The un-opted-repo
# case is already covered by tests/integration/test-opt-in-gate.sh — out of
# scope here by design (this matrix is specifically about stdin-shape
# robustness, not opt-in gating).
#
# Scripts are invoked DIRECTLY against the real plugin (mirrors
# test-native-marker.sh / test-opt-in-gate.sh) — CORTEX_PROJECT_DIR (and, for
# session-start, HOME) are set inline per-invocation.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "hook-contract"

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

ENTRY_POINTS="session-start pre-dispatch post-dispatch context-flow stop-gate session-end-dispatch pre-compact drift-detector"
STDIN_CLASSES="empty malformed normal"

# build_payload <entry> <sid> — echoes the "normal" class payload for <entry>.
# Deliberately neutral content (no keyword collisions, no git-push/decision/
# proposal triggers) — the matrix is about stdin SHAPE, not routing branches;
# those are covered by each script's own dedicated suite.
build_payload() {
  local entry="$1" sid="$2"
  case "$entry" in
    context-flow)
      mock_json "user_prompt=please summarize the recent changes" "session_id=$sid"
      ;;
    pre-dispatch|post-dispatch)
      mock_json "tool_name=Bash" "session_id=$sid" "tool_input.command=echo normal"
      ;;
    *)
      mock_json "session_id=$sid"
      ;;
  esac
}

# run_entry <entry> <class> <proj> <sid> — invokes <entry> with the stdin
# payload for <class>. Sets CELL_OUT / CELL_RC globals.
run_entry() {
  local entry="$1" class="$2" proj="$3" sid="$4"
  local payload=""
  case "$class" in
    empty) payload="" ;;
    malformed) payload='not valid json {{{' ;;
    normal) payload="$(build_payload "$entry" "$sid")" ;;
  esac

  set +e
  case "$entry" in
    session-start)
      CELL_OUT=$(printf '%s' "$payload" | CORTEX_PROJECT_DIR="$proj" HOME="$proj" bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null)
      ;;
    drift-detector)
      CELL_OUT=$(printf '%s' "$payload" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/drift-detector.sh" 2>/dev/null)
      ;;
    *)
      CELL_OUT=$(printf '%s' "$payload" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/${entry}.sh" 2>/dev/null)
      ;;
  esac
  CELL_RC=$?
  set -e
}

# ============================================================================
# The 8 x 3 = 24-cell matrix.
# ============================================================================
for entry in $ENTRY_POINTS; do
  setup_test
  PROJ="$_TEST_TMPDIR/proj-${entry}"
  SID="hc-${entry}"
  if [ "$entry" = "session-start" ]; then
    # session-start CREATES the event log itself — it only needs the
    # sentinel (mirrors test-session-start.sh's setup_opted_test).
    mkdir -p "$PROJ/.claude/cortex"
    touch "$PROJ/.claude/cortex/enabled"
  else
    create_event_log "$PROJ/.claude" "$SID" > /dev/null
  fi

  for class in $STDIN_CLASSES; do
    run_entry "$entry" "$class" "$PROJ" "$SID"
    label="${entry//-/_}_${class}_stdin"
    assert_eq "${label}_exit_0" "0" "$CELL_RC"
    assert_json_valid "${label}_valid_json" "$CELL_OUT"
  done
done

# ============================================================================
# Folded in from tests/edge/test-empty-stdin.sh (deleted in this commit).
# All 8 of its original assertions are preserved here:
#   - 2 (context-flow, pre-dispatch empty-stdin) map onto cells already run
#     above; re-asserted here with the ORIGINAL suite's exact strictness
#     (assert_eq "{}") since the matrix loop above intentionally uses the
#     looser assert_json_valid uniformly across all 24 cells.
#   - 3 (stop-gate, pre-compact, session-end-dispatch empty-stdin) already
#     used assert_json_valid in the original — trivially subsumed by the
#     matrix loop above with no further action needed.
#   - 3 (migration-linter.sh, post-edit-dispatch.sh, post-bash-dispatch.sh)
#     exercise SUB-HANDLER scripts that are not among the 8 canonical hook
#     entry points — they're only reachable THROUGH pre-dispatch.sh /
#     post-dispatch.sh routing, which short-circuits on empty stdin (no
#     tool_name to route on) before ever reaching them, so routing through
#     the matrix above does not exercise their own empty-stdin contract.
#     Preserved here via direct invocation, unchanged from the original.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-fold"
SID="hc-fold"
create_event_log "$PROJ/.claude" "$SID" > /dev/null

run_entry "context-flow" "empty" "$PROJ" "$SID"
assert_eq "context_flow_empty_stdin_returns_empty_object" "{}" "$CELL_OUT"

run_entry "pre-dispatch" "empty" "$PROJ" "$SID"
assert_eq "pre_dispatch_empty_stdin_returns_empty_object" "{}" "$CELL_OUT"

set +e
migration_linter_out=$(printf '' | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/migration-linter.sh" 2>/dev/null)
migration_linter_rc=$?
post_edit_out=$(printf '' | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/post-edit-dispatch.sh" 2>/dev/null)
post_edit_rc=$?
post_bash_out=$(printf '' | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/post-bash-dispatch.sh" 2>/dev/null)
post_bash_rc=$?
set -e
assert_eq "migration_linter_empty_stdin_exit_0" "0" "$migration_linter_rc"
assert_eq "migration_linter_empty_stdin_returns_empty_object" "{}" "$migration_linter_out"
assert_eq "post_edit_dispatch_empty_stdin_exit_0" "0" "$post_edit_rc"
assert_eq "post_edit_dispatch_empty_stdin_returns_empty_object" "{}" "$post_edit_out"
assert_eq "post_bash_dispatch_empty_stdin_exit_0" "0" "$post_bash_rc"
assert_eq "post_bash_dispatch_empty_stdin_returns_empty_object" "{}" "$post_bash_out"

export PATH="$SAVED_PATH"
end_suite
