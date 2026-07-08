#!/usr/bin/env bash
set -euo pipefail
# Opt-in activation sentinel (spec §4.3): un-opted repos must be fully
# inert. Every gated entry point — the 6 dispatchers, session-start,
# drift-detector.sh, sensory-check.sh, statusline.sh — exits immediately on
# an un-opted project (`.claude/cortex/enabled` FILE absent; directory
# existence is explicitly NOT the signal), with zero filesystem writes.
#
# Scripts are invoked DIRECTLY against the real plugin (not through
# setup_script_sandbox, which unconditionally creates .claude/cortex/sessions
# and would itself violate the "zero directories in an un-opted repo"
# assertion this suite exists to prove). CORTEX_PROJECT_DIR is set inline
# per-invocation so each test gets an isolated project dir.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "opt-in-gate"

# --- Helpers ---

# seed_raw_log <claude_dir> <session_id> [event-lines...]
# Like create_event_log, but deliberately does NOT stamp the opt-in sentinel —
# simulates a "drive-by repo" where .claude/cortex/ already exists (an old
# migrate_state_files/resolve_state_file side effect from before gating
# existed) but /cortex:setup was never run. Proves the gate keys off the
# sentinel FILE specifically, not off directory/session-data existence.
seed_raw_log() {
  local dir="$1" sid="$2"
  shift 2
  mkdir -p "$dir/cortex/sessions/test-week"
  local file="$dir/cortex/sessions/test-week/${sid}.events.log"
  printf '%s|session_start|2026-03-14T00:00:00Z test-model\n' "1700000000" > "$file"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
  echo "$file"
}

# assert_tree_unchanged <label> <before> <after>
assert_tree_unchanged() {
  local label="$1" before="$2" after="$3"
  if [ "$before" = "$after" ]; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$label"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$label"
    printf "          .claude tree changed:\n"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null | sed 's/^/          /' || true
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

# ============================================================================
# Group 1: un-opted repo => every gated entry point is inert (spec §12)
# ============================================================================

# --- pre-dispatch.sh: git-push safety message fires on payload alone (no
# event log needed) — a strong discriminator that the gate, not routing,
# suppressed the output.
setup_test
PROJ="$_TEST_TMPDIR/proj-pre-dispatch"
create_unopted_dir "$PROJ/.claude" > /dev/null
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "tool_name=Bash" "session_id=uo-pre" "tool_input.command=git push origin master")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/pre-dispatch.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "pre_dispatch_unopted_exit_0" "0" "$rc"
assert_eq "pre_dispatch_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "pre_dispatch_unopted_no_new_files" "$before" "$after"

# --- post-dispatch.sh: a Write matching a .claude/exemplars/ pattern would
# normally fire pattern-template.sh's "convention reference" systemMessage
# (test-post-dispatch.sh's missing_event_log_still_routes_to_handlers proves
# this fires with zero event-log state — the ONLY missing ingredient here is
# the sentinel).
setup_test
PROJ="$_TEST_TMPDIR/proj-post-dispatch"
create_unopted_dir "$PROJ/.claude" > /dev/null
mkdir -p "$PROJ/.claude/exemplars"
echo "export const Foo = 1;" > "$PROJ/.claude/exemplars/component.ts"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "tool_name=Write" "session_id=uo-post" "tool_input.file_path=${PROJ}/src/new-file.ts")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/post-dispatch.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "post_dispatch_unopted_exit_0" "0" "$rc"
assert_eq "post_dispatch_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "post_dispatch_unopted_no_new_files" "$before" "$after"

# --- context-flow.sh: "scoring" keyword would normally inject the
# scoring-architecture context file content (pure prompt-driven, no project
# state needed at all).
setup_test
PROJ="$_TEST_TMPDIR/proj-context-flow"
create_unopted_dir "$PROJ/.claude" > /dev/null
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "user_prompt=update the scoring engine" "session_id=uo-ctx")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/context-flow.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "context_flow_unopted_exit_0" "0" "$rc"
assert_eq "context_flow_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "context_flow_unopted_no_new_files" "$before" "$after"

