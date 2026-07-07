#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
EIO="$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"
source "$EIO"

begin_suite "concurrent-appends"

tdir=$(mktemp -d)
log=$(create_event_log "$tdir/.claude" "s-conc")

# 50 SEPARATE processes (distinct PIDs — faithful to real async hook fires).
# The v3 read-modify-write path scored 4/50 on this exact scenario (proven 2026-07-06).
for i in $(seq 1 50); do
  bash -c 'source "$1"; append_event tool_call "Bash" "$2"' _ "$EIO" "$log" &
done
wait

EVENT_LOG="$log"
assert_eq "fifty_concurrent_appends" "50" "$(count_events tool_call)"

# No torn lines: every line parses. (grep -c discipline: -q guard first.)
malformed=0
if grep -qvE '^[0-9]+\|[a-z_]+\|' "$log"; then
  malformed=$(grep -cvE '^[0-9]+\|[a-z_]+\|' "$log")
fi
assert_eq "zero_torn_lines" "0" "$malformed"

end_suite
