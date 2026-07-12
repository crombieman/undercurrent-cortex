#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh" || { printf '{}'; exit 0; }

# The --native flag + native-hooks.ok marker suppression protocol is DELETED
# (calibration wave T5): it existed to suppress stale settings.json
# bootstrap-era entries, and T4 verified that era's entries are gone before
# deleting the cleanup machinery. A leftover marker file on disk is inert.

# Buffer stdin (SessionEnd may or may not provide JSON)
INPUT=$(cat)

# session_id, extracted once up front — (v2) the health row's own session_id
# field / per-sid dedup key. Same extraction resolve_event_log uses
# internally, so this is guaranteed to match whatever EVENT_LOG resolves to.
SESSION_ID=$(_eio_extract_sid "$INPUT")

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

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

# HEALTH_FILE deliberately does NOT derive from the locally-resolved
# (possibly EVENT_LOG-overridden) PROJECT_DIR above — it goes through the W4
# global helper instead (eio_health_file, re-resolves via _eio_project_dir()).
# Those two are always equal within a single invocation — see task report.
HEALTH_FILE="$(eio_health_file)"

# --- Compute metrics (v2: git-derived core + self-report demoted to a single
# labeled last column — spec §6.1) ---
today=$(date +%Y-%m-%d)
journal="${PROJECT_DIR}/memory/${today}.md"

# self_misses: journal [reasoning-miss] count, computed EXACTLY as v3 did
# (kept verbatim — labeled self-report, drives nothing downstream).
# Note: grep -c outputs "0" AND exits non-zero on no match. Using || echo 0
# produces "0\n0" (double output). Guard with grep -q first (lessons.md).
self_misses=0
if [ -f "$journal" ] && grep -q '\[reasoning-miss\]' "$journal" 2>/dev/null; then
  self_misses=$(grep -c '\[reasoning-miss\]' "$journal" 2>/dev/null)
fi

# material_edits — straight event-log count, whole session.
material_edits=$(count_events file_edit r)
material_edits="${material_edits:-0}"
# commits: GIT-derived below, from the SAME --since window as fix_or_revert
# (calibration wave, queue item 3 — same-provenance: the event-count
# denominator under a git-count numerator produced impossible ratios like
# 5.00 live). Event-log commit events remain the Gate-1 anchor only; the
# ROW's commit fields are pure git. No git repo ⇒ the count is unknowable ⇒
# 0 commits + null fix_ratio, never the event count. These are REPO-WINDOW
# observations (any actor's commit in the checkout during the session window).
commits=0

# files_modified: ALL file_edit paths (r + x), flag stripped — feeds topology/
# max_re_edits below. (The cross-session tracker it also used to feed was
# retired in wave 5 — hot files derive from the logs via eio_hot_files.)
files_modified=$(list_events file_edit | sed 's/^[rx] //')

# session_start / start_epoch — anchor for duration_min AND the git-derived
# windows below (fix_ratio/reverts/rework_files all key off it).
session_start_event=$(last_event session_start)
session_start="${session_start_event%% *}"
start_epoch=0
if [ -n "$session_start" ] && [ "$session_start" != "PLACEHOLDER_TIME" ] && [ "$session_start" != "unknown" ]; then
  # C-2 fix: replace ISO 8601 T separator with space for GNU date
  start_epoch=$(date -d "${session_start/T/ }" +%s 2>/dev/null || echo "0")
fi

# duration_min: session_start → now.
duration_min=0
if [ "$start_epoch" -gt 0 ]; then
  now_epoch=$(date +%s)
  duration_min=$(( (now_epoch - start_epoch) / 60 ))
fi

# max_re_edits / topology — UNCHANGED from v3 (r+x file_edit re-edit counts).
# No "idle" topology state in v2: idle semantics now live solely in `domain`
# (below), computed from r-flagged edits specifically.
max_re_edits=0
topology="focused"
if [ -n "$files_modified" ]; then
  max_re_edits=$(echo "$files_modified" | sort | uniq -c | awk '{print $1}' | sort -rn | head -n 1)
  max_re_edits="${max_re_edits:-0}"
  if [ "$max_re_edits" -ge 6 ]; then
    topology="high-churn"
  elif [ "$max_re_edits" -ge 3 ]; then
    topology="iterating"
  fi