# --- stop-gate.sh: a drive-by repo — .claude/cortex/ already exists (raw log
# seeded WITHOUT the sentinel) with an uncommitted file_edit, which would
# normally block Gate 1 ("Uncommitted changes").
setup_test
PROJ="$_TEST_TMPDIR/proj-stop-gate"
create_unopted_dir "$PROJ/.claude" > /dev/null
seed_raw_log "$PROJ/.claude" "uo-stop" "1700000001|file_edit|r src/lib/foo.ts" > /dev/null
before=$(find "$PROJ/.claude" | sort)
set +e
result=$(printf '%s' "{\"session_id\":\"uo-stop\"}" | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/stop-gate.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "stop_gate_unopted_exit_0" "0" "$rc"
assert_eq "stop_gate_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "stop_gate_unopted_no_new_files" "$before" "$after"

# --- session-end-dispatch.sh: a drive-by repo with a raw log + journal
# reasoning-miss tag would normally write health.local.md + cross-session.
# local.md. Output is "{}" on the happy path too, so the file-tree assertion
# is the real discriminator here.
setup_test
PROJ="$_TEST_TMPDIR/proj-session-end"
create_unopted_dir "$PROJ/.claude" > /dev/null
seed_raw_log "$PROJ/.claude" "uo-end" "1700000001|file_edit|r src/lib/foo.ts" > /dev/null
create_journal "$PROJ" "$(date +%Y-%m-%d)"
before=$(find "$PROJ/.claude" | sort)
set +e
result=$(printf '%s' "{\"session_id\":\"uo-end\"}" | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/session-end-dispatch.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "session_end_unopted_exit_0" "0" "$rc"
assert_eq "session_end_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "session_end_unopted_no_new_files" "$before" "$after"

# --- pre-compact.sh: ANY resolvable event log (even just the session_start
# line) always produces a non-{} "[PRE-COMPACT CONTEXT PRESERVATION]"
# systemMessage on the happy path — a clean discriminator.
setup_test
PROJ="$_TEST_TMPDIR/proj-pre-compact"
create_unopted_dir "$PROJ/.claude" > /dev/null
seed_raw_log "$PROJ/.claude" "uo-compact" > /dev/null
before=$(find "$PROJ/.claude" | sort)
set +e
result=$(printf '%s' "{\"session_id\":\"uo-compact\"}" | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/pre-compact.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "pre_compact_unopted_exit_0" "0" "$rc"
assert_eq "pre_compact_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "pre_compact_unopted_no_new_files" "$before" "$after"

# --- drift-detector.sh: forced to the process.env check (mocked day-of-year,
# even) with a real violation present — would normally report "Drift: ...".
# Also proves drift-detector.sh's own sourcing no longer side-effects a
# cortex/ dir into existence (it used to source state-io.sh, whose
# migrate_state_files() runs unconditionally at source time).
setup_test
PROJ="$_TEST_TMPDIR/proj-drift"
create_unopted_dir "$PROJ/.claude" > /dev/null
mkdir -p "$PROJ/src/lib"
echo 'const key = process.env.SECRET_KEY;' > "$PROJ/src/lib/bad.ts"
create_mock_date "$MOCK_BIN" "2"
before=$(find "$PROJ/.claude" | sort)
set +e
result=$(printf '%s' '{}' | CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/drift-detector.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "drift_detector_unopted_exit_0" "0" "$rc"
assert_eq "drift_detector_unopted_returns_empty" "{}" "$result"
assert_tree_unchanged "drift_detector_unopted_no_new_files" "$before" "$after"

# --- sensory-check.sh: language detection (Check 4) fires on filesystem
# state alone, no git/gh/session needed — would normally print "Python
# project detected." Plain-text surface: empty output, not "{}".
setup_test
PROJ="$_TEST_TMPDIR/proj-sensory"
create_unopted_dir "$PROJ/.claude" > /dev/null
echo "[project]" > "$PROJ/pyproject.toml"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "session_id=uo-sensory")
set +e
result=$(CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/sensory-check.sh" "$json" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "sensory_check_unopted_exit_0" "0" "$rc"
assert_eq "sensory_check_unopted_returns_empty" "" "$result"
assert_tree_unchanged "sensory_check_unopted_no_new_files" "$before" "$after"

# --- statusline.sh: with no gate, ALWAYS prints two lines of graceful
# defaults (proven by test-statusline.sh's own "no event log" test) — the
# clearest possible discriminator. Also proves statusline needs its OWN gate
# even though it's only reachable indirectly via already-gated dispatchers in
# the hook path — /status invokes it directly.
setup_test
PROJ="$_TEST_TMPDIR/proj-statusline"
create_unopted_dir "$PROJ/.claude" > /dev/null
before=$(find "$PROJ/.claude" | sort)
set +e
result=$(CORTEX_PROJECT_DIR="$PROJ" bash "$PLUGIN_ROOT/hooks/scripts/statusline.sh" "{\"session_id\":\"uo-status\"}" < /dev/null 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "statusline_unopted_exit_0" "0" "$rc"
assert_eq "statusline_unopted_returns_empty" "" "$result"
assert_tree_unchanged "statusline_unopted_no_new_files" "$before" "$after"

# --- session-start: truly fresh repo (no health file at all) — the biggest
# side-effect surface of any entry point (event log, current-session.id
# marker, mode_set/threshold_set events, bootstrap-hooks.sh) must ALL be
# suppressed. HOME is redirected so a would-be bootstrap-hooks.sh write
# cannot touch the real ~/.claude/settings.json if the gate ever regresses.
setup_test
PROJ="$_TEST_TMPDIR/proj-session-start-fresh"
create_unopted_dir "$PROJ/.claude" > /dev/null
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "session_id=uo-fresh")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" HOME="$PROJ" bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "session_start_fresh_exit_0" "0" "$rc"
assert_eq "session_start_fresh_returns_empty" "{}" "$result"
assert_tree_unchanged "session_start_fresh_no_new_files" "$before" "$after"

# ============================================================================
# Group 2: session-start grandfathering (spec §4.3)
# ============================================================================

# --- Grandfathering succeeds: health.local.md has >=1 real data row (proof
# of prior use predating opt-in gating) — sentinel is auto-created and
# session-start proceeds with its normal output.
setup_test
PROJ="$_TEST_TMPDIR/proj-ss-grandfather"
create_unopted_dir "$PROJ/.claude" > /dev/null
mkdir -p "$PROJ/.claude/cortex"
create_health_file "$PROJ/.claude/cortex/health.local.md" \
  "2026-07-01|0|1.0|true|0|0|0|0|10|1|focused|proj"
SENTINEL="$PROJ/.claude/cortex/enabled"
json=$(mock_json "session_id=uo-grandfather")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" HOME="$PROJ" bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null)
rc=$?
set -e
assert_eq "grandfather_exit_0" "0" "$rc"
assert_file_exists "grandfather_creates_sentinel" "$SENTINEL"
assert_contains "grandfather_sentinel_has_enabled_marker" "$(cat "$SENTINEL" 2>/dev/null)" "enabled "
assert_json_valid "grandfather_output_valid_json" "$result"
assert_contains "grandfather_proceeds_normally" "$result" "cortex-session-start"

# --- Grandfathering does NOT trigger on a header-only health file (zero data
# rows — the "# Fields: ...|...|..." header comment itself contains pipes,
# so the check must scope to content AFTER the "---" separator, not just
# grep -q '|' over the whole file). Gate fires: {}, no sentinel, no new files.
setup_test
PROJ="$_TEST_TMPDIR/proj-ss-headeronly"
create_unopted_dir "$PROJ/.claude" > /dev/null
mkdir -p "$PROJ/.claude/cortex"
create_health_file "$PROJ/.claude/cortex/health.local.md"
SENTINEL="$PROJ/.claude/cortex/enabled"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "session_id=uo-headeronly")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" HOME="$PROJ" bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "headeronly_exit_0" "0" "$rc"
assert_eq "headeronly_returns_empty" "{}" "$result"
assert_eq "headeronly_no_sentinel_created" "no" "$([ -f "$SENTINEL" ] && echo yes || echo no)"
assert_tree_unchanged "headeronly_no_new_files" "$before" "$after"

export PATH="$SAVED_PATH"
end_suite
