#!/usr/bin/env bash
set -euo pipefail

# Singleton-free identity (calibration wave T5, queue item 6).
# Replaces test-native-marker.sh + test-dual-fire.sh: their subject — the
# --native/native-hooks.ok suppression protocol — is deleted (T4 verified the
# bootstrap era's settings.json entries are gone before removing the
# machinery). What must hold NOW: no shared mutable identity file is ever
# created, the sid travels explicitly, and leftover marker files from older
# versions are completely inert.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "singleton-free"

export CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR"
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# --- 1. session-start creates NEITHER singleton and injects the sid ---
setup_test
mark_opted_in "$_TEST_TMPDIR/.claude"
result=$(echo "$(mock_json "session_id=sf-boot")" \
  | CORTEX_PROJECT_DIR="$_TEST_TMPDIR" HOME="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null) || true
assert_eq "boot_creates_no_native_marker" "no" \
  "$([ -f "$_TEST_TMPDIR/.claude/cortex/native-hooks.ok" ] && echo yes || echo no)"
assert_eq "boot_creates_no_current_session_id" "no" \
  "$([ -f "$_TEST_TMPDIR/.claude/cortex/current-session.id" ] && echo yes || echo no)"
assert_contains "boot_injects_explicit_sid" "$result" "Session id: sf-boot"

# --- 2. A dispatcher invoked WITHOUT --native while a leftover marker file
# matches its payload sid proceeds NORMALLY (the old protocol would have
# suppressed it — a leftover marker must change nothing) ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "sf-disp")
printf '4.0.1 2026-07-11T00:00:00Z sf-disp\n' \
  > "$_TEST_TMPDIR/.claude/cortex/native-hooks.ok"
json=$(mock_json "tool_name=Bash" "session_id=sf-disp" "tool_input.command=echo hi")
out=$(echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
  bash "$PLUGIN_ROOT/hooks/scripts/post-dispatch.sh" 2>/dev/null) || true
assert_eq "leftover_marker_does_not_suppress_dispatch" "1" \
  "$(count_events tool_call '' '' "$LOG")"

# --- 3. And with a MISMATCHED leftover marker: identical behavior (the
# marker's content is irrelevant — nothing reads it) ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "sf-disp2")
printf '3.20.0 2026-07-11T00:00:00Z some-other-session\n' \
  > "$_TEST_TMPDIR/.claude/cortex/native-hooks.ok"
json=$(mock_json "tool_name=Bash" "session_id=sf-disp2" "tool_input.command=echo hi")
out=$(echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
  bash "$PLUGIN_ROOT/hooks/scripts/post-dispatch.sh" 2>/dev/null) || true
assert_eq "mismatched_marker_equally_inert" "1" \
  "$(count_events tool_call '' '' "$LOG")"

# --- 4. pre-compact re-injects the sid (compaction survival channel) ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "sf-compact" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/a.ts")
json=$(mock_json "session_id=sf-compact")
out=$(echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
  bash "$PLUGIN_ROOT/hooks/scripts/pre-compact.sh" 2>/dev/null) || true
assert_contains "pre_compact_reinjects_sid" "$out" "Session id: sf-compact"

end_suite
