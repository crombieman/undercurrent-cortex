#!/usr/bin/env bash
set -euo pipefail
# Native hooks marker protocol (Task 5, spec §4.2). Proves the --native flag +
# native-hooks.ok marker suppress the stale ~/.claude/settings.json
# bootstrap-hooks.sh entry once hooks.json's native registration is active for
# the session, while a compat window (no marker yet) keeps every dispatcher
# behaving normally. Covers post-dispatch, stop-gate, context-flow (brief's
# "at minimum" set) plus session-start's marker-writing contract.
#
# Scripts are invoked DIRECTLY against the real plugin (not through
# setup_script_sandbox — mirrors tests/integration/test-opt-in-gate.sh, whose
# comment explains why: the sandbox unconditionally creates .claude/cortex/
# session state, which would muddy the "marker present/absent" discriminator
# this suite exists to prove). CORTEX_PROJECT_DIR is set inline per-invocation.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "native-marker"

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

# stamp_native_marker <claude_dir> [session_id]
# Writes native-hooks.ok in the real "<version> <utc-iso> <session_id>" shape
# session-start now writes (Codex I-2). WITH a session_id 3rd token, a
# non-native dispatcher suppresses ONLY when that sid matches its payload's sid.
# OMIT the sid to reproduce a LEGACY 2-token marker (pre-I-2 shape), which must
# NOT suppress — presence is no longer sufficient.
stamp_native_marker() {
  local claude_dir="$1" sid="${2:-}"
  mkdir -p "$claude_dir/cortex"
  if [ -n "$sid" ]; then
    printf '3.18.1 2026-07-08T00:00:00Z %s\n' "$sid" > "$claude_dir/cortex/native-hooks.ok"
  else
    printf '3.18.1 2026-07-08T00:00:00Z\n' > "$claude_dir/cortex/native-hooks.ok"
  fi
}

# ============================================================================
# Group 1: post-dispatch.sh — event-append discriminator (tool_call count)
# ============================================================================

run_post_dispatch() {
  local proj="$1" json="$2"
  shift 2
  printf '%s' "$json" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/post-dispatch.sh" "$@" 2>/dev/null || true
}

# (a) WITHOUT --native + marker present with MATCHING sid => {} and NO event
# appended (this session's native registration is proven alive).
setup_test
PROJ="$_TEST_TMPDIR/proj-pd-a"
LOG=$(create_event_log "$PROJ/.claude" "pd-a")
stamp_native_marker "$PROJ/.claude" "pd-a"
before=$(count_events tool_call '' '' "$LOG")
json=$(mock_json "tool_name=Bash" "session_id=pd-a" "tool_input.command=echo hi")
result=$(run_post_dispatch "$PROJ" "$json")
after=$(count_events tool_call '' '' "$LOG")
assert_eq "post_dispatch_no_native_marker_suppressed_returns_empty" "{}" "$result"
assert_eq "post_dispatch_no_native_marker_suppressed_no_event_appended" "$before" "$after"

# (b) WITHOUT --native + NO marker => normal behavior (tool_call appended)
setup_test
PROJ="$_TEST_TMPDIR/proj-pd-b"
LOG=$(create_event_log "$PROJ/.claude" "pd-b")
before=$(count_events tool_call '' '' "$LOG")
json=$(mock_json "tool_name=Bash" "session_id=pd-b" "tool_input.command=echo hi")
result=$(run_post_dispatch "$PROJ" "$json")
after=$(count_events tool_call '' '' "$LOG")
assert_eq "post_dispatch_no_native_no_marker_normal_behavior" "1" "$((after - before))"

# (c) WITH --native + marker present => normal behavior (tool_call appended)
setup_test
PROJ="$_TEST_TMPDIR/proj-pd-c"
LOG=$(create_event_log "$PROJ/.claude" "pd-c")
stamp_native_marker "$PROJ/.claude" "pd-c"
before=$(count_events tool_call '' '' "$LOG")
json=$(mock_json "tool_name=Bash" "session_id=pd-c" "tool_input.command=echo hi")
result=$(run_post_dispatch "$PROJ" "$json" --native)
after=$(count_events tool_call '' '' "$LOG")
assert_eq "post_dispatch_native_marker_present_normal_behavior" "1" "$((after - before))"

