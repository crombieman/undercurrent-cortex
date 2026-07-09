#!/usr/bin/env bash
set -euo pipefail
# Circulatory System — deterministic keyword-matching context injector.
# UserPromptSubmit command hook (async: false).
# Reads user_prompt from stdin JSON, matches against keyword lists,
# returns matching context file as systemMessage. First match wins.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh" || { printf '{}'; exit 0; }

CONTEXT_DIR="$SCRIPT_DIR/../../context"

# --native flag (Task 5: native hooks.json registration): consumed before any
# other arg handling — sensory-check's `--mid-session "$INPUT"` invocation
# below is a SEPARATE script call, unaffected by this flag. Its ABSENCE plus
# the native-hooks.ok marker (written every session by session-start once its
# opt-in gate passes) means this invocation is the stale
# ~/.claude/settings.json bootstrap-hooks.sh entry firing alongside the
# native hooks.json registration — see the native-suppression check below.
NATIVE=false
[ "${1:-}" = "--native" ] && { NATIVE=true; shift; }

# Read stdin JSON, resolve session-scoped event log, extract user_prompt
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

resolve_event_log "$INPUT"
PROMPT=$(printf '%s' "$INPUT" | extract_json_field "user_prompt")

# Graceful degradation
[ -z "$PROMPT" ] && { printf '{}'; exit 0; }

PROJECT_DIR="$(eio_project_dir)"
STATE_DIR="${PROJECT_DIR}/.claude"
PROPOSALS_FILE="$(eio_proposals_file)"

# Profile check for proposal handling (strict only)
PROFILE=$(eio_get_profile)

# Lowercase for case-insensitive matching
PROMPT_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Pad with spaces for word-boundary matching on short keywords
PADDED=" ${PROMPT_LOWER} "

# --- Feedback Loop: cautious-mode injection ---
# R4 fix: the old keyword list (edit|fix|add|implement|build|refactor|change|
# update) collided with ordinary English substrings ("additional", "fixture")
# and re-fired on every matching prompt all session long. Replaced with a
# once-per-session trigger: fires on the FIRST prompt of a cautious session,
# regardless of content, then never again (guarded by the `intervention
# cautious_mode` event — spec §3.3 closed vocabulary — appended at each actual
# point of injection below, not here, so a prompt that matches an earlier
# early-return branch and never surfaces CAUTIOUS_MSG doesn't burn the
# session's one opportunity).
CAUTIOUS_MSG=""
mode=$(last_event mode_set)
mode="${mode%% *}"
mode="${mode:-normal}"
if [ "$mode" = "cautious" ]; then
  cautious_fired=$(count_events intervention cautious_mode)
  cautious_fired="${cautious_fired:-0}"
  if [ "$cautious_fired" -eq 0 ]; then
    CAUTIOUS_MSG="[Cautious mode active — health trend degrading or high-churn detected. Plan before acting. Enter plan mode for non-trivial changes.]"
  fi
fi

# Priority-ordered keyword matching (first match wins)
# Uses bash [[ ]] glob matching — immune to regex injection from user input
CONTEXT_FILE=""

# --- Context file auto-discovery ---
# Use newline-separated list (not colon) to handle Windows paths with drive letters
SCAN_DIRS_NL="$CONTEXT_DIR"

# CORTEX_EXTRA_CONTEXT_DIRS uses newlines (not colons) to avoid Windows drive letter splitting
if [ -n "${CORTEX_EXTRA_CONTEXT_DIRS:-}" ]; then
  SCAN_DIRS_NL="${SCAN_DIRS_NL}"$'\n'"${CORTEX_EXTRA_CONTEXT_DIRS}"
fi

# Read extra context dirs from domain pack registrations
EXTRA_DIRS_FILE="${STATE_DIR}/cortex-context-dirs.local"
if [ -f "$EXTRA_DIRS_FILE" ]; then
  while IFS= read -r extra_dir; do
    [ -n "$extra_dir" ] && [ -d "$extra_dir" ] && SCAN_DIRS_NL="${SCAN_DIRS_NL}"$'\n'"$extra_dir"
  done < "$EXTRA_DIRS_FILE"
fi

