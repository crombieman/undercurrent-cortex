#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }

# Buffer stdin ONCE, then resolve session-scoped event log
INPUT=$(cat)
resolve_event_log "$INPUT"

PROJECT_DIR="$(eio_project_dir)"

# Extract tool_input.command from buffered input
command_str=$(printf '%s' "$INPUT" | extract_json_field "tool_input.command")
[ -z "$command_str" ] && { printf '{}'; exit 0; }

# --- Pattern: test commands ---
if echo "$command_str" | grep -qE '(npm test|vitest|npx vitest)'; then
  if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
    append_event "test_run" "vitest"
  fi
fi

# --- Pattern: git commit (not amend) ---
if echo "$command_str" | grep -qE '^[[:space:]]*git[[:space:]]+commit[[:space:]]'; then
  if ! echo "$command_str" | grep -q '\-\-amend'; then
    # Recency guard: PostToolUse only fires on exit-0, so the commit command
    # itself succeeded — but compound commands (e.g. "git add . && git commit")
    # can leave a stale HEAD if this hook fires late relative to the actual
    # commit. Only append the commit event when HEAD's committer timestamp is
    # within 60s of now. `edits_since_last_commit` derives via the `commit`
    # anchor — no reset write needed here (mapping-table resolution).
    if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
      commit_ts=$(git -C "${PROJECT_DIR}" log -1 --format=%ct 2>/dev/null || echo "")
      if [[ "$commit_ts" =~ ^[0-9]+$ ]]; then
        now_ts=$(date +%s)
        delta=$(( now_ts - commit_ts ))
        [ "$delta" -lt 0 ] && delta=$(( -delta ))
        if [ "$delta" -le 60 ]; then
          short_sha=$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "")
          subject=$(git -C "${PROJECT_DIR}" log -1 --pretty=format:"%s" 2>/dev/null || echo "")
          [ -n "$short_sha" ] && append_event "commit" "${short_sha} ${subject}"
        fi
      fi
    fi

    # Journal logging (absorbed from post-commit-log)
    today=$(date +%Y-%m-%d)
    time_now=$(date +%H:%M)
    journal="${PROJECT_DIR}/memory/${today}.md"
    if [ -f "$journal" ]; then
      msg=$(git -C "${PROJECT_DIR}" log -1 --pretty=format:"%s" 2>/dev/null || echo "commit")
      [ -z "$msg" ] && msg="commit"
      printf '\n## %s - commit: %s\n' "$time_now" "$msg" >> "$journal"
    fi

    # --- Conventional commit check + context prompt ---
    source "$SCRIPT_DIR/lib/escape-json.sh" || true
    context_prompt="📝 Commit logged. Add a 1-line context note to the journal: what problem did this solve, or what state was the system left in?"
    if [ "$msg" != "commit" ]; then
      if ! echo "$msg" | grep -qE '^(feat|fix|refactor|docs|chore|test|perf|ci|build|style):'; then
        warn_text="Non-conventional commit: '${msg}'. Expected prefix: feat:/fix:/refactor:/docs:/chore:/test:. Consider: git commit --amend -m 'type: ...'\\n${context_prompt}"
        warn=$(escape_for_json "$warn_text")
        printf '{"systemMessage":"%s"}' "$warn"
        exit 0
      fi
    fi
    # Conventional commit (or couldn't determine) — still prompt for context
    prompt=$(escape_for_json "$context_prompt")
    printf '{"systemMessage":"%s"}' "$prompt"
    exit 0
  fi
fi

printf '{}'
exit 0