# (d) WITHOUT --native + marker present but MISMATCHED sid => normal behavior
# (Codex I-2): the marker proves a DIFFERENT session's native registration, not
# this one's — presence must NOT suppress. tool_call appended.
setup_test
PROJ="$_TEST_TMPDIR/proj-pd-d"
LOG=$(create_event_log "$PROJ/.claude" "pd-d")
stamp_native_marker "$PROJ/.claude" "some-other-session"
before=$(count_events tool_call '' '' "$LOG")
json=$(mock_json "tool_name=Bash" "session_id=pd-d" "tool_input.command=echo hi")
result=$(run_post_dispatch "$PROJ" "$json")
after=$(count_events tool_call '' '' "$LOG")
assert_eq "post_dispatch_mismatched_sid_not_suppressed" "1" "$((after - before))"

# (e) WITHOUT --native + LEGACY 2-token marker (no sid) => normal behavior
# (Codex I-2): a pre-I-2 marker shape cannot prove same-session liveness, so it
# must NOT suppress. tool_call appended.
setup_test
PROJ="$_TEST_TMPDIR/proj-pd-e"
LOG=$(create_event_log "$PROJ/.claude" "pd-e")
stamp_native_marker "$PROJ/.claude"   # no sid => legacy 2-token shape
before=$(count_events tool_call '' '' "$LOG")
json=$(mock_json "tool_name=Bash" "session_id=pd-e" "tool_input.command=echo hi")
result=$(run_post_dispatch "$PROJ" "$json")
after=$(count_events tool_call '' '' "$LOG")
assert_eq "post_dispatch_legacy_marker_not_suppressed" "1" "$((after - before))"

# ============================================================================
# Group 2: stop-gate.sh — block-decision discriminator (Gate 1: uncommitted)
# ============================================================================

run_stop_gate() {
  local proj="$1" sid="$2"
  shift 2
  echo "{\"session_id\":\"${sid}\"}" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/stop-gate.sh" "$@" 2>/dev/null || true
}

# (a) WITHOUT --native + marker present => {} (block suppressed)
setup_test
PROJ="$_TEST_TMPDIR/proj-sg-a"
LOG=$(create_event_log "$PROJ/.claude" "sg-a")
seed_file_edit "$LOG" "r" "${PROJ}/src/lib/foo.ts"
stamp_native_marker "$PROJ/.claude" "sg-a"
before=$(count_events stop_blocked '' '' "$LOG")
result=$(run_stop_gate "$PROJ" "sg-a")
after=$(count_events stop_blocked '' '' "$LOG")
assert_eq "stop_gate_no_native_marker_suppressed_returns_empty" "{}" "$result"
assert_eq "stop_gate_no_native_marker_suppressed_no_event_appended" "$before" "$after"

# (b) WITHOUT --native + NO marker => normal behavior (blocks on uncommitted changes)
setup_test
PROJ="$_TEST_TMPDIR/proj-sg-b"
LOG=$(create_event_log "$PROJ/.claude" "sg-b")
seed_file_edit "$LOG" "r" "${PROJ}/src/lib/foo.ts"
result=$(run_stop_gate "$PROJ" "sg-b")
assert_contains "stop_gate_no_native_no_marker_normal_behavior" "$result" "block"

# (c) WITH --native + marker present => normal behavior (blocks on uncommitted changes)
setup_test
PROJ="$_TEST_TMPDIR/proj-sg-c"
LOG=$(create_event_log "$PROJ/.claude" "sg-c")
seed_file_edit "$LOG" "r" "${PROJ}/src/lib/foo.ts"
stamp_native_marker "$PROJ/.claude" "sg-c"
result=$(run_stop_gate "$PROJ" "sg-c" --native)
assert_contains "stop_gate_native_marker_present_normal_behavior" "$result" "block"

# (d) WITHOUT --native + marker present but MISMATCHED sid => normal behavior
# (Codex I-2): block fires (not suppressed) because the marker proves a
# different session's native registration, not this one's.
setup_test
PROJ="$_TEST_TMPDIR/proj-sg-d"
LOG=$(create_event_log "$PROJ/.claude" "sg-d")
seed_file_edit "$LOG" "r" "${PROJ}/src/lib/foo.ts"
stamp_native_marker "$PROJ/.claude" "some-other-session"
result=$(run_stop_gate "$PROJ" "sg-d")
assert_contains "stop_gate_mismatched_sid_not_suppressed" "$result" "block"

# ============================================================================
# Group 3: context-flow.sh — systemMessage discriminator ("[decision]" prompt,
# a pure prompt-logic branch independent of the context/*.md keyword files)
# ============================================================================

run_context_flow() {
  local proj="$1" json="$2"
  shift 2
  printf '%s' "$json" | CORTEX_PROJECT_DIR="$proj" bash "$PLUGIN_ROOT/hooks/scripts/context-flow.sh" "$@" 2>/dev/null || true
}

