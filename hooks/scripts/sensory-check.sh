#!/usr/bin/env bash
set -euo pipefail
# Sensory System — external awareness: remote commits, CI status, open PRs.
# Called by session-start (full scan) and context-flow (mid-session with cooldown).
# Outputs plain text (caller wraps in JSON).
#
# Usage: sensory-check.sh [--mid-session] [hook_json]
# hook_json carries session_id for event-log resolution. session-start still
# calls this without hook_json this wave (converted in a later task) — reads
# degrade to the current-session.id marker fallback, and appends are skipped
# entirely when no session_id can be resolved (spec §3.4: appends require an
# attributable session).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh" || exit 0

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup or session-start's grandfathering check. Plain exit (text
# surface, no JSON wrapper — the caller wraps output in JSON if needed).
[ -f "$(_eio_cortex_dir)/enabled" ] || exit 0

MID_SESSION=false
HOOK_JSON=""
if [ "${1:-}" = "--mid-session" ]; then
  MID_SESSION=true
  HOOK_JSON="${2:-}"
else
  HOOK_JSON="${1:-}"
fi

# Resolve the write-target log strictly from session_id in hook_json (appends
# require an attributable session — no marker fallback for writes).
resolve_event_log "$HOOK_JSON"
WRITE_LOG="$EVENT_LOG"

# Resolve the read-target log — falls back to current-session.id when
# hook_json carries no session_id, so cooldown/delta reads still work even
# when this script is called without JSON (e.g. session-start this wave).
resolve_event_log_readonly "$HOOK_JSON"
READ_LOG="$EVENT_LOG"

PROJECT_DIR="$(eio_project_dir)"

# --- Non-interactive guard: never let git/gh block on an auth prompt ---
# Root-cause fix for frozen SessionStart hooks: a stale GitHub token + Git
# Credential Manager popup (or any interactive prompt) inside this blocking
# hook hangs Claude Code indefinitely. Force every git/gh call below to fail
# fast instead of prompting.
export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=0
export GCM_INTERACTIVE=never
export GIT_ASKPASS=echo
export SSH_ASKPASS=echo
export GH_NO_UPDATE_NOTIFIER=1
export GH_PROMPT_DISABLED=1

# --- Timeout wrapper (Windows Git Bash safe) ---
# Only trust GNU coreutils `timeout` — Windows' timeout.exe is a different,
# interactive command that mangles these invocations and may sit on PATH ahead
# of (or instead of) GNU timeout in a hook shell. With no usable GNU timeout,
# SKIP the network call rather than run it unbounded (the old `else "$@"`
# branch could hang the hook forever).
run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1 && timeout --version 2>/dev/null | grep -qi coreutils; then
    timeout -k 1 "$secs" "$@" 2>/dev/null || true
  else
    return 0
  fi
}

# --- Mid-session cooldown: skip if last check <5 min ago ---
if [ "$MID_SESSION" = true ]; then
  last_check=$(last_event sensory_check "$READ_LOG" 2>/dev/null || echo "")
  if [ -n "$last_check" ]; then
    # C-2 fix: replace ISO 8601 T separator with space for GNU date
    last_epoch=$(date -d "${last_check/T/ }" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    if [ "${last_epoch:-0}" -gt 0 ] && [ $((now_epoch - last_epoch)) -lt 300 ]; then
      exit 0  # Cooldown active
    fi
  fi
fi

output=""

# --- Check 1: Remote commits ---
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [ -n "$remote_url" ]; then
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -n "$current_branch" ] && [ "$current_branch" != "HEAD" ]; then
      # Fetch with 2-second timeout
      fetch_output=$(run_with_timeout 2 git fetch --dry-run origin "$current_branch" 2>&1)
      if echo "$fetch_output" | grep -q '[0-9a-f]' 2>/dev/null; then
        output="${output}Remote has new commits on origin/${current_branch} since last fetch."$'\n'
      fi

      # Track remote HEAD
      remote_head=$(git rev-parse "origin/${current_branch}" 2>/dev/null || echo "unknown")
      last_remote=$(last_event remote_head "$READ_LOG" 2>/dev/null || echo "")
      if [ -n "$last_remote" ] && [ "$remote_head" != "$last_remote" ] && [ "$remote_head" != "unknown" ]; then
        output="${output}Remote HEAD changed since last session (was: ${last_remote:0:7}, now: ${remote_head:0:7})."$'\n'
      fi
      if [ -n "$WRITE_LOG" ] && [ -f "$WRITE_LOG" ]; then
        EVENT_LOG="$WRITE_LOG"
        append_event "remote_head" "$remote_head"
      fi
    fi
  fi
fi

# --- Check 2: CI status ---
if command -v gh >/dev/null 2>&1; then
  ci_json=$(run_with_timeout 5 gh run list --branch master --limit 3 --json status,conclusion,name)
  if [ -n "$ci_json" ] && [ "$ci_json" != "[]" ]; then
    # Extract latest conclusion (simple grep — avoids jq dependency)
    latest_conclusion=$(echo "$ci_json" | grep -o '"conclusion":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    if [ "$latest_conclusion" = "failure" ]; then
      latest_name=$(echo "$ci_json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
      output="${output}CI FAILED: ${latest_name}. Run: gh run list --limit 3"$'\n'
    fi
    if [ -n "$WRITE_LOG" ] && [ -f "$WRITE_LOG" ]; then
      EVENT_LOG="$WRITE_LOG"
      append_event "ci_status" "${latest_conclusion:-unknown}"
    fi
  fi

  # --- Check 3: Open PRs ---
  pr_json=$(run_with_timeout 5 gh pr list --state open --json number,title --limit 5)
  if [ -n "$pr_json" ] && [ "$pr_json" != "[]" ]; then
    pr_count=0
    if echo "$pr_json" | grep -q '"number"' 2>/dev/null; then
      pr_count=$(echo "$pr_json" | grep -c '"number"')
    fi
    if [ "${pr_count:-0}" -gt 0 ]; then
      output="${output}${pr_count} open PR(s) on this repo."$'\n'
    fi
  fi
fi

# --- Check 4: Language detection ---
if [ "$MID_SESSION" != true ]; then
  lang_detected=""
  if [ -f "${PROJECT_DIR}/pyproject.toml" ] || [ -f "${PROJECT_DIR}/setup.py" ] || [ -f "${PROJECT_DIR}/requirements.txt" ] || [ -f "${PROJECT_DIR}/Pipfile" ]; then
    lang_detected="${lang_detected}Python project detected."$'\n'
  fi
  if [ -f "${PROJECT_DIR}/go.mod" ]; then
    lang_detected="${lang_detected}Go project detected."$'\n'
  fi
  if [ -f "${PROJECT_DIR}/Cargo.toml" ]; then
    lang_detected="${lang_detected}Rust project detected."$'\n'
  fi
  if [ -n "$lang_detected" ]; then
    output="${output}${lang_detected}"
  fi
fi

# Write timestamp (skipped when no session_id was resolvable — write rule)
if [ -n "$WRITE_LOG" ] && [ -f "$WRITE_LOG" ]; then
  EVENT_LOG="$WRITE_LOG"
  append_event "sensory_check" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# Output (plain text — caller wraps in JSON if needed)
printf '%s' "$output"
exit 0
