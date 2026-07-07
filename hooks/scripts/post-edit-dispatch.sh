#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }

# Buffer stdin ONCE, then resolve session-scoped event log
INPUT=$(cat)
resolve_event_log "$INPUT"

# Guard: event log must exist (session-start creates it)
[ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ] || { printf '{}'; exit 0; }

PROJECT_DIR="$(eio_project_dir)"

# Extract nested tool_input.file_path from buffered input
file_path=$(printf '%s' "$INPUT" | extract_json_field "tool_input.file_path")
file_path=$(normalize_path "$file_path")

[ -z "$file_path" ] && { printf '{}'; exit 0; }

# Track the edit — flag r (repo-internal, not gitignored) or x (external/ignored)
# (plan files in ~/.claude/plans/, external memory files, etc. can't be committed)
flag="x"
if [[ "$file_path" == "${PROJECT_DIR}"* ]]; then
  flag="r"
  if git -C "${PROJECT_DIR}" check-ignore -q "$file_path" 2>/dev/null; then
    flag="x"
  fi
fi
append_event "file_edit" "${flag} ${file_path}"

# Re-edit spiral detection (skip plugin infrastructure paths)
if ! echo "$file_path" | grep -qE '\.claude-plugin/|\.claude/'; then
  files_modified=$(list_events "file_edit" | sed 's/^[rx] //')
  re_edit_count=0
  if [ -n "$files_modified" ]; then
    if echo "$files_modified" | grep -qxF "$file_path"; then
      re_edit_count=$(echo "$files_modified" | grep -cxF "$file_path")
    fi
  fi
  if [ "$re_edit_count" -ge 3 ]; then
    source "$SCRIPT_DIR/lib/escape-json.sh" || true
    msg=$(escape_for_json "Re-edit detected: ${file_path} has been modified ${re_edit_count} times this session. Consider stepping back to re-plan the approach.")
    printf '{"systemMessage":"%s"}' "$msg"
    exit 0
  fi
fi

# Check for documentation.md update
if [[ "$file_path" == *"documentation.md"* ]]; then
  append_event "docs_edit" "$file_path"
fi

# Track journal edits (memory/*.md) for mid-session checkpoint bookkeeping
if echo "$file_path" | grep -qE 'memory/.*\.md'; then
  append_event "journal_edit" "$file_path"
fi

# Track lessons.md updates for root cause documentation gate
if echo "$file_path" | grep -qiE '/lessons\.md$'; then
  append_event "root_cause_logged" "true"
fi

# Commit cadence nudge (dynamic threshold from feedback loop)
edits=$(count_events "file_edit" "r" "commit")
threshold=$(last_event "threshold_set")
threshold="${threshold:-15}"
if [ "${edits:-0}" -gt "$threshold" ]; then
  source "$SCRIPT_DIR/lib/escape-json.sh" || true
  msg=$(escape_for_json "You have ${edits} edits since last commit (threshold: ${threshold}). Consider committing — many edits since last commit.")
  printf '{"systemMessage":"%s"}' "$msg"
  exit 0
fi

# Doc-sync reminder for architectural files
docs_edit_count=$(count_events "docs_edit")
if [ "$docs_edit_count" -eq 0 ] && echo "$file_path" | grep -qiE 'scoring|pipeline|v10|v11|constants|middleware|signals|cached-loader|env\.ts|cron|batch-upsert|stripe'; then
  source "$SCRIPT_DIR/lib/escape-json.sh" || true
  msg=$(escape_for_json "Architectural file modified. Consider updating documentation.md.")
  printf '{"systemMessage":"%s"}' "$msg"
  exit 0
fi

printf '{}'
exit 0
