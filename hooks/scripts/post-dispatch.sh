#!/usr/bin/env bash
set -euo pipefail
# Unified PostToolUse dispatcher — routes to sub-handlers by tool_name.
# Plugin hooks.json registers this with NO matcher (fires on all PostToolUse).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }

# Buffer stdin ONCE
INPUT=$(cat)

# Resolve session-scoped event log
resolve_event_log "$INPUT"

# Extract tool_name for routing (needed regardless of whether the event log
# resolved — routing is the dispatcher's job even without an attributable
# session; sub-handlers guard their own state).
tool_name=$(printf '%s' "$INPUT" | extract_json_field "tool_name")

# Record the tool call + mid-session checkpoint only when the event log
# resolved. journal_edit events (Task 2, post-edit-dispatch.sh) are the
# checkpoint anchor — no reset write needed here.
if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
  append_event "tool_call" "$tool_name"

  # Mid-session checkpoint every 25 tool uses since the last journal entry
  uses=$(count_events tool_call '' journal_edit)
  if [ "$uses" -gt 0 ] && [ $((uses % 25)) -eq 0 ]; then
    source "$SCRIPT_DIR/lib/escape-json.sh" || true
    checkpoint=$(escape_for_json "📝 Mid-session checkpoint (${uses} tool uses since last journal entry): consider adding a journal entry to memory/YYYY-MM-DD.md. What's the current state of the work?")
    printf '{"systemMessage":"%s"}' "$checkpoint"
    exit 0
  fi
fi

case "$tool_name" in
  Bash)
    printf '%s' "$INPUT" | "$SCRIPT_DIR/post-bash-dispatch.sh"
    ;;
  Write|Edit)
    printf '%s' "$INPUT" | "$SCRIPT_DIR/post-edit-dispatch.sh"
    # For Write, also run pattern-template
    if [ "$tool_name" = "Write" ]; then
      printf '%s' "$INPUT" | "$SCRIPT_DIR/pattern-template.sh" 2>/dev/null || true
    fi
    ;;
  *)
    printf '{}'
    ;;
esac
exit 0
