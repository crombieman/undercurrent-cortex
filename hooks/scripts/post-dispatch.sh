#!/usr/bin/env bash
set -euo pipefail
# Unified PostToolUse dispatcher — routes to sub-handlers by tool_name.
# Plugin hooks.json registers this with NO matcher (fires on all PostToolUse).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }

# The --native flag + native-hooks.ok marker suppression protocol is DELETED
# (calibration wave T5): it existed to suppress stale settings.json
# bootstrap-era entries, and T4 verified that era's entries are gone before
# deleting the cleanup machinery. A leftover marker file on disk is inert.

# Buffer stdin ONCE
INPUT=$(cat)

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

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

  # Mid-session checkpoint every 25 tool uses since the last journal entry —
  # LAB-only (T6 emitter census: nudges are treatment; the tool_call append
  # above is recording and runs in both conditions)
  if [ "$is_journal_edit" = false ] && [ "$(eio_get_profile)" = "lab" ]; then
    uses=$(count_events tool_call '' journal_edit)
    if [ "$uses" -gt 0 ] && [ $((uses % 25)) -eq 0 ]; then
      # Record the fire for follow-through scoring (spec §6.3): followed iff a
      # journal_edit lands within the next 10 tool_call events.
      append_event "intervention" "journal_checkpoint"
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
    # Exactly ONE JSON object per hook invocation (wave review C-1: both
    # sub-handlers printing straight to stdout produced concatenated `{}{}`
    # on every Write — invalid under the hook contract). post-edit-dispatch
    # speaks first; pattern-template (Write-only, lab-gated internally) is
    # consulted only when post-edit had nothing to say.
    edit_out=$(printf '%s' "$INPUT" | "$SCRIPT_DIR/post-edit-dispatch.sh")
    if [ "$tool_name" = "Write" ] && { [ -z "$edit_out" ] || [ "$edit_out" = "{}" ]; }; then
      pt_out=$(printf '%s' "$INPUT" | "$SCRIPT_DIR/pattern-template.sh" 2>/dev/null) || true
      [ -n "$pt_out" ] && edit_out="$pt_out"
    fi
    [ -z "$edit_out" ] && edit_out="{}"
    printf '%s' "$edit_out"
    ;;
  *)
    printf '{}'
    ;;
esac
exit 0