fi

# --- Domain tagging (v2, spec §6.1): most-frequent FIRST path segment of
# r-flagged file_edit paths, relative to PROJECT_DIR. Zero r-edits => idle
# (this is the v2 idle signal — trend/median readers filter on it). Ties or
# fewer than 3 r-edits => mixed (not enough signal, or genuinely split). ---
domain="idle"
if [ "$material_edits" -gt 0 ]; then
  domain="mixed"
  if [ "$material_edits" -ge 3 ]; then
    r_paths=$(list_events file_edit | grep '^r ' | sed 's/^r //' || true)
    if [ -n "$r_paths" ]; then
      pd_norm=$(normalize_path "$PROJECT_DIR")
      pd_norm="${pd_norm%/}"
      segments=""
      while IFS= read -r rp; do
        [ -z "$rp" ] && continue
        np=$(normalize_path "$rp")
        rel="$np"
        case "$np" in
          "$pd_norm"/*) rel="${np#"$pd_norm"/}" ;;
        esac
        seg="${rel%%/*}"
        [ -z "$seg" ] && continue
        segments="${segments}${seg}"$'\n'
      done <<< "$r_paths"
      if [ -n "$segments" ]; then
        counts=$(printf '%s\n' "$segments" | grep -v '^$' | sort | uniq -c | sort -rn \
          | awk '{ c = $1; $1 = ""; sub(/^[ \t]+/, ""); print c "|" $0 }')
        top_count=$(echo "$counts" | head -1 | cut -d'|' -f1)
        top_name=$(echo "$counts" | head -1 | cut -d'|' -f2-)
        second_count=$(echo "$counts" | sed -n '2p' | cut -d'|' -f1)
        if [ -n "$second_count" ] && [ "$second_count" = "$top_count" ]; then
          domain="mixed"
        elif [ -n "$top_name" ]; then
          domain="$top_name"
        fi
      fi
    fi
  fi
fi

# --- Git-derived metrics (v2 measurement core, spec §6.1) ---
has_git=false
if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  has_git=true
fi

fix_or_revert_count=0
reverts=0
if [ "$has_git" = true ] && [ "$start_epoch" -gt 0 ]; then
  commit_subjects=$(git -C "$PROJECT_DIR" log --since="$session_start" --format=%s 2>/dev/null || true)
  if [ -n "$commit_subjects" ]; then
    # commits = the same population the numerators count over (one subject
    # line per commit in the window) — same-provenance by construction.
    commits=$(printf '%s\n' "$commit_subjects" | wc -l | tr -d ' ')
    fix_or_revert_count=$(printf '%s\n' "$commit_subjects" | grep -icE '^(fix:|revert)' 2>/dev/null || true)
    reverts=$(printf '%s\n' "$commit_subjects" | grep -icE '^revert' 2>/dev/null || true)
  fi
fi
commits="${commits:-0}"
fix_or_revert_count="${fix_or_revert_count:-0}"
reverts="${reverts:-0}"

fix_ratio="null"
if [ "$commits" -gt 0 ]; then
  fix_ratio=$(awk "BEGIN { printf \"%.2f\", ${fix_or_revert_count} / ${commits} }")
fi

# rework_files: files committed THIS session that were ALSO touched by a
# commit in the 14 days immediately preceding session_start — a thrash/rework
# proxy. Empty repo or zero commits this session => 0 (gate on commits>0
# short-circuits without ever shelling out to git for the common no-op case).
rework_files=0
if [ "$has_git" = true ] && [ "$start_epoch" -gt 0 ] && [ "$commits" -gt 0 ]; then
  session_files=$(git -C "$PROJECT_DIR" log --name-only --since="$session_start" --pretty=format: 2>/dev/null | sed '/^$/d' | sort -u || true)
  if [ -n "$session_files" ]; then
    prior_epoch=$(( start_epoch - 14 * 86400 ))
    prior_start=$(date -u -d "@${prior_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${prior_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    if [ -n "$prior_start" ]; then
      prior_files=$(git -C "$PROJECT_DIR" log --name-only --since="$prior_start" --until="$session_start" --pretty=format: 2>/dev/null | sed '/^$/d' | sort -u || true)
      if [ -n "$prior_files" ]; then
        rework_files=$(comm -12 <(printf '%s\n' "$session_files") <(printf '%s\n' "$prior_files") | wc -l | tr -d ' ')
      fi
    fi
  fi
fi
rework_files="${rework_files:-0}"

# tests_pass
tests_pass="none"
[ "$(count_events test_run)" -gt 0 ] && tests_pass="pass"

# Cross-session file tracking RETIRED (wave 5, locked D6): hot files are
# derived at read from the week-bucket logs via eio_hot_files — no mutable
# cross-session.local.md writer anywhere. Legacy files on disk are inert.

# --- Dedup guard: per session_id (v2 rows), NOT date-wide (spec §6.1). A
# health_written event on THIS session's own log is still the fast path;
# the health-file scan additionally catches the case where health_written
# didn't make it to disk (crash) but the row itself did. ---
if grep '^v2|' "$HEALTH_FILE" 2>/dev/null | grep -qF "|${SESSION_ID}|"; then
  append_event "health_written" "$today"
  printf '{}'
  exit 0
fi
if [ "$(count_events health_written)" -gt 0 ]; then
  printf '{}'
  exit 0
fi

# --- Idle skip (calibration wave, queue item 5): a genuinely idle session —
# zero r-flagged edits AND zero commits in the git window — writes NO row.
# Idle/twin boots (which have both zeros) were 5 of 7 live v2 rows, drowning
# the trend denominator. A commits-only session is NOT idle: it keeps its row
# (domain stays "idle" as an edit-activity label; the trend's domain filter
# already excludes it from medians). health_written is still appended so the
# skill/dispatcher double-fire dedup above keeps working; the value records
# the skip. Placed BEFORE any file mutation: a skipped session leaves
# health.local.md untouched entirely (read-side idle filters in
# health-trend.sh stay as defense for legacy idle rows already on disk). ---
if [ "$domain" = "idle" ] && [ "${commits:-0}" -eq 0 ]; then
  append_event "health_written" "$today idle-skipped"
  printf '{}'
  exit 0
fi

# --- Write to health file ---
mkdir -p "$(dirname "$HEALTH_FILE")" 2>/dev/null || true

# The v3 header-strip rewrite is DELETED (calibration wave, queue item 7,
# with the healer): health.local.md is create-once + append-only — the ONLY
# writes anywhere are the header creation below and the row append. Legacy
# trend_*/avg_*/--- lines on old files simply persist; every reader already
# filters them. This ends the two-writer race class for good (lint-enforced).

