#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "health-dedup"

# Helper: run session-end-dispatch directly against the event log (no
# sandbox — event-io resolves the project dir lazily via
# CORTEX_PROJECT_DIR_OVERRIDE).
run_session_end() {
  local sid="$1"
  echo "{\"session_id\":\"${sid}\"}" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/scripts/session-end-dispatch.sh" 2>/dev/null || true
}

# Helper: count data rows in a health file (excludes header/comment lines)
count_health_rows() {
  local health_file="$1"
  local data_rows=0
  if [ -f "$health_file" ]; then
    data_rows=$(grep -c '|' "$health_file" | tr -d ' ')
    header_pipes=$(grep -c '^# Fields:' "$health_file" || true)
    data_rows=$((data_rows - header_pipes))
  fi
  echo "$data_rows"
}

# Test 1: no health_written event yet → second call blocked (only 1 data
# row after 2 calls). Same session fires twice — the flag now lives as a
# health_written event in the session's own log, not a state-file field.
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "dedup-test" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
mkdir -p "$_TEST_TMPDIR/memory"
echo "# Journal" > "$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
# First call — writes health row and appends health_written event
run_session_end "dedup-test" > /dev/null
# Second call — should be blocked by the health_written event
run_session_end "dedup-test" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_eq "health_dedup_one_row" "1" "$(count_health_rows "$health_file")"

# Test 2: no health_written event → first call allows the write
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "allow-write" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts" > /dev/null
mkdir -p "$_TEST_TMPDIR/memory"
echo "# Journal" > "$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
run_session_end "allow-write" > /dev/null
health_file="$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_file_exists "health_file_created" "$health_file"
result=$([ "$(count_health_rows "$health_file")" -ge 1 ] && echo "yes" || echo "no")
assert_eq "health_written_false_allows" "yes" "$result"

# Test 3: missing health_written event gets appended after a write
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "missing-field" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/a.ts")
mkdir -p "$_TEST_TMPDIR/memory"
echo "# Journal" > "$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
run_session_end "missing-field" > /dev/null
hw=$(count_events health_written '' '' "$LOG")
assert_eq "health_written_event_added" "1" "$hw"

end_suite
