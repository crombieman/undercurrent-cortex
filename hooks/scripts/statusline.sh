#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh" || exit 0
source "$SCRIPT_DIR/lib/health-trend.sh" || exit 0

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup or session-start's grandfathering check. Plain exit (text
# surface, no JSON wrapper). statusline is invoked directly by /status, not
# only via already-gated dispatchers, so it needs its own gate.
[ -f "$(_eio_cortex_dir)/enabled" ] || exit 0

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

# --- Line 2 data: organism health (v2: read-time trend from health-trend.sh,
# spec §6.2 — no more trend_direction=/avg_reasoning_misses= header fields;
# those are computed from v2 rows here, never stored). ---
ht_result=$(ht_trend "$HEALTH_FILE")
IFS='|' read -r ht_total ht_nonidle ht_verdict _ht_reason <<< "$ht_result"

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

# heart/status default to a neutral "adapting" — covers both a genuinely
# stable trend AND "not enough data yet" (below the 10-non-idle-v2-row
# threshold). v3's zero-avg-misses-implies-thriving default is gone with
# self-report demotion; there's no equivalent v2 signal to substitute.
heart="💛"; status="adapting"

if [ "$mode" = "cautious" ]; then
  heart="🧡"; status="cautious"
elif [ "$ht_verdict" = "degrading" ]; then
  heart="❤️‍🩹"; status="stressed"
elif [ "$ht_verdict" = "improving" ]; then
  heart="💚"; status="thriving"
fi

# Trailing trend segment: below the read threshold, show the honest raw
# session count instead of an arrow/verdict pair (spec §6.2 — "📊 N sessions
# tracked — trend at 10"; N = ht_total, which counts legacy rows too).
if [ -z "$ht_verdict" ]; then
  trend_segment="📊 ${ht_total} sessions tracked — trend at 10"
else
  arrow="→"
  case "$ht_verdict" in
    improving) arrow="↗" ;;
    degrading) arrow="↘" ;;
  esac
  trend_segment="${arrow} ${ht_verdict}"
fi

# --- Output ---
printf '✏️  %s edits · 📦 %s commits · 🧪%s · 📄%s\n' "$edits" "$commits" "$tests_icon" "$docs_icon"
printf '%s %s │ 🧠 %s absorbed │ 🧬 %s mutations queued │ %s\n' "$heart" "$status" "$lessons" "$proposals" "$trend_segment"
