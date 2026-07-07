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

# --- count_events: basic + prefix filter ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-count")
append_event "file_edit" "r C:/a.ts"
append_event "file_edit" "x C:/tmp/notes.md"
append_event "file_edit" "r C:/b.ts"
assert_eq "count_unfiltered" "3" "$(count_events file_edit)"
assert_eq "count_prefix_r_flag" "2" "$(count_events file_edit r)"

# --- count_events: after-anchor (edits since last commit, spec §3.5) ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-anchor")
append_event "file_edit" "r C:/a.ts"
append_event "commit" "abc1234 feat: x"
append_event "file_edit" "r C:/b.ts"
append_event "file_edit" "r C:/c.ts"
assert_eq "count_after_anchor" "2" "$(count_events file_edit r commit)"

# --- count_events: anchor ERE alternation (escape hatch, spec §3.5) ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-ere")
append_event "stop_blocked" "gate1"
append_event "stop_forced" "true"
append_event "stop_blocked" "gate1"
assert_eq "count_anchor_ere_alternation" "1" "$(count_events stop_blocked '' 'stop_approved|stop_forced')"

# --- spec §3.5 required sequence: block, block, pass, block => no force ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-seq")
append_event "stop_blocked" "g1"; append_event "stop_blocked" "g1"
append_event "stop_approved" "true"
append_event "stop_blocked" "g1"
assert_eq "block_block_pass_block_no_force" "1" "$(count_events stop_blocked '' 'stop_approved|stop_forced')"

# --- last_event: empty when absent, last wins ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-last")
assert_eq "last_event_empty_when_absent" "" "$(last_event mode_set)"
append_event "mode_set" "normal boot"
append_event "mode_set" "cautious fix_ratio"
assert_eq "last_event_last_wins" "cautious fix_ratio" "$(last_event mode_set)"

# --- list_events: file order, pipes preserved in values ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-list")
append_event "carry_over" "item with | pipe"
append_event "carry_over" "second"
expected="item with | pipe
second"
assert_eq "list_events_order_and_pipes" "$expected" "$(list_events carry_over)"

# --- malformed lines skipped; CRLF tolerated ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-mal")
printf 'garbage no pipes\n' >> "$EVENT_LOG"
printf '1700000009|file_edit|r C:/crlf.ts\r\n' >> "$EVENT_LOG"
printf '|||\n' >> "$EVENT_LOG"
assert_eq "malformed_skipped_crlf_counted" "1" "$(count_events file_edit)"
assert_eq "crlf_value_clean" "r C:/crlf.ts" "$(last_event file_edit)"

# --- embedded pipes AND CRLF on the same line (interaction) ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-pipecrlf")
printf '1700000010|carry_over|fix a|b handling\r\n' >> "$EVENT_LOG"
assert_eq "pipes_plus_crlf_value" "fix a|b handling" "$(last_event carry_over)"
assert_eq "pipes_plus_crlf_list" "fix a|b handling" "$(list_events carry_over)"

# --- resolve_event_log: pretty-printed JSON (spaces/newlines around keys) ---
TDIR3=$(mktemp -d)
f3=$(create_event_log "$TDIR3/.claude" "sid-pretty")
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR3"
resolve_event_log "$(printf '{\n  "session_id": "sid-pretty",\n  "tool_name": "Bash"\n}')"
assert_eq "resolve_pretty_json" "$f3" "$EVENT_LOG"

# --- resolve_event_log_readonly: falls back to current-session.id for reads ---
mkdir -p "$TDIR3/.claude/cortex"
printf 'sid-pretty\n' > "$TDIR3/.claude/cortex/current-session.id"
resolve_event_log_readonly '{"no_sid":"here"}'
assert_eq "readonly_falls_back_to_marker" "$f3" "$EVENT_LOG"

# --- resolve_event_log (write path): does NOT use the marker fallback ---
resolve_event_log '{"no_sid":"here"}'
assert_eq "write_resolution_never_uses_marker" "" "$EVENT_LOG"
unset CORTEX_PROJECT_DIR_OVERRIDE

end_suite
