#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# event-io.sh (NOT state-io.sh): this routed sub-handler only needs PROJECT_DIR.
# state-io.sh runs migrate_state_files() at SOURCE time (mkdir sessions/, write
# .migrated-v3.7) — sourcing it here would make mid-session opt-in leak side
# effects even when this session has no event log (Codex I-1).
source "$SCRIPT_DIR/lib/event-io.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh" || { printf '{}'; exit 0; }

PROJECT_DIR="$(eio_project_dir)"

# Buffer stdin
input=$(cat)

# Resolve session-scoped event log (deny-once escape hatch below). No
# resolvable log (missing/absent session_id, or a session_id with no log on
# disk) leaves EVENT_LOG empty/missing — append_event and list_events both
# no-op on that, so the escape hatch degrades to always-deny (pre-v4
# behavior, unchanged).
resolve_event_log "$input"

# Extract file path
file_path=$(echo "$input" | extract_json_field "tool_input.file_path")
file_path=$(echo "$file_path" | sed 's|\\\\|/|g')

# Early exit: not a plan file
case "$file_path" in
  *.claude/plans/*) ;;
  *) printf '{}'; exit 0 ;;
esac

# Resolve relative paths to absolute
if [[ "$file_path" != /* && "$file_path" != [A-Za-z]:* ]]; then
  file_path="${PROJECT_DIR}/${file_path}"
fi

# Normalize MSYS paths: /c/Users/... → C:/Users/...
file_path=$(echo "$file_path" | sed 's|^/\([a-zA-Z]\)/|\1:/|')

# Check if file exists and has >50 lines
if [ -f "$file_path" ]; then
  line_count=$(wc -l < "$file_path" 2>/dev/null | tr -d ' ')
  if [ "${line_count:-0}" -gt 50 ]; then
    # Deny-once escape hatch (vocabulary §3.3: plan_guard_denied): if THIS
    # exact path was already denied earlier this session, allow — the user
    # has been warned once and this is presumably a deliberate re-write, not
    # a blind overwrite. Exact whole-line match (not substring) so one plan
    # file's path can't accidentally unlock a different one that happens to
    # contain it.
    already_denied=""
    if [ -n "${EVENT_LOG:-}" ] && [ -f "$EVENT_LOG" ]; then
      if list_events plan_guard_denied | grep -qxF "$file_path"; then
        already_denied="yes"
      fi
    fi
    if [ -n "$already_denied" ]; then
      printf '{}'
      exit 0
    fi
    append_event "plan_guard_denied" "$file_path"
    msg=$(escape_for_json "BLOCKED: Plan file '${file_path##*/}' already has ${line_count} lines of content. Read it first before overwriting to verify you are not destroying a previous plan. Use the Read tool to review existing content.")
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}' "$msg"
    exit 0
  fi
fi

printf '{}'
exit 0
