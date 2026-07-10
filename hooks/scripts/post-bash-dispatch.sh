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

# --- Pattern: test commands (per-language, spec §5.4/L6) ---
# Event existence = pass (PostToolUse only fires for exit-0 commands — wave-0
# pin), so no result flag is needed. Word-boundary anchors keep substrings
# like "pytest-docs"/"mypytest"/"go testing" from false-positiving. A
# per-project test_command ERE (config.local) is checked FIRST so projects
# can override detection. Known accepted noise (same class as v3's bare
# "vitest" substring): a command that MENTIONS a test invocation and exits 0
# (e.g. `grep pytest file`) forges a pass — bounded, documented.
test_framework=""
custom_pattern=$(eio_config_get test_command)
if [ -n "$custom_pattern" ] && echo "$command_str" | grep -qE "$custom_pattern"; then
  test_framework="custom"
elif echo "$command_str" | grep -qE '(^|[;&|[:space:]])(npm[[:space:]]+test|npx[[:space:]]+vitest|vitest)([[:space:]]|$|[;&|])'; then
  test_framework="vitest"
elif echo "$command_str" | grep -qE '(^|[;&|[:space:]])(python3?[[:space:]]+-m[[:space:]]+)?pytest([[:space:]]|$|[;&|])'; then
  test_framework="pytest"
elif echo "$command_str" | grep -qE '(^|[;&|[:space:]])go[[:space:]]+test([[:space:]]|$|[;&|])'; then
  test_framework="gotest"
elif echo "$command_str" | grep -qE '(^|[;&|[:space:]])cargo[[:space:]]+test([[:space:]]|$|[;&|])'; then
  test_framework="cargotest"
fi
if [ -n "$test_framework" ] && [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
  append_event "test_run" "$test_framework"
fi

# --- Pattern: Codex review invocation (spec §5.6, D7/L9) ---
# `codex` as a standalone word (boundary form keeps codexify/mycodex out), OR
# the companion runtime file. Either the dispatch step or the harvest step
# counts — both prove the review loop was exercised this session. Consumed by
# the stop-gate Codex reminder and the codex_reminder follow-through scoring.
if echo "$command_str" | grep -qE '(^|[;&|[:space:]])codex([[:space:]]|$)|(^|[;&|[:space:]])node[[:space:]][^;&|]*codex-companion\.mjs'; then
  if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
    append_event "codex_review" "cli"
  fi
fi

# --- Pattern: git commit (not amend) ---
# Word-boundary form, NOT line-anchored: compound commands (`git add -A &&
# git commit -m ...`) are how commits are usually phrased in practice, and the
# old `^git commit` anchor silently dropped every one of them — the session's
# edits-since-commit never reset and (post-T5) every commit_nudge in such a
# session scored as not-followed. Quotes are excluded from the boundary class,
# so `grep 'git commit' ...` stays out; for everything else the HEAD-recency
# guard below is the actual gatekeeper.
if echo "$command_str" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit([[:space:]]|$)'; then
  if ! echo "$command_str" | grep -q '\-\-amend'; then
    # Recency guard: the anchored regex above matches any command that STARTS
    # with `git commit `, including invocations that create no new commit — e.g.
    # `git commit` aborting on an empty index, `git commit --dry-run`, or a
    # commit that a hook rejected. In those cases HEAD is stale (it points at an
    # earlier commit) and recording it would attribute an old SHA to this
    # session. So only append the commit event when HEAD's committer timestamp is
    # within 60s of now — proof a commit was actually just created. Accepted
    # residual (bounded): an exit-0 command containing an unquoted `git commit`
    # token that does NOT commit (e.g. --dry-run) within 60s of a real commit
    # duplicates that commit's event — harmless to the commit-anchored
    # derivations, at worst +1 on the health row's commit count.
    # `edits_since_last_commit` derives via the `commit` anchor — no reset
    # write needed (mapping-table resolution).
    if [ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ]; then
      commit_ts=$(git -C "${PROJECT_DIR}" log -1 --format=%ct 2>/dev/null || echo "")
      if [[ "$commit_ts" =~ ^[0-9]+$ ]]; then
        now_ts=$(date +%s)
        delta=$(( now_ts - commit_ts ))
        [ "$delta" -lt 0 ] && delta=$(( -delta ))
        if [ "$delta" -le 60 ]; then
          short_sha=$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "")
          # Dedup against the last recorded commit event (spec §3.3 "HEAD
          # verified changed"): a matched command that created no NEW commit
          # (dry-run, unquoted mention) inside the recency window would
          # otherwise re-log the previous commit AFTER newer file_edits and
          # falsely reset Gate 1's edits-since-commit anchor.
          last_commit_sha=$(last_event commit)
          last_commit_sha="${last_commit_sha%% *}"
          if [ -n "$short_sha" ] && [ "$short_sha" != "$last_commit_sha" ]; then
            subject=$(git -C "${PROJECT_DIR}" log -1 --pretty=format:"%s" 2>/dev/null || echo "")
            append_event "commit" "${short_sha} ${subject}"
          fi
        fi
      fi
    fi

    # Journal logging (absorbed from post-commit-log)
    today=$(date +%Y-%m-%d)
    time_now=$(date +%H:%M)
    journal="${PROJECT_DIR}/memory/${today}.md"
    # Default before the journal gate — when no journal exists, msg is otherwise
    # never assigned and the conventional-commit check below would trip set -u,
    # crashing the hook without emitting valid JSON (hook contract violation).
    msg="commit"
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
