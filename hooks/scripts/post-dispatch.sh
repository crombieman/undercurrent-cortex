#!/usr/bin/env bash
set -euo pipefail
# Unified PostToolUse dispatcher — routes to sub-handlers by tool_name.
# Plugin hooks.json registers this with NO matcher (fires on all PostToolUse).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }

# --native flag (Task 5: native hooks.json registration): consumed before any
# other arg handling. Its ABSENCE plus the native-hooks.ok marker (written
# every session by session-start once its opt-in gate passes) means this
# invocation is the stale ~/.claude/settings.json bootstrap-hooks.sh entry
# firing alongside the native hooks.json registration — see the
# native-suppression check below.
NATIVE=false
[ "${1:-}" = "--native" ] && { NATIVE=true; shift; }

# Buffer stdin ONCE
INPUT=$(cat)

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup or session-start's grandfathering check.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

# Native dual-fire suppression (spec §4.2): invoked WITHOUT --native while the
# native-hooks.ok marker is present means this is the stale settings.json
# bootstrap entry firing alongside the native hooks.json registration —
# suppress it so the event doesn't get appended twice. No marker present means
# a pre-4.0 install (compat window): proceed normally.
if [ "$NATIVE" != true ] && [ -f "$(_eio_cortex_dir)/native-hooks.ok" ]; then
  printf '{}'
  exit 0
fi

# Resolve session-scoped event log
resolve_event_log "$INPUT"

# Extract tool_name + file_path for routing (needed regardless of whether the
# event log resolved — routing is the dispatcher's job even without an
# attributable session; sub-handlers guard their own state). file_path is read
# here so the checkpoint block can recognise a journal edit before it fires.
tool_name=$(printf '%s' "$INPUT" | extract_json_field "tool_name")
file_path=$(printf '%s' "$INPUT" | extract_json_field "tool_input.file_path")

# Record the tool call + mid-session checkpoint only when the event log
# resolved. journal_edit events (Task 2, post-edit-dispatch.sh) are the
# checkpoint anchor — no reset write needed here.
if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
  append_event "tool_call" "$tool_name"

  # A Write/Edit into memory/*.md IS the journal edit that anchors the
  # checkpoint. If THIS call is that edit, skip the checkpoint and fall through
  # to routing so post-edit-dispatch records journal_edit (which resets the
  # anchor naturally). Otherwise a journal Write landing exactly on the
  # modulo-25 boundary would fire a spurious nag AND lose its journal_edit /
  # file_edit events (the sub-handler would never run after the early exit).
  is_journal_edit=false
  if { [ "$tool_name" = "Write" ] || [ "$tool_name" = "Edit" ]; } \
     && printf '%s' "$file_path" | grep -qE 'memory/.*\.md'; then
    is_journal_edit=true
  fi

  # Mid-session checkpoint every 25 tool uses since the last journal entry
  if [ "$is_journal_edit" = false ]; then
    uses=$(count_events tool_call '' journal_edit)
    if [ "$uses" -gt 0 ] && [ $((uses % 25)) -eq 0 ]; then
      source "$SCRIPT_DIR/lib/escape-json.sh" || true
      checkpoint=$(escape_for_json "📝 Mid-session checkpoint (${uses} tool uses since last journal entry): consider adding a journal entry to memory/YYYY-MM-DD.md. What's the current state of the work?")
      printf '{"systemMessage":"%s"}' "$checkpoint"
      exit 0
    fi
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
