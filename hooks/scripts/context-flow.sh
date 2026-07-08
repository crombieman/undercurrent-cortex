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

# Read stdin JSON, resolve session-scoped event log, extract user_prompt
INPUT=$(cat)
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
CAUTIOUS_MSG=""
mode=$(last_event mode_set)
mode="${mode%% *}"
mode="${mode:-normal}"
if [ "$mode" = "cautious" ]; then
  if [[ "$PROMPT_LOWER" == *"edit"* ]] || [[ "$PROMPT_LOWER" == *"fix"* ]] \
     || [[ "$PROMPT_LOWER" == *"add"* ]] || [[ "$PROMPT_LOWER" == *"implement"* ]] \
     || [[ "$PROMPT_LOWER" == *"build"* ]] || [[ "$PROMPT_LOWER" == *"refactor"* ]] \
     || [[ "$PROMPT_LOWER" == *"change"* ]] || [[ "$PROMPT_LOWER" == *"update"* ]]; then
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
     || [[ "$PROMPT_LOWER" == *"call it"* ]]; then
  MSG="Remember to invoke the session-end skill before closing. Run: /cortex:session-end"
  ESCAPED=$(escape_for_json "$MSG")
  printf '{"systemMessage":"%s"}' "$ESCAPED"
  exit 0
fi

# If no match or file missing
if [ -z "$CONTEXT_FILE" ] || [ ! -f "$CONTEXT_FILE" ]; then
  # Still inject cautious-mode warning if active
  if [ -n "$CAUTIOUS_MSG" ]; then
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
    ESCAPED=$(escape_for_json "$CAUTIOUS_MSG")
    printf '{"systemMessage":"%s"}' "$ESCAPED"
    exit 0
  fi
  printf '{}'
  exit 0
fi

# Prepend cautious-mode warning if active
if [ -n "$CAUTIOUS_MSG" ]; then
  CONTENT="${CAUTIOUS_MSG}"$'\n\n'"${CONTENT}"
fi

ESCAPED=$(escape_for_json "$CONTENT")
printf '{"systemMessage":"%s"}' "$ESCAPED"
exit 0
