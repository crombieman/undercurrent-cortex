#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh" || { printf '{}'; exit 0; }

# Buffer stdin (SessionEnd may or may not provide JSON)
INPUT=$(cat)

# Resolve session-scoped event log from session_id in hook JSON. This script
# WRITES (health_written event), so it must use the write resolver — the
# readonly resolver's current-session.id marker fallback is for read surfaces
# only (spec §3.4).
resolve_event_log "$INPUT"

# Guard: event log must exist (session-start creates it). No legacy
# state-file fallback in v4 — the log IS the state.
if [ -z "$EVENT_LOG" ] || [ ! -f "$EVENT_LOG" ]; then
  printf '{}'
  exit 0
fi

# Bug 4 fix (preserved from v3): derive PROJECT_DIR from event log location,
# not cwd. Event log is at: {project}/.claude/cortex/sessions/YYYY-WNN/{sid}.events.log
# Navigate 4 levels up from the YYYY-WNN dir to reach the project root.
PROJECT_DIR="$(eio_project_dir)"
EVENT_LOG_PROJECT_DIR=$(cd "$(dirname "$EVENT_LOG")/../../../.." && pwd)
if [ -d "$EVENT_LOG_PROJECT_DIR/memory" ]; then
  PROJECT_DIR="$EVENT_LOG_PROJECT_DIR"
fi

CORTEX_DIR="${PROJECT_DIR}/.claude/cortex"
HEALTH_FILE="${CORTEX_DIR}/health.local.md"

# --- Compute metrics ---
today=$(date +%Y-%m-%d)
journal="${PROJECT_DIR}/memory/${today}.md"

# 1. reasoning_misses: count [reasoning-miss] tags in today's journal
# Note: grep -c outputs "0" AND exits non-zero on no match. Using || echo 0
# produces "0\n0" (double output). Guard with grep -q first (lessons.md).
reasoning_misses=0
if [ -f "$journal" ] && grep -q '\[reasoning-miss\]' "$journal" 2>/dev/null; then
  reasoning_misses=$(grep -c '\[reasoning-miss\]' "$journal" 2>/dev/null)
fi

# 2. edits_per_commit: total edit operations / max(commits, 1)
commits_count=$(count_events commit)
commits_count="${commits_count:-0}"
files_modified=$(list_events file_edit | sed 's/^[rx] //')
total_edits=0
if [ -n "$files_modified" ]; then
  total_edits=$(echo "$files_modified" | wc -l | tr -d ' ')
fi
divisor=$commits_count
[ "$divisor" -eq 0 ] && divisor=1
edits_per_commit=$(awk "BEGIN { printf \"%.1f\", $total_edits / $divisor }")

# 3. docs_synced
docs_synced=false
[ "$(count_events docs_edit)" -gt 0 ] && docs_synced=true

# 4. tests_delta: count test/spec files among file_edit paths (not unique —
# v3 counted every edit line, so a test file touched 3x counts as 3)
tests_delta=0
if [ -n "$files_modified" ]; then
  if echo "$files_modified" | grep -qE '\.(test|spec)\.' 2>/dev/null; then
    tests_delta=$(echo "$files_modified" | grep -cE '\.(test|spec)\.' 2>/dev/null)
  fi
fi

# 5. lessons_created: lines added to tasks/lessons.md (staged + unstaged)
lessons_created=0
if command -v git >/dev/null 2>&1; then
  diff_output=$(git -C "$PROJECT_DIR" diff HEAD -- tasks/lessons.md 2>/dev/null || true)
  if [ -n "$diff_output" ] && echo "$diff_output" | grep -q '^+[^+]' 2>/dev/null; then
    lessons_created=$(echo "$diff_output" | grep -c '^+[^+]' 2>/dev/null)
  fi
fi

# 6/7. carry_over resolution: count [carry-over] tags in today's journal
# Bug 3 fix: state file [carry_over] section is never populated — parse journal instead.
# Strikethrough ~~[carry-over]~~ marks resolved carry-overs.
carry_total=0
carry_resolved=0
if [ -f "$journal" ]; then
  if grep -q '\[carry-over\]' "$journal" 2>/dev/null; then
    carry_total=$(grep -c '\[carry-over\]' "$journal" 2>/dev/null)
  fi
  if grep -q '~~\[carry-over\]' "$journal" 2>/dev/null; then
    carry_resolved=$(grep -c '~~\[carry-over\]' "$journal" 2>/dev/null)
  fi
fi

