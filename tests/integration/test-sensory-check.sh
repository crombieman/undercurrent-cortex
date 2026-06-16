#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/state-io.sh"

begin_suite "sensory-check"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# Set up MOCK_BIN at suite level to avoid subshell PATH issues
MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"

# sensory-check.sh calls resolve_state_file "" (no JSON input), which searches
# session-scoped files in SESSIONS_DIR. Tests 3+6 need STATE_FILE to be found,
# so they use create_state_file (session-scoped). Tests 1,2,4,5 don't depend on
# STATE_FILE resolution, so legacy files are fine.

# Test 1: Clean state, CI success — does NOT contain "CI FAILED"
setup_test
create_legacy_state_file "$_TEST_TMPDIR/.claude" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" 2>/dev/null || true)
assert_not_contains "clean_no_ci_failure" "$result" "CI FAILED"

# Test 2: CI failure — contains "CI FAILED"
setup_test
create_legacy_state_file "$_TEST_TMPDIR/.claude" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" 2>/dev/null || true)
assert_contains "ci_failure_reported" "$result" "CI FAILED"

# Test 3: Mid-session cooldown active — empty output
setup_test
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "sensory-cooldown" "last_sensory_check=${now_iso}")
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" --mid-session 2>/dev/null || true)
assert_eq "mid_session_cooldown_skips" "" "$result"

# Test 4: Full scan (no --mid-session) ignores cooldown — still shows CI failure
setup_test
sf=$(create_legacy_state_file "$_TEST_TMPDIR/.claude")
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sed -i "s|^\[files_modified\]|last_sensory_check=${now_iso}\n\n[files_modified]|" "$sf"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" 2>/dev/null || true)
assert_contains "full_scan_ignores_cooldown" "$result" "CI FAILED"

# Test 5: No gh command — graceful, no crash, no "CI FAILED"
setup_test
create_legacy_state_file "$_TEST_TMPDIR/.claude" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
hide_command "$MOCK_BIN" "gh"
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" 2>/dev/null || true)
assert_not_contains "no_gh_graceful" "$result" "CI FAILED"

# Test 6: Writes last_sensory_check timestamp to state file
setup_test
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "sensory-ts")
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"
bash "$SANDBOX/hooks/scripts/sensory-check.sh" 2>/dev/null || true
timestamp=$(grep '^last_sensory_check=' "$sf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')
if [ -n "$timestamp" ] && [ "$timestamp" != "" ]; then
  printf "    ${_GREEN}PASS${_RESET}  %s\n" "writes_timestamp_to_state"
  _PASS_COUNT=$((_PASS_COUNT + 1))
else
  printf "    ${_RED}FAIL${_RESET}  %s\n" "writes_timestamp_to_state"
  printf "          expected non-empty timestamp, got: '%s'\n" "$timestamp"
  _FAIL_COUNT=$((_FAIL_COUNT + 1))
fi

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
create_legacy_state_file "$_TEST_TMPDIR/.claude" > /dev/null
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "failure"
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
result=$(bash "$SANDBOX/hooks/scripts/sensory-check.sh" 2>/dev/null || true)
assert_not_contains "no_coreutils_timeout_skips_ci_check" "$result" "CI FAILED"
assert_file_not_contains "no_coreutils_timeout_skips_git_fetch" "$MOCK_BIN/git.calls" "fetch"
assert_file_not_contains "non_coreutils_timeout_never_runs_command" "$MOCK_BIN/timeout.calls" "gh"
rm -f "$MOCK_BIN/timeout" "$MOCK_BIN/timeout.calls"

export PATH="$SAVED_PATH"
end_suite
