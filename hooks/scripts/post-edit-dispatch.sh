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
    # Record the fire for follow-through scoring (spec §6.3): kind first token,
    # warned path as payload. Appended AFTER this edit's file_edit event, so
    # only FURTHER edits of the path count against the <2 follow window.
    append_event "intervention" "re_edit_warning ${file_path}"
    source "$SCRIPT_DIR/lib/escape-json.sh" || true
    msg=$(escape_for_json "Re-edit detected: ${file_path} has been modified ${re_edit_count} times this session. Consider stepping back to re-plan the approach.")
    printf '{"systemMessage":"%s"}' "$msg"
    exit 0
  fi
fi

# Check for docs-file update. Per-project config (spec §7.1) — default
# documentation.md; substring match on the configured file's basename (same
# semantics as the old hardcoded check).
docs_file=$(eio_config_get docs_file "documentation.md")
docs_basename=$(basename "$docs_file")
if [[ "$file_path" == *"$docs_basename"* ]]; then
  append_event "docs_edit" "$file_path"
fi

# Track journal edits (memory/*.md) for mid-session checkpoint bookkeeping
if echo "$file_path" | grep -qE 'memory/.*\.md'; then
  append_event "journal_edit" "$file_path"
fi

# Track lessons-file updates for root cause documentation gate. Per-project
# config (spec §7.1) — default tasks/lessons.md; path must END with
# "/<basename>", case-insensitive (matches the old hardcoded check's regex).
lessons_file=$(eio_config_get lessons_file "tasks/lessons.md")
lessons_basename=$(basename "$lessons_file")
shopt -s nocasematch
if [[ "$file_path" == */"$lessons_basename" ]]; then
  append_event "root_cause_logged" "true"
fi
shopt -u nocasematch

# Commit cadence nudge (dynamic threshold from feedback loop, overridable via
# per-project config — spec §7.1). commit_nudge_threshold config wins over the
# feedback-derived threshold_set event when set to a genuine integer;
# non-numeric config values are ignored (fall back to current behavior).
# Race-safe derivation (Codex plan-review C-2): duplicate commit events from
# async double-observation never move the anchor past newer edits.
edits=$(eio_edits_since_last_commit)
threshold=$(last_event "threshold_set")
threshold="${threshold:-15}"
cfg_threshold=$(eio_config_get commit_nudge_threshold)
if [ -n "$cfg_threshold" ]; then
  case "$cfg_threshold" in
    ''|*[!0-9]*) : ;;  # non-numeric — ignore, keep feedback-derived threshold
    *) threshold="$cfg_threshold" ;;
  esac
fi
if [ "${edits:-0}" -gt "$threshold" ]; then
  # Record the fire for follow-through scoring (spec §6.3): followed iff a
  # commit event lands within the next 5 r-flagged file_edits.
  append_event "intervention" "commit_nudge"
  source "$SCRIPT_DIR/lib/escape-json.sh" || true
  msg=$(escape_for_json "You have ${edits} edits since last commit (threshold: ${threshold}). Consider committing — many edits since last commit.")
  printf '{"systemMessage":"%s"}' "$msg"
  exit 0
fi

# Doc-sync reminder for architectural files. Per-project config (spec §7.1) —
# architectural_patterns has NO default, so this reminder never fires unless
# a project explicitly opts in via config.local (keeps Undercurrent-specific
# vocabulary out of the public plugin).
docs_edit_count=$(count_events "docs_edit")
arch_patterns=$(eio_config_get architectural_patterns)
if [ "$docs_edit_count" -eq 0 ] && [ -n "$arch_patterns" ] && echo "$file_path" | grep -qiE "$arch_patterns"; then
  source "$SCRIPT_DIR/lib/escape-json.sh" || true
  msg=$(escape_for_json "Architectural file modified. Consider updating ${docs_file}.")
  printf '{"systemMessage":"%s"}' "$msg"
  exit 0
fi

printf '{}'
exit 0