# Create file with header if it doesn't exist (v2: no trend_*/avg_*/---
# metadata lines — those are read-time-only now). Deny-tolerant: creation
# failure in a read-only sandbox must not abort before JSON is emitted.
if [ ! -f "$HEALTH_FILE" ]; then
  cat > "$HEALTH_FILE" 2>/dev/null << 'HEADER' || true
# Cortex Health Log
# Fields: v2|date|session_id|commits|material_edits|fix_ratio|reverts|rework_files|tests_pass|duration_min|max_re_edits|topology|domain|self_misses
HEADER
fi

# Append v2 data row, then mark written ONLY on success (W5 review I-2):
# recording health_written before/without the row would make every future
# SessionEnd skip this session's row forever. Crash between row and marker is
# covered by the per-sid health-file grep dedup above (retry-storm-safe).
row_written=1
echo "v2|${today}|${SESSION_ID}|${commits}|${material_edits}|${fix_ratio}|${reverts}|${rework_files}|${tests_pass}|${duration_min}|${max_re_edits}|${topology}|${domain}|${self_misses}" >> "$HEALTH_FILE" 2>/dev/null || row_written=0
if [ "$row_written" -eq 1 ]; then
  append_event "health_written" "$today"
fi

# v3's rolling-average recompute (trend_direction=/avg_*= header rewrite) is
# GONE in v2 — trend is computed at READ time from v2 rows themselves
# (hooks/scripts/lib/health-trend.sh), never stored back into the file.

# v3's proposal-count warning (>50 ids => proposals_need_archiving flag) was
# dropped here: the flag was write-only-dead (never read anywhere), and
# proposals_need_archiving is not in the closed v4 event vocabulary (spec §3.3).
# The proposal-pruning concept moves to wave 4's pruning work.

printf '{}'
exit 0