# (a) WITHOUT --native + marker present => {} (decision message suppressed)
setup_test
PROJ="$_TEST_TMPDIR/proj-cf-a"
create_event_log "$PROJ/.claude" "cf-a" > /dev/null
stamp_native_marker "$PROJ/.claude" "cf-a"
json=$(mock_json "user_prompt=[decision] use Postgres for this" "session_id=cf-a")
result=$(run_context_flow "$PROJ" "$json")
assert_eq "context_flow_no_native_marker_suppressed_returns_empty" "{}" "$result"

# (b) WITHOUT --native + NO marker => normal behavior (decision message fires)
setup_test
PROJ="$_TEST_TMPDIR/proj-cf-b"
create_event_log "$PROJ/.claude" "cf-b" > /dev/null
json=$(mock_json "user_prompt=[decision] use Postgres for this" "session_id=cf-b")
result=$(run_context_flow "$PROJ" "$json")
assert_contains "context_flow_no_native_no_marker_normal_behavior" "$result" "Decision detected"

# (c) WITH --native + marker present => normal behavior (decision message fires)
setup_test
PROJ="$_TEST_TMPDIR/proj-cf-c"
create_event_log "$PROJ/.claude" "cf-c" > /dev/null
stamp_native_marker "$PROJ/.claude" "cf-c"
json=$(mock_json "user_prompt=[decision] use Postgres for this" "session_id=cf-c")
result=$(run_context_flow "$PROJ" "$json" --native)
assert_contains "context_flow_native_marker_present_normal_behavior" "$result" "Decision detected"

# (d) WITHOUT --native + marker present but MISMATCHED sid => normal behavior
# (Codex I-2): decision message fires (not suppressed).
setup_test
PROJ="$_TEST_TMPDIR/proj-cf-d"
create_event_log "$PROJ/.claude" "cf-d" > /dev/null
stamp_native_marker "$PROJ/.claude" "some-other-session"
json=$(mock_json "user_prompt=[decision] use Postgres for this" "session_id=cf-d")
result=$(run_context_flow "$PROJ" "$json")
assert_contains "context_flow_mismatched_sid_not_suppressed" "$result" "Decision detected"

# ============================================================================
# Group 4: session-start — writes native-hooks.ok with plugin-version first token
# ============================================================================

EXPECTED_PLUGIN_VERSION=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -1)

setup_test
PROJ="$_TEST_TMPDIR/proj-ss-marker"
mkdir -p "$PROJ/.claude/cortex"
touch "$PROJ/.claude/cortex/enabled"
json=$(mock_json "session_id=ss-marker-test")
printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" HOME="$PROJ" bash "$PLUGIN_ROOT/hooks/session-start" > /dev/null 2>&1 || true
MARKER="$PROJ/.claude/cortex/native-hooks.ok"
assert_file_exists "session_start_writes_native_marker" "$MARKER"
marker_version=""
[ -f "$MARKER" ] && marker_version=$(cut -d' ' -f1 "$MARKER" | tr -d '\r\n')
assert_eq "session_start_marker_first_token_is_plugin_version" "$EXPECTED_PLUGIN_VERSION" "$marker_version"
# Codex I-2: the marker's 3rd token is THIS session's session_id, so a
# same-session non-native dispatcher can prove native registration is alive.
marker_sid=""
[ -f "$MARKER" ] && marker_sid=$(awk 'NR==1{print $3}' "$MARKER" | tr -d '\r\n')
assert_eq "session_start_marker_third_token_is_session_id" "ss-marker-test" "$marker_sid"

# Overwrite semantics: a second session-start run replaces (not appends to) the marker.
setup_test
PROJ="$_TEST_TMPDIR/proj-ss-marker-overwrite"
mkdir -p "$PROJ/.claude/cortex"
touch "$PROJ/.claude/cortex/enabled"
json1=$(mock_json "session_id=ss-marker-overwrite-1")
printf '%s' "$json1" | CORTEX_PROJECT_DIR="$PROJ" HOME="$PROJ" bash "$PLUGIN_ROOT/hooks/session-start" > /dev/null 2>&1 || true
json2=$(mock_json "session_id=ss-marker-overwrite-2")
printf '%s' "$json2" | CORTEX_PROJECT_DIR="$PROJ" HOME="$PROJ" bash "$PLUGIN_ROOT/hooks/session-start" > /dev/null 2>&1 || true
MARKER2="$PROJ/.claude/cortex/native-hooks.ok"
line_count=$(wc -l < "$MARKER2" | tr -d ' ')
assert_eq "session_start_marker_overwritten_not_appended" "1" "$line_count"

export PATH="$SAVED_PATH"
end_suite
