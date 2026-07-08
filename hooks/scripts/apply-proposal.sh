#!/usr/bin/env bash
set -euo pipefail
# Growth/Adaptation System — proposal lifecycle: approve or reject pending proposals.
# Called by context-flow.sh when user says "approve proposal" or "reject proposal".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# event-io.sh (NOT state-io.sh): this handler only needs PROPOSALS_FILE.
# state-io.sh runs migrate_state_files() at SOURCE time (mkdir sessions/, write
# .migrated-v3.7) — sourcing it here would leak those side effects on every
# proposal approve/reject (Codex I-1).
source "$SCRIPT_DIR/lib/event-io.sh" || { echo "State I/O unavailable"; exit 0; }

PROPOSALS_FILE="$(eio_proposals_file)"

ACTION="${1:-approve}"  # approve or reject

[ -f "$PROPOSALS_FILE" ] || { echo "No proposals file."; exit 0; }

# Find first pending proposal
proposal_id=""
proposal_type=""
proposal_target=""
proposal_body=""
proposal_summary=""
current_id=""
in_pending=false
in_body=false
body_lines=""

while IFS= read -r line; do
  case "$line" in
    id=*)
      current_id="${line#id=}"
      ;;
    status=pending)
      if [ -n "$current_id" ]; then
        in_pending=true
        proposal_id="$current_id"
      fi
      ;;
    type=*)
      if [ "$in_pending" = true ]; then
        proposal_type="${line#type=}"
      fi
      ;;
    target=*)
      if [ "$in_pending" = true ]; then
        proposal_target="${line#target=}"
      fi
      ;;
    "**Summary"*:*)
      if [ "$in_pending" = true ]; then
        proposal_summary="${line#*: }"
      fi
      ;;
    "**Body"*:*)
      if [ "$in_pending" = true ]; then
        in_body=true
        # Capture inline content after "**Body**: "
        body_content="${line#*: }"
        if [ "$body_content" != "$line" ] && [ -n "$body_content" ]; then
          body_lines="$body_content"
        fi
      fi
      ;;
    "**Proposed change"*:*|"**Risk"*:*|"**Evidence"*:*)
      if [ "$in_body" = true ]; then
        in_body=false
      fi
      ;;
    "---")
      if [ "$in_pending" = true ] && [ -n "$proposal_id" ]; then
        # Found complete pending proposal
        proposal_body="$body_lines"
        break
      fi
      # Reset for next proposal block
      in_pending=false
      in_body=false
      body_lines=""
      current_id=""
      proposal_type=""
      proposal_target=""
      proposal_summary=""
      ;;
    *)
      if [ "$in_body" = true ]; then
        if [ -n "$body_lines" ]; then
          body_lines="${body_lines}"$'\n'"${line}"
        else
          body_lines="$line"
        fi
      fi
      ;;
  esac
done < "$PROPOSALS_FILE"

# Handle case where file ends without final ---
if [ "$in_pending" = true ] && [ -n "$proposal_id" ] && [ -z "$proposal_body" ]; then
  proposal_body="$body_lines"
fi

if [ -z "$proposal_id" ]; then
  echo "No pending proposals found."
  exit 0
fi

if [ "$ACTION" = "reject" ]; then
  # Update status to rejected
  PROP_ID="$proposal_id" awk '
    BEGIN { id=ENVIRON["PROP_ID"]; found=0 }
    $0 == "id="id { found=1 }
    found && /^status=pending/ { print "status=rejected"; found=0; next }
    { print }
  ' "$PROPOSALS_FILE" > "$PROPOSALS_FILE.tmp.$$" && mv "$PROPOSALS_FILE.tmp.$$" "$PROPOSALS_FILE"
  echo "Rejected proposal: ${proposal_id} (${proposal_summary:-no summary})"
  exit 0
fi

# --- APPROVE + APPLY ---
if [ -z "$proposal_type" ] || [ -z "$proposal_target" ]; then
  echo "Proposal ${proposal_id} missing type or target. Cannot auto-apply."
  exit 0
fi

# hook-rule type: flag for manual review, don't auto-apply
if [ "$proposal_type" = "hook-rule" ]; then
  PROP_ID="$proposal_id" awk '
    BEGIN { id=ENVIRON["PROP_ID"]; found=0 }
    $0 == "id="id { found=1 }
    found && /^status=pending/ { print "status=approved-manual"; found=0; next }
    { print }
  ' "$PROPOSALS_FILE" > "$PROPOSALS_FILE.tmp.$$" && mv "$PROPOSALS_FILE.tmp.$$" "$PROPOSALS_FILE"
  echo "Proposal ${proposal_id} approved but requires MANUAL review (hook-rule type). Edit ${proposal_target} yourself."
  exit 0
fi

# Check target file exists (for types that append)
if [ "$proposal_type" != "context-file" ] && [ ! -f "$proposal_target" ]; then
  PROP_ID="$proposal_id" awk '
    BEGIN { id=ENVIRON["PROP_ID"]; found=0 }
    $0 == "id="id { found=1 }
    found && /^status=pending/ { print "status=skipped"; found=0; next }
    { print }
  ' "$PROPOSALS_FILE" > "$PROPOSALS_FILE.tmp.$$" && mv "$PROPOSALS_FILE.tmp.$$" "$PROPOSALS_FILE"
  echo "Target file ${proposal_target} does not exist. Status set to skipped."
  exit 0
fi

# Empty body guard
if [ -z "$proposal_body" ]; then
  echo "Proposal ${proposal_id} has empty body. Cannot apply."
  exit 0
fi

# Duplicate detection: check if first line of body already exists in target
if [ -f "$proposal_target" ]; then
  first_line=$(echo "$proposal_body" | head -1)
  if [ -n "$first_line" ] && grep -qF "$first_line" "$proposal_target" 2>/dev/null; then
    PROP_ID="$proposal_id" awk '
      BEGIN { id=ENVIRON["PROP_ID"]; found=0 }
      $0 == "id="id { found=1 }
      found && /^status=pending/ { print "status=duplicate"; found=0; next }
      { print }
    ' "$PROPOSALS_FILE" > "$PROPOSALS_FILE.tmp.$$" && mv "$PROPOSALS_FILE.tmp.$$" "$PROPOSALS_FILE"
    echo "Proposal ${proposal_id} is a duplicate — content already exists in ${proposal_target}."
    exit 0
  fi
fi

# Apply based on type (all use append for safety)
case "$proposal_type" in
  lesson|context-keyword|skill-update|claude-md-amendment)
    printf '\n%s\n' "$proposal_body" >> "$proposal_target"
    ;;
  context-file)
    mkdir -p "$(dirname "$proposal_target")"
    printf '%s\n' "$proposal_body" > "$proposal_target"
    ;;
  *)
    echo "Unknown proposal type: ${proposal_type}. Cannot auto-apply."
    exit 0
    ;;
esac

# Update status to applied
TODAY=$(date +%Y-%m-%d)
PROP_ID="$proposal_id" TODAY="$TODAY" awk '
  BEGIN { id=ENVIRON["PROP_ID"]; td=ENVIRON["TODAY"]; found=0 }
  $0 == "id="id { found=1 }
  found && /^status=pending/ { print "status=applied"; print "applied_date="td; found=0; next }
  { print }
' "$PROPOSALS_FILE" > "$PROPOSALS_FILE.tmp.$$" && mv "$PROPOSALS_FILE.tmp.$$" "$PROPOSALS_FILE"

echo "Applied proposal ${proposal_id} (${proposal_type}) to ${proposal_target}: ${proposal_summary:-no summary}"
exit 0