# 8. duration_minutes: session_start → now. Event value is "<iso> <model>" —
# the first space-token is the timestamp (session-start hook contract).
session_start_event=$(last_event session_start)
session_start="${session_start_event%% *}"
duration_min=0
if [ -n "$session_start" ] && [ "$session_start" != "PLACEHOLDER_TIME" ] && [ "$session_start" != "unknown" ]; then
  # C-2 fix: replace ISO 8601 T separator with space for GNU date
  start_epoch=$(date -d "${session_start/T/ }" +%s 2>/dev/null || echo "0")
  now_epoch=$(date +%s)
  if [ "$start_epoch" -gt 0 ]; then
    duration_min=$(( (now_epoch - start_epoch) / 60 ))
  fi
fi

# 9/10. Topology classification from re-edit counts
max_re_edits=0
topology="focused"
if [ -n "$files_modified" ]; then
  # Find max edits to any single file
  max_re_edits=$(echo "$files_modified" | sort | uniq -c | awk '{print $1}' | sort -rn | head -n 1)
  max_re_edits="${max_re_edits:-0}"

  # Classify: focused (<=2), iterating (3-5), high-churn (6+)
  if [ "$max_re_edits" -ge 6 ]; then
    topology="high-churn"
  elif [ "$max_re_edits" -ge 3 ]; then
    topology="iterating"
  fi
fi

# --- Domain tagging ---
# Bug 1 fix: use project basename instead of regex path extraction.
# The regex [^/]+/[^/]+ breaks on Windows drive paths (C:/Users → domain_tag).
domain_tag="mixed"
if [ -n "$files_modified" ]; then
  domain_tag=$(basename "$PROJECT_DIR" 2>/dev/null || echo "unknown")
elif [ "${total_edits:-0}" -eq 0 ]; then
  domain_tag="idle"
fi

# --- Cross-session file tracking (runs before zero-metric skip) ---
# Cross-session tracks file edit patterns across sessions — this should happen
# regardless of whether we write a health row. Moved before zero-metric exit.
CROSS_FILE="${CORTEX_DIR}/cross-session.local.md"
if [ ! -f "$CROSS_FILE" ]; then
  {
    echo "# Cross-Session File Edit Tracker"
    echo "# Format: filepath|session_count|last_session_date"
  } > "$CROSS_FILE"
fi

if [ -n "$files_modified" ]; then
  unique_files=$(echo "$files_modified" | sort -u)
  while IFS= read -r raw_filepath; do
    [ -z "$raw_filepath" ] && continue
    # Fix 2: skip non-path lines (defensive — file_edit values are always
    # real paths in v4, but keeps parity with any malformed event values)
    echo "$raw_filepath" | grep -qE '[/\\]' || continue
    # Fix 1: Normalize path format (backslash→forward slash, lowercase drive→uppercase)
    filepath=$(normalize_path "$raw_filepath")
    # Skip plugin infrastructure files
    echo "$filepath" | grep -qE '\.claude-plugin/|\.claude/' && continue
    if grep -qF "${filepath}|" "$CROSS_FILE" 2>/dev/null; then
      old_count=$(grep -F "${filepath}|" "$CROSS_FILE" | head -1 | cut -d'|' -f2)
      new_count=$((old_count + 1))
      # Use awk + ENVIRON to avoid Windows path mangling
      FILEPATH="$filepath" NEWCOUNT="$new_count" TODAY="$today" awk '
        BEGIN { fp=ENVIRON["FILEPATH"]; nc=ENVIRON["NEWCOUNT"]; td=ENVIRON["TODAY"] }
        index($0, fp"|") == 1 { print fp"|"nc"|"td; next }
        { print }
      ' "$CROSS_FILE" > "$CROSS_FILE.tmp.$$" && mv "$CROSS_FILE.tmp.$$" "$CROSS_FILE"
    else
      echo "${filepath}|1|${today}" >> "$CROSS_FILE"
    fi
  done <<< "$unique_files"
fi

# Prune cross-session entries older than 30 days
cutoff=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "")
if [ -n "$cutoff" ] && [ -f "$CROSS_FILE" ]; then
  CUTOFF="$cutoff" awk -F'|' '
    /^#/ { print; next }
    NF < 3 { print; next }
    $3 >= ENVIRON["CUTOFF"] { print }
  ' "$CROSS_FILE" > "$CROSS_FILE.tmp.$$" && mv "$CROSS_FILE.tmp.$$" "$CROSS_FILE"
fi

# --- Skip health row if session had zero tracked activity (noise prevention) ---
# Tag idle sessions instead of skipping them. Previously this exited early,
# making ~60% of sessions invisible to health tracking. Now we tag them as
# idle and still write the row. Rolling averages exclude idle rows.
if [ "${total_edits:-0}" -eq 0 ] && [ "${commits_count:-0}" -eq 0 ] && \
   [ "${reasoning_misses:-0}" -eq 0 ] && [ "${tests_delta:-0}" -eq 0 ] && \
   [ "${lessons_created:-0}" -eq 0 ] && [ "${carry_total:-0}" -eq 0 ]; then
  topology="idle"
