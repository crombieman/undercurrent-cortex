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

# --- Pattern: test commands (per-language; calibration wave, queue item 2) ---
# Event existence = pass (PostToolUse only fires for exit-0 commands — wave-0
# pin). COMMAND-POSITION bound (the D7 fix shape): the framework token must
# sit at a command head (start of line or right after ;, |, &), so a mention
# inside another command's arguments (`grep pytest file`, `echo make check`)
# can no longer forge a pass. The per-project test_command ERE (config.local)
# is checked FIRST and gets the SAME anchoring wrapped around it by this
# caller — the project configures the command, the anchoring is ours (Codex
# plan-review I-8). Accepted residual: command-wrapper prefixes (`time
# pytest`, `env X=1 pytest`) sit one token deep and are missed — bounded,
# documented.
_cmd_head='(^|[;&|])[[:space:]]*'
test_framework=""
custom_pattern=$(eio_config_get test_command)
if [ -n "$custom_pattern" ] \
   && echo "$command_str" | grep -qE "${_cmd_head}(${custom_pattern})" 2>/dev/null; then
  test_framework="custom"
elif echo "$command_str" | grep -qE "${_cmd_head}(npm[[:space:]]+test|npx[[:space:]]+vitest|vitest)([[:space:]]|\$|[;&|])"; then
  test_framework="vitest"
elif echo "$command_str" | grep -qE "${_cmd_head}(python3?[[:space:]]+-m[[:space:]]+)?pytest([[:space:]]|\$|[;&|])"; then
  test_framework="pytest"
elif echo "$command_str" | grep -qE "${_cmd_head}go[[:space:]]+test([[:space:]]|\$|[;&|])"; then
  test_framework="gotest"
elif echo "$command_str" | grep -qE "${_cmd_head}cargo[[:space:]]+test([[:space:]]|\$|[;&|])"; then
  test_framework="cargotest"
fi
if [ -n "$test_framework" ] && [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
  append_event "test_run" "$test_framework"
fi

# --- Pattern: Codex review invocation (spec §5.6, D7/L9) ---
# Require `codex`/`node` at a shell-command boundary plus a non-option Codex
# subcommand. This keeps echo/prose mentions, version/help probes, and a bare
# binary from forging a review while preserving direct and chained invocations.
# Consumed by the stop-gate reminder and codex_reminder follow-through scoring.
if echo "$command_str" | grep -qE '(^|[;&|])[[:space:]]*codex[[:space:]]+[^-;&|[:space:]][^;&|[:space:]]*|(^|[;&|])[[:space:]]*node[[:space:]][^;&|]*codex-companion\.mjs'; then
  if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
    append_event "codex_review" "cli"
  fi
fi

# --- Commit capture: git-derived (calibration wave, queue item 1) ---
# Command text plays NO role: on every exit-0 Bash observation, enumerate the
# commits since this session's session_start anchor and append any sha not yet
# in the log. "HEAD moved between observations" is the ground truth — the
# lexical `git commit` matcher this replaces missed compound/scripted commits
# and needed recency heuristics (synthesis limitation 1). Amends/rebases land
# as their rewritten shas at the next observation (accepted residual: the
# orphaned sha's event remains; the health row's commit fields are git-derived
# so the ROW stays correct). Events land at observation time, not creation
# time — ordering vs file_edits is approximate, as before. Write-time sha
# dedup below is best-effort under async concurrency; the race-safe consumer
# is eio_edits_since_last_commit (read-side first-observation anchor, Codex
# plan-review C-2). These fields are REPO-WINDOW observations: any actor's
# commit in this checkout during the session window is enumerated.
new_seen=false
newest_new_subject=""
if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
  anchor=$(last_event session_start)
  anchor="${anchor%% *}"
  # Anchor guard (plan-audit finding 1): a fallback-sid log carries "unknown"
  # — never feed a non-ISO anchor to `git log --since`.
  case "$anchor" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*)
      known_shas=$(list_events commit | awk '{print $1}')
      # git enumerates newest-first; reverse so events append in chronological
      # order (line order is the authoritative event order). head -50 bounds
      # the pathological window; mawk-safe reversal (no tac dependency).
      new_commits=$(git -C "${PROJECT_DIR}" log --since="$anchor" --format='%h %s' 2>/dev/null \
        | head -50 | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }') || true
      if [ -n "$new_commits" ]; then
        today=$(date +%Y-%m-%d)
        journal="${PROJECT_DIR}/memory/${today}.md"
        while IFS= read -r nc; do
          [ -z "$nc" ] && continue
          nc_sha="${nc%% *}"
          if [ -n "$known_shas" ] && printf '%s\n' "$known_shas" | grep -qxF "$nc_sha"; then
            continue
          fi
          nc_subject="${nc#* }"
          [ "$nc_subject" = "$nc" ] && nc_subject=""
          append_event "commit" "${nc_sha} ${nc_subject}"
          known_shas="${known_shas}${known_shas:+$'\n'}${nc_sha}"
          new_seen=true
          newest_new_subject="$nc_subject"
          # Journal line per newly observed commit (advisory document write;
          # deny-tolerant — a denied write must not crash the hook).
          if [ -f "$journal" ]; then
            printf '\n## %s - commit: %s\n' "$(date +%H:%M)" "${nc_subject:-commit}" >> "$journal" 2>/dev/null || true
          fi
        done <<< "$new_commits"
      fi
      ;;
  esac
fi

# --- Conventional commit check + context prompt (only when a NEW commit was
# observed this call; the newest new commit's subject is the one checked) ---
if [ "$new_seen" = true ]; then
  source "$SCRIPT_DIR/lib/escape-json.sh" || true
  context_prompt="📝 Commit logged. Add a 1-line context note to the journal: what problem did this solve, or what state was the system left in?"
  if [ -n "$newest_new_subject" ] \
     && ! echo "$newest_new_subject" | grep -qE '^(feat|fix|refactor|docs|chore|test|perf|ci|build|style):'; then
    warn_text="Non-conventional commit: '${newest_new_subject}'. Expected prefix: feat:/fix:/refactor:/docs:/chore:/test:. Consider: git commit --amend -m 'type: ...'\\n${context_prompt}"
    warn=$(escape_for_json "$warn_text")
    printf '{"systemMessage":"%s"}' "$warn"
    exit 0
  fi
  prompt=$(escape_for_json "$context_prompt")
  printf '{"systemMessage":"%s"}' "$prompt"
  exit 0
fi

printf '{}'
exit 0
