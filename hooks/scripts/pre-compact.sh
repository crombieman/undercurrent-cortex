#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh"  || { printf '{}'; exit 0; }

# Buffer stdin ONCE (C1 fix — extract_json_field uses cat internally)
INPUT=$(cat)

# Resolve session-scoped event log from session_id in hook JSON
resolve_event_log "$INPUT"

# Guard: no event log → nothing to preserve. v4 has no legacy state-file
# fallback (the log IS the state; same guard pattern as stop-gate.sh).
if [ -z "$EVENT_LOG" ] || [ ! -f "$EVENT_LOG" ]; then
  printf '{}'
  exit 0
fi

# --- Optional transcript scan: append discovered items as carry_over events (I3 fix) ---
transcript_path=$(printf '%s' "$INPUT" | extract_json_field "transcript_path")
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  tagged_items=$(grep -oE '\[carry-over\].*' "$transcript_path" 2>/dev/null | head -10 || true)
  if [ -n "$tagged_items" ]; then
    while IFS= read -r item; do
      if [ -n "$item" ]; then
        append_event "carry_over" "$item"
      fi
    done <<< "$tagged_items"
  fi

  pin_items=$(grep -oE '\[mid-session pin\].*' "$transcript_path" 2>/dev/null | head -10 || true)
  if [ -n "$pin_items" ]; then
    while IFS= read -r item; do
      if [ -n "$item" ]; then
        append_event "carry_over" "$item"
      fi
    done <<< "$pin_items"
  fi
fi

# --- Build preservation summary from the event log ---
summary="[PRE-COMPACT CONTEXT PRESERVATION]"

# Carry-over items (read AFTER transcript scan writes — I3). Epoch-ordered
# reconciliation (spec §3.5 amendment) via the shared eio_unresolved_items
# helper — the same source of truth as stop-gate.sh Gate 4. Only UNRESOLVED
# items (latest carry_over epoch strictly after their latest carry_addressed
# epoch) are preserved and warned about, so both scripts present the same view.
carry_over=$(eio_unresolved_items "$EVENT_LOG")
if [ -n "$carry_over" ]; then
  summary="${summary}"$'\n\n'"Carry-over items:"$'\n'"${carry_over}"
fi

# Files modified this session (deduplicated)
files_modified=$(list_events file_edit | sed 's/^[rx] //')
if [ -n "$files_modified" ]; then
  unique_files=$(echo "$files_modified" | sort -u)
  file_count=$(echo "$unique_files" | wc -l | tr -d ' ')
  summary="${summary}"$'\n\n'"Files modified (${file_count} unique):"$'\n'"${unique_files}"
fi

# Session counters
commits=$(count_events commit)
edits=$(count_events file_edit r commit)
tests_run_count=$(count_events test_run)
docs_updated_count=$(count_events docs_edit)
tests_run=false
[ "${tests_run_count:-0}" -gt 0 ] && tests_run=true
docs_updated=false
[ "${docs_updated_count:-0}" -gt 0 ] && docs_updated=true

summary="${summary}"$'\n\n'"Session stats: ${commits:-0} commits, ${edits:-0} uncommitted edits, tests_run=${tests_run}, docs_updated=${docs_updated}"

# Warnings
if [ "${edits:-0}" -gt 0 ]; then
  summary="${summary}"$'\n'"WARNING: ${edits} uncommitted edits at compaction time."
fi

# carry_over holds only UNRESOLVED items (epoch-reconciled above) — warn
# whenever any remain, mirroring stop-gate.sh Gate 4's block condition.
if [ -n "$carry_over" ]; then
  summary="${summary}"$'\n'"WARNING: Carry-over items not yet addressed."
fi

# --- Output ---
escaped=$(escape_for_json "$summary")
printf '{"systemMessage":"%s"}' "$escaped"
exit 0