while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ -d "$dir" ] || continue
  for ctx_file in "$dir"/*.md; do
    [ -f "$ctx_file" ] || continue
    IFS= read -r kw_line < "$ctx_file"
    [[ "$kw_line" == keywords:* ]] || continue
    local_keywords="${kw_line#keywords: }"
    IFS=, read -ra kw_list <<< "$local_keywords"
    for kw in "${kw_list[@]}"; do
      kw="${kw## }"
      kw="${kw%% }"
      if [[ "$PROMPT_LOWER" == *"$kw"* ]]; then
        CONTEXT_FILE="$ctx_file"
        break 3
      fi
    done
  done
done <<< "$SCAN_DIRS_NL"

if [[ "$PADDED" == *" ci "* ]] || [[ "$PROMPT_LOWER" == *"pipeline status"* ]] \
     || [[ "$PROMPT_LOWER" == *"build status"* ]] || [[ "$PROMPT_LOWER" == *"github actions"* ]] \
     || [[ "$PROMPT_LOWER" == *"remote commits"* ]] || [[ "$PROMPT_LOWER" == *"open prs"* ]]; then
  # Sensory system: mid-session external awareness check
  sensory_output=""
  if [ -x "$SCRIPT_DIR/sensory-check.sh" ]; then
    sensory_output=$("$SCRIPT_DIR/sensory-check.sh" --mid-session "$INPUT" 2>/dev/null || echo "")
  fi
  if [ -n "$sensory_output" ]; then
    ESCAPED=$(escape_for_json "$sensory_output")
    printf '{"systemMessage":"%s"}' "$ESCAPED"
    exit 0
  fi
  # Fall through to empty if no sensory output
  printf '{}'
  exit 0

elif [[ "$PROMPT_LOWER" == *"[decision]"* ]] || [[ "$PROMPT_LOWER" == *"decision:"* ]] \
     || [[ "$PROMPT_LOWER" == *"i decided"* ]] || [[ "$PROMPT_LOWER" == *"we decided"* ]]; then
  MSG="Decision detected. Log it with metadata:\n- Category: architecture / data / UX / pipeline / security\n- Reversibility: easy / hard / irreversible\n- Confidence: high / medium / low\nWrite entry to .claude/cortex/decisions.local.md with format:\n## YYYY-MM-DD - [title]\ncategory=[cat] reversibility=[rev] confidence=[conf]\n[description]"
  ESCAPED=$(escape_for_json "$MSG")
  printf '{"systemMessage":"%s"}' "$ESCAPED"
  exit 0

elif [[ "$PROFILE" = "strict" ]] && { [[ "$PROMPT_LOWER" == *"approve proposal"* ]] || [[ "$PROMPT_LOWER" == *"accept proposal"* ]] \
     || [[ "$PROMPT_LOWER" == *"apply proposal"* ]] || [[ "$PROMPT_LOWER" == *"approve all"* ]]; }; then
  # Growth system: apply approved proposals
  apply_output=""
  if [ -x "$SCRIPT_DIR/apply-proposal.sh" ]; then
    apply_output=$("$SCRIPT_DIR/apply-proposal.sh" approve 2>/dev/null || echo "Failed to apply proposal.")
  else
    apply_output="apply-proposal.sh not found."
  fi
  ESCAPED=$(escape_for_json "${apply_output:-No pending proposals found.}")
  printf '{"systemMessage":"%s"}' "$ESCAPED"
  exit 0

elif [[ "$PROFILE" = "strict" ]] && { [[ "$PROMPT_LOWER" == *"reject proposal"* ]] || [[ "$PROMPT_LOWER" == *"dismiss proposal"* ]] \
     || [[ "$PROMPT_LOWER" == *"skip proposal"* ]]; }; then
  apply_output=""
  if [ -x "$SCRIPT_DIR/apply-proposal.sh" ]; then
    apply_output=$("$SCRIPT_DIR/apply-proposal.sh" reject 2>/dev/null || echo "Failed to reject proposal.")
  else
    apply_output="apply-proposal.sh not found."
  fi
  ESCAPED=$(escape_for_json "${apply_output:-No pending proposals found.}")
  printf '{"systemMessage":"%s"}' "$ESCAPED"
  exit 0

elif [[ "$PROFILE" = "strict" ]] && { [[ "$PROMPT_LOWER" == *"show proposals"* ]] || [[ "$PROMPT_LOWER" == *"list proposals"* ]] \
     || [[ "$PROMPT_LOWER" == *"pending proposals"* ]]; }; then
  if [ -f "$PROPOSALS_FILE" ]; then
    pending=""
    if grep -q '^status=pending' "$PROPOSALS_FILE" 2>/dev/null; then
      pending=$(awk '/^status=pending/{p=1} p && /^## Proposal:/{print; p=0}' "$PROPOSALS_FILE")
    fi
    if [ -n "$pending" ]; then
      ESCAPED=$(escape_for_json "Pending proposals:"$'\n'"${pending}")
    else
      ESCAPED=$(escape_for_json "No pending proposals.")
    fi
  else
    ESCAPED=$(escape_for_json "No proposals file exists.")
  fi
  printf '{"systemMessage":"%s"}' "$ESCAPED"
  exit 0

elif [[ "$PROMPT_LOWER" == *"done for today"* ]] || [[ "$PROMPT_LOWER" == *"wrap up"* ]] \
     || [[ "$PROMPT_LOWER" == *"session end"* ]] || [[ "$PROMPT_LOWER" == *"let's stop"* ]] \
     || [[ "$PROMPT_LOWER" == *"call it a day"* ]] || [[ "$PROMPT_LOWER" == *"call it a night"* ]] \
     || [[ "$PROMPT_LOWER" == *"calling it"* ]]; then
  MSG="Remember to invoke the session-end skill before closing. Run: /cortex:session-end"
  ESCAPED=$(escape_for_json "$MSG")
  printf '{"systemMessage":"%s"}' "$ESCAPED"
  exit 0
fi

# If no match or file missing
if [ -z "$CONTEXT_FILE" ] || [ ! -f "$CONTEXT_FILE" ]; then
  # Still inject cautious-mode warning if active
  if [ -n "$CAUTIOUS_MSG" ]; then
    append_event "intervention" "cautious_mode"
    ESCAPED=$(escape_for_json "$CAUTIOUS_MSG")
    printf '{"systemMessage":"%s"}' "$ESCAPED"
    exit 0
  fi
  printf '{}'
  exit 0
fi

# Read context file and return as systemMessage
CONTENT=$(cat "$CONTEXT_FILE" 2>/dev/null) || true
if [ -z "$CONTENT" ]; then
  if [ -n "$CAUTIOUS_MSG" ]; then
    append_event "intervention" "cautious_mode"
    ESCAPED=$(escape_for_json "$CAUTIOUS_MSG")
    printf '{"systemMessage":"%s"}' "$ESCAPED"
    exit 0
  fi
  printf '{}'
  exit 0
fi

# Prepend cautious-mode warning if active
if [ -n "$CAUTIOUS_MSG" ]; then
  append_event "intervention" "cautious_mode"
  CONTENT="${CAUTIOUS_MSG}"$'\n\n'"${CONTENT}"
fi

ESCAPED=$(escape_for_json "$CONTENT")
printf '{"systemMessage":"%s"}' "$ESCAPED"
exit 0
