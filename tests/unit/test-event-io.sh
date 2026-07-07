#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "event-io"

# --- append_event: basic format ---
TDIR=$(mktemp -d)
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-test")
append_event "file_edit" "r C:/Users/x/src/a.ts"
line=$(tail -1 "$EVENT_LOG")
assert_contains "append_basic_value" "$line" "|file_edit|r C:/Users/x/src/a.ts"
is_numeric=no; case "${line%%|*}" in ''|*[!0-9]*) : ;; *) is_numeric=yes ;; esac
assert_eq "append_epoch_numeric" "yes" "$is_numeric"

# --- append_event: silent no-op when log missing (mid-session opt-in inertness) ---
EVENT_LOG="$TDIR/nonexistent/x.events.log"
append_event "file_edit" "r C:/a.ts"     # must not error under set -e
missing=yes; [ -f "$EVENT_LOG" ] && missing=no
assert_eq "append_no_log_is_noop" "yes" "$missing"

# --- append_event: T1 metachar class inert in values ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-meta")
append_event "commit" 'abc1234 fix: a|b & \back $dollar'
assert_contains "append_metachars_inert" "$(tail -1 "$EVENT_LOG")" 'a|b & \back $dollar'

# --- append_event: newline flattening ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-nl")
append_event "carry_over" "$(printf 'line1\nline2')"
assert_eq "append_flattens_newlines" "2" "$(wc -l < "$EVENT_LOG" | tr -d ' ')"
assert_contains "append_flatten_content" "$(tail -1 "$EVENT_LOG")" "line1 line2"

# --- resolve_event_log: finds week-bucket log by session_id ---
TDIR2=$(mktemp -d)
f=$(create_event_log "$TDIR2/.claude" "abc-123")
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR2"
resolve_event_log '{"session_id":"abc-123"}'
assert_eq "resolve_from_session_id" "$f" "$EVENT_LOG"

# --- resolve_event_log: missing session_id => EVENT_LOG empty (appends dropped) ---
resolve_event_log '{"no_sid":"here"}'
assert_eq "resolve_missing_sid_blocks_appends" "" "$EVENT_LOG"
unset CORTEX_PROJECT_DIR_OVERRIDE

end_suite
