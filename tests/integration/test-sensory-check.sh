#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "sensory-check"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell — event-io.sh
# resolves the project dir from this env var at call time, so it must be set
# here explicitly (pattern: tests/integration/test-post-dispatch.sh:22).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Set up MOCK_BIN at suite level to avoid subshell PATH issues
MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"

# Helper: hook JSON carrying only session_id (sensory-check's write-path
# resolution requires this; the read-path falls back to current-session.id
# when it's absent — see the no-json test below).
sensory_json() {
  mock_json "session_id=$1"
}

# sensory-check.sh now takes the hook JSON as its final arg (after the
# optional --mid-session flag): sensory-check.sh [--mid-session] [hook_json].
# Tests seed a session-scoped event log via create_event_log and pass its
# session_id through so reads/writes resolve to that log directly.

# Test 1: Clean state, CI success — does NOT contain "CI FAILED"
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sensory-clean" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"
json=$(sensory_json "sensory-clean")
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" "$json" 2>/dev/null || true)
assert_not_contains "clean_no_ci_failure" "$result" "CI FAILED"

# Test 2: CI failure — contains "CI FAILED"
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sensory-cifail" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
json=$(sensory_json "sensory-cifail")
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" "$json" 2>/dev/null || true)
assert_contains "ci_failure_reported" "$result" "CI FAILED"

# Test 3: Mid-session cooldown active (last sensory_check event <5 min ago) — empty output
setup_test
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
create_event_log "$_TEST_TMPDIR/.claude" "sensory-cooldown" \
  "1700000001|sensory_check|${now_iso}" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
json=$(sensory_json "sensory-cooldown")
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" --mid-session "$json" 2>/dev/null || true)
assert_eq "mid_session_cooldown_skips" "" "$result"

# Test 4: Full scan (no --mid-session) ignores cooldown — still shows CI failure
setup_test
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
create_event_log "$_TEST_TMPDIR/.claude" "sensory-fullscan" \
  "1700000001|sensory_check|${now_iso}" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
json=$(sensory_json "sensory-fullscan")
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" "$json" 2>/dev/null || true)
assert_contains "full_scan_ignores_cooldown" "$result" "CI FAILED"

# Test 5: No gh command — graceful, no crash, no "CI FAILED"
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sensory-nogh" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
hide_command "$MOCK_BIN" "gh"
json=$(sensory_json "sensory-nogh")
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" "$json" 2>/dev/null || true)
assert_not_contains "no_gh_graceful" "$result" "CI FAILED"

# Test 6: Writes a sensory_check event to the event log
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "sensory-ts")
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"
json=$(sensory_json "sensory-ts")
bash "$SANDBOX/hooks/scripts/sensory-check.sh" "$json" > /dev/null 2>/dev/null || true
timestamp=$(last_event sensory_check "$LOG")
if [ -n "$timestamp" ]; then
  printf "    ${_GREEN}PASS${_RESET}  %s\n" "writes_timestamp_to_event_log"
  _PASS_COUNT=$((_PASS_COUNT + 1))
else
  printf "    ${_RED}FAIL${_RESET}  %s\n" "writes_timestamp_to_event_log"
  printf "          expected non-empty timestamp, got: '%s'\n" "$timestamp"
  _FAIL_COUNT=$((_FAIL_COUNT + 1))
fi

# Test 6b: Called without hook JSON at all (session-start's current call
# shape — converted in a later task). Appends must be skipped (no
# attributable session), but the script must still produce output and must
# not crash.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "sensory-nojson")
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"
bash "$SANDBOX/hooks/scripts/sensory-check.sh" > /dev/null 2>/dev/null || true
after=$(count_events sensory_check '' '' "$LOG")
assert_eq "no_json_skips_sensory_check_append" "0" "$after"

# Test 6c: Called without hook JSON while a LEFTOVER current-session.id file
# exists — the marker fallback is DELETED (calibration T5): the file is
# ignored, no sid resolves, and the contract that matters holds: exit 0 and
# ZERO event appends (a sid-less invocation can never write into another
# session's log — exactly the guest-clobber incident class this kills).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "sensory-marker" \
  "1700000001|sensory_check|$(date -u +%Y-%m-%dT%H:%M:%SZ)")
printf 'sensory-marker' > "$_TEST_TMPDIR/.claude/cortex/current-session.id"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
before_appends=$(count_events sensory_check '' '' "$LOG")
rc=0
bash "$SANDBOX/hooks/scripts/sensory-check.sh" --mid-session >/dev/null 2>&1 || rc=$?
after_appends=$(count_events sensory_check '' '' "$LOG")
assert_eq "leftover_marker_exit_zero" "0" "$rc"
assert_eq "leftover_marker_no_append_to_other_session" "$before_appends" "$after_appends"
rm -f "$_TEST_TMPDIR/.claude/cortex/current-session.id"

# Test 7: Anti-hang regression guard — without GNU coreutils `timeout`, network
# calls must be SKIPPED, never run unbounded.
# Root-cause defense for frozen SessionStart hooks: run_with_timeout must reject
# a non-coreutils `timeout` (e.g. Windows timeout.exe shadowing GNU on PATH) and
# skip the call — NOT run it through the wrong `timeout`, and NOT fall back to an
# unbounded `"$@"` that can hang Claude Code forever.
# Discriminator: with gh mocked as FAILURE, correct code skips gh entirely so
# "CI FAILED" never appears; either regression (dropping the coreutils check, or
# restoring the unbounded fallback) re-runs gh and the assertions go red.
# Positive control: Test 2 proves real GNU timeout DOES surface "CI FAILED".
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "sensory-timeout" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
json=$(sensory_json "sensory-timeout")
# Shadow `timeout` with a non-coreutils impl. If a regression ever routes a real
# command through it, it EXECs that command so the breach is observable in the
# .calls logs (and as "CI FAILED" in the output).
cat > "$MOCK_BIN/timeout" << TIMEOUTEOF
#!/usr/bin/env bash
echo "timeout \$*" >> "$MOCK_BIN/timeout.calls"
if [ "\$1" = "--version" ]; then
  echo "mock-timeout (not-gnu) 0.0"   # deliberately NOT coreutils
  exit 0
fi
[ "\$1" = "-k" ] && shift 2            # drop -k <n>
shift                                  # drop <seconds>
exec "\$@"
TIMEOUTEOF
chmod +x "$MOCK_BIN/timeout"
# Reset cumulative call logs (mocks append; MOCK_BIN persists across the suite)
# so assertions reflect only THIS invocation.
rm -f "$MOCK_BIN/git.calls" "$MOCK_BIN/gh.calls" "$MOCK_BIN/timeout.calls"
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" "$json" 2>/dev/null || true)
assert_not_contains "no_coreutils_timeout_skips_ci_check" "$result" "CI FAILED"
assert_file_not_contains "no_coreutils_timeout_skips_git_fetch" "$MOCK_BIN/git.calls" "fetch"
assert_file_not_contains "non_coreutils_timeout_never_runs_command" "$MOCK_BIN/timeout.calls" "gh"
rm -f "$MOCK_BIN/timeout" "$MOCK_BIN/timeout.calls"

export PATH="$SAVED_PATH"
end_suite
