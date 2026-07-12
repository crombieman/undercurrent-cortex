#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh"  || { printf '{}'; exit 0; }

# --native flag (Task 5: native hooks.json registration): consumed before any
# other arg handling. Its ABSENCE plus the native-hooks.ok marker (written
# every session by session-start once its opt-in gate passes) means this
# invocation is the stale ~/.claude/settings.json bootstrap-hooks.sh entry
# firing alongside the native hooks.json registration — see the
# native-suppression check below.
NATIVE=false
[ "${1:-}" = "--native" ] && { NATIVE=true; shift; }

# Buffer stdin ONCE (C1 fix — extract_json_field uses cat internally)
INPUT=$(cat)

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup or session-start's grandfathering check.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

# Native dual-fire suppression (spec §4.2, hardened Codex I-2): suppress ONLY
# when the native-hooks.ok marker's 3rd token (session_id, written by
# session-start THIS session) equals THIS payload's session_id — proof native
# registration is demonstrably alive for this very session. A marker with a
# mismatched or missing 3rd token (downgrade, legacy 2-token marker), or a
# payload carrying no session_id, does NOT suppress (compat: proceed normally).
# Presence alone is insufficient — it can outlive an active native registration.
if [ "$NATIVE" != true ]; then
  _marker="$(_eio_cortex_dir)/native-hooks.ok"
  if [ -f "$_marker" ]; then
    _marker_sid=$(awk 'NR==1{print $3}' "$_marker" 2>/dev/null | tr -d '[:space:]' || true)
    _payload_sid=$(_eio_extract_sid "$INPUT")
    if [ -n "$_payload_sid" ] && [ "$_marker_sid" = "$_payload_sid" ]; then
      printf '{}'
      exit 0
    fi
  fi
fi

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

# Session counters (edits via the race-safe first-observation anchor — C-2)
commits=$(count_events commit)
edits=$(eio_edits_since_last_commit)
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