fi

# --- Dedup guard: prevent duplicate health writes if hook fires multiple times ---
# Also prevents duplicates when the session-end skill calls this script AND the
# SessionEnd hook fires afterward.
# Bug 2 fix: also check global health file for today's date (per-session flag
# doesn't prevent different sessions on the same day from writing duplicate rows).
if grep -q "^${today}|" "$HEALTH_FILE" 2>/dev/null; then
  append_event "health_written" "$today"
  printf '{}'
  exit 0
fi
if [ "$(count_events health_written)" -gt 0 ]; then
  printf '{}'
  exit 0
fi
# Mark as written — appended before the health-file write itself (matches v3
# ordering: a crash mid-write still leaves this session flagged, avoiding a
# retry storm on the next SessionEnd fire).
append_event "health_written" "$today"

# --- Write to health file ---
mkdir -p "$(dirname "$HEALTH_FILE")"

# Create file with header if it doesn't exist
if [ ! -f "$HEALTH_FILE" ]; then
  cat > "$HEALTH_FILE" << 'HEADER'
# Cortex Health Log
# Fields: date|reasoning_misses|edits_per_commit|docs_synced|tests_delta|lessons_created|carry_resolved|carry_total|duration_min|max_re_edits|topology|domain_tag
trend_direction=stable
avg_reasoning_misses=0.0
avg_edits_per_commit=0.0
avg_duration_min=0
---
HEADER
fi

# Append data row (12 fields — old rows with 11 are backward-compatible)
echo "${today}|${reasoning_misses}|${edits_per_commit}|${docs_synced}|${tests_delta}|${lessons_created}|${carry_resolved}|${carry_total}|${duration_min}|${max_re_edits}|${topology}|${domain_tag}" >> "$HEALTH_FILE"

# --- Recompute rolling averages from last 10 data lines ---
# Use ALL rows for session count/trend, but EXCLUDE idle rows from epc/duration averages.
# Old rows (11 fields) without topology field are treated as non-idle.
data_lines=$(grep -v '^#' "$HEALTH_FILE" | grep -v '^$' | grep -v '^trend_' | grep -v '^avg_' | grep -v '^---' | grep '|' | tail -10)
line_count=$(echo "$data_lines" | wc -l | tr -d ' ')

if [ "$line_count" -ge 1 ]; then
  # Compute averages — reasoning_misses uses ALL rows, epc/duration exclude idle
  read -r avg_rm avg_epc avg_dur <<< $(echo "$data_lines" | awk -F'|' '{
    rm += $2; rm_count++
    # Field 11 is topology — exclude idle rows from epc/duration averages
    if (NF < 11 || $11 != "idle") { epc += $3; dur += $9; active_count++ }
  } END {
    if (active_count == 0) active_count = 1
    printf "%.1f %.1f %d", rm/rm_count, epc/active_count, dur/active_count
  }')

  # Trend detection: compare last 3 vs prior sessions (requires 6+ data points)
  trend="stable"
  if [ "$line_count" -ge 6 ]; then
    recent_3_misses=$(echo "$data_lines" | tail -3 | awk -F'|' '{s+=$2} END {printf "%.1f", s/3}')
    prior_misses=$(echo "$data_lines" | head -n -3 | tail -4 | awk -F'|' '{s+=$2; c++} END {if(c>0) printf "%.1f", s/c; else printf "0.0"}')
    trend=$(awk "BEGIN {
      diff = $recent_3_misses - $prior_misses
      if (diff > 0.5) print \"degrading\"
      else if (diff < -0.5) print \"improving\"
      else print \"stable\"
    }")
  fi

  # M-2 fix: single awk pass to update all header fields atomically
  awk -v trend="$trend" -v arm="$avg_rm" -v aepc="$avg_epc" -v adur="$avg_dur" '
    /^trend_direction=/ { print "trend_direction=" trend; next }
    /^avg_reasoning_misses=/ { print "avg_reasoning_misses=" arm; next }
    /^avg_edits_per_commit=/ { print "avg_edits_per_commit=" aepc; next }
    /^avg_duration_min=/ { print "avg_duration_min=" adur; next }
    { print }
  ' "$HEALTH_FILE" > "$HEALTH_FILE.tmp.$$" && mv "$HEALTH_FILE.tmp.$$" "$HEALTH_FILE"
fi

# v3's proposal-count warning (>50 ids => proposals_need_archiving flag) was
# dropped here: the flag was write-only-dead (never read anywhere), and
# proposals_need_archiving is not in the closed v4 event vocabulary (spec §3.3).
# The proposal-pruning concept moves to wave 4's pruning work.

printf '{}'
exit 0
