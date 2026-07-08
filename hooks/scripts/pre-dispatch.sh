#!/usr/bin/env bash
set -euo pipefail
# Unified PreToolUse dispatcher — routes to sub-handlers by tool_name.
# Plugin hooks.json registers this with NO matcher (fires on all PreToolUse).
# Prompt-based hooks remain inline in hooks.json with their own matchers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }

# Buffer stdin ONCE
INPUT=$(cat)

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal (state-io.sh's migration can create
# .claude/cortex/ as a side effect) — only the explicit sentinel file, written
# by /cortex:setup or session-start's grandfathering check.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

# Resolve session-scoped event log for plan-mode tracking
resolve_event_log "$INPUT"

# Extract tool_name for routing
tool_name=$(printf '%s' "$INPUT" | extract_json_field "tool_name")

# Detect ExitPlanMode BEFORE the early-exit filter. Missing/unresolved log
# (un-opted repo) means the append is skipped, but routing below is unaffected —
# routing is not state.
if [ "$tool_name" = "ExitPlanMode" ] && [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
  append_event "plan_mode" "used"
fi

# Early exit for irrelevant tools
case "$tool_name" in
  Write|Edit|Bash) ;;
  *) printf '{}'; exit 0 ;;
esac

# --- Bash: git push safety check ---
if [ "$tool_name" = "Bash" ]; then
  command_str=$(printf '%s' "$INPUT" | extract_json_field "tool_input.command")
  if echo "$command_str" | grep -qE 'git\s+push'; then
    source "$SCRIPT_DIR/lib/escape-json.sh" || true
    msg=$(escape_for_json "Git push safety: (1) no untracked files imported by committed code, (2) tests pass, (3) docs updated if architectural files changed, (4) never force-push to master.")
    printf '{"systemMessage":"%s"}' "$msg"
    exit 0
  fi
  # Non-push bash commands — pass through
  printf '{}'
  exit 0
fi

# Migration linter runs on Write AND Edit (if present — may be in domain pack)
linter_result="{}"
if [ -x "$SCRIPT_DIR/migration-linter.sh" ]; then
  linter_result=$(printf '%s' "$INPUT" | "$SCRIPT_DIR/migration-linter.sh")
fi

# If migration-linter returned a deny, propagate it immediately
if printf '%s' "$linter_result" | grep -q '"deny"' 2>/dev/null; then
  printf '%s' "$linter_result"
  exit 0
fi

# Plan-file-guard only runs on Write
if [ "$tool_name" = "Write" ]; then
  guard_result=$(printf '%s' "$INPUT" | "$SCRIPT_DIR/plan-file-guard.sh")
  if printf '%s' "$guard_result" | grep -q '"deny"' 2>/dev/null; then
    printf '%s' "$guard_result"
    exit 0
  fi
fi

# TDD guard — warn/deny src/ edits without test file this session
if [ "$tool_name" = "Write" ] || [ "$tool_name" = "Edit" ]; then
  tdd_result=$(printf '%s' "$INPUT" | "$SCRIPT_DIR/tdd-guard.sh" 2>/dev/null || echo "{}")
  if printf '%s' "$tdd_result" | grep -q '"deny"' 2>/dev/null; then
    printf '%s' "$tdd_result"
    exit 0
  fi
  if [ "$tdd_result" != "{}" ] && [ -n "$tdd_result" ]; then
    # TDD warning — but let migration-linter warning take priority if both fire
    if [ "$linter_result" = "{}" ] || [ -z "$linter_result" ]; then
      printf '%s' "$tdd_result"
      exit 0
    fi
  fi
fi

# If migration-linter returned a warning (systemMessage but not deny), output it
if [ "$linter_result" != "{}" ] && [ -n "$linter_result" ]; then
  printf '%s' "$linter_result"
  exit 0
fi

printf '{}'
exit 0
