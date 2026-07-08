#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh" || exit 0

# Resolve event log — read-only surface (statusline never appends). Falls
# back to current-session.id when the hook JSON arg lacks a session_id
# (spec §3.4: appends require write resolution, but reads may use the marker).
resolve_event_log_readonly "${1:-}"

PROJECT_DIR="$(eio_project_dir)"
HEALTH_FILE="$(eio_health_file)"
PROPOSALS_FILE="$(eio_proposals_file)"

# --- Line 1 data: session activity ---
edits=$(count_events file_edit r commit)
edits="${edits:-0}"
commits=$(count_events commit)
commits="${commits:-0}"

tests_icon="❌"; [ "$(count_events test_run)" -gt 0 ] && tests_icon="✅"

docs_icon="❌"; [ "$(count_events docs_edit)" -gt 0 ] && docs_icon="✅"

# --- Line 2 data: organism health ---
trend="stable"
avg_misses="0.0"
if [ -f "$HEALTH_FILE" ]; then
  trend=$(grep '^trend_direction=' "$HEALTH_FILE" 2>/dev/null | cut -d= -f2 | tr -d '\r' || true)
  trend="${trend:-stable}"
  avg_misses=$(grep '^avg_reasoning_misses=' "$HEALTH_FILE" 2>/dev/null | cut -d= -f2 | tr -d '\r' || true)
  avg_misses="${avg_misses:-0.0}"
fi

# Lessons count (## headings in tasks/lessons.md)
lessons=0
lessons_file="${PROJECT_DIR}/tasks/lessons.md"
if [ -f "$lessons_file" ]; then
  if grep -q '^## ' "$lessons_file" 2>/dev/null; then
    lessons=$(grep -c '^## ' "$lessons_file" 2>/dev/null)
  fi
fi

# Pending proposals
proposals=0
if [ -f "$PROPOSALS_FILE" ]; then
  if grep -q '^status=pending' "$PROPOSALS_FILE" 2>/dev/null; then
    proposals=$(grep -c '^status=pending' "$PROPOSALS_FILE" 2>/dev/null)
  fi
fi

# Heart + status + arrow
mode=$(last_event mode_set)
mode="${mode%% *}"
mode="${mode:-normal}"

heart="💛"; status="adapting"; arrow="→"
case "$trend" in
  improving) arrow="↗" ;;
  degrading) arrow="↘" ;;
  *) arrow="→" ;;
esac

if [ "$mode" = "cautious" ]; then
  heart="🧡"; status="cautious"
elif [ "$trend" = "degrading" ]; then
  heart="❤️‍🩹"; status="stressed"
elif [ "$trend" = "improving" ]; then
  heart="💚"; status="thriving"
else
  # stable — thriving if zero misses, adapting otherwise
  zero_misses=$(awk "BEGIN { print ($avg_misses == 0) }" 2>/dev/null || echo "0")
  if [ "$zero_misses" = "1" ]; then
    heart="💚"; status="thriving"
  fi
fi

# --- Output ---
printf '✏️  %s edits · 📦 %s commits · 🧪%s · 📄%s\n' "$edits" "$commits" "$tests_icon" "$docs_icon"
printf '%s %s │ 🧠 %s absorbed │ 🧬 %s mutations queued │ %s %s\n' "$heart" "$status" "$lessons" "$proposals" "$arrow" "$trend"
