#!/usr/bin/env bash
# Shared state file I/O — SANCTIONED LEGACY READER, sourced only by
# hooks/session-start (until v4.2). Provides PROJECT_DIR, STATE_FILE,
# HEALTH_FILE, PROPOSALS_FILE constants and READ-ONLY access to the flat
# key=value state file.
#
# The write surface (write_field, increment_field, append_to_section,
# validate_state_file, init_state_file, resolve_state_file) was deleted —
# hooks now write exclusively through the append-only event log
# (hooks/scripts/lib/event-io.sh). What remains here reads whatever legacy
# state files still exist on disk and migrates/cleans them up.
#
# Session-scoped state files: each Claude Code session got its own state file
# (cortex-state-{session_id}.local.md) to avoid collisions when running
# multiple sessions concurrently. Shared files (health, proposals, decisions)
# remain singleton.

PROJECT_DIR="${CORTEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${PROJECT_DIR}/.claude"                      # UNCHANGED — other tools depend on this
CORTEX_DIR="${STATE_DIR}/cortex"                        # NEW — cortex-specific subdir
SESSIONS_DIR="${CORTEX_DIR}/sessions"                   # NEW — weekly-bucketed session files
# STATE_FILE has no writer anymore; default fallback for scripts that read it
# without resolving a specific session file:
STATE_FILE="${SESSIONS_DIR}/fallback.local.md"
HEALTH_FILE="${CORTEX_DIR}/health.local.md"
PROPOSALS_FILE="${CORTEX_DIR}/proposals.local.md"
DECISIONS_FILE="${CORTEX_DIR}/decisions.local.md"

# cleanup_stale_state_files
# Removes legacy FLAT state files from .claude/ root (migration leftovers).
# Does NOT touch anything inside sessions/ — no auto-pruning of week dirs.
cleanup_stale_state_files() {
  local cutoff_epoch
  cutoff_epoch=$(date -d "24 hours ago" +%s 2>/dev/null || date -v-24H +%s 2>/dev/null || echo "0")
  [ "$cutoff_epoch" -eq 0 ] && return 0

  # Remove flat legacy cortex-state-*.local.md stragglers (should have been migrated)
  for f in "${STATE_DIR}"/cortex-state-*.local.md; do
    [ -f "$f" ] || continue
    local file_epoch
    file_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
    if [ "$file_epoch" -gt 0 ] && [ "$file_epoch" -lt "$cutoff_epoch" ]; then
      rm -f "$f"
    fi
  done

  # Clean up legacy undercurrent-state-*.local.md files unconditionally
  for f in "${STATE_DIR}"/undercurrent-state-*.local.md; do
    [ -f "$f" ] || continue
    rm -f "$f"
  done

  # Delete the massive legacy singleton unconditionally (pre-session-scoping artifact)
  rm -f "${STATE_DIR}/undercurrent-state.local.md" 2>/dev/null || true

  # Also remove legacy single cortex file if stale
  local legacy="${STATE_DIR}/cortex-state.local.md"
  if [ -f "$legacy" ]; then
    local file_epoch
    file_epoch=$(stat -c %Y "$legacy" 2>/dev/null || stat -f %m "$legacy" 2>/dev/null || echo "0")
    if [ "$file_epoch" -gt 0 ] && [ "$file_epoch" -lt "$cutoff_epoch" ]; then
      rm -f "$legacy"
    fi
  fi
}

# migrate_state_files
# Two-phase migration:
# Phase 1 (legacy): undercurrent-* → cortex-* flat files (pre-v3.3)
# Phase 2 (v3.7): flat cortex-* → cortex/sessions/YYYY-WNN/ weekly buckets
migrate_state_files() {
  # Skip in CI — no real state files to migrate
  [ "${CI:-}" = "true" ] && return 0

  # === Phase 1: undercurrent-* → cortex-* (flat, same as before) ===

  # --- Health file merge ---
  local old_health="${STATE_DIR}/undercurrent-health.local.md"
  local flat_health="${STATE_DIR}/cortex-health.local.md"
  if [ -f "$old_health" ]; then
    if [ -f "$flat_health" ]; then
      local old_data
      old_data=$(sed -n '/^---$/,$p' "$old_health" 2>/dev/null | tail -n +2)
      if [ -n "$old_data" ]; then
        local existing_rows
        existing_rows=$(sed -n '/^---$/,$p' "$flat_health" 2>/dev/null | tail -n +2)
        while IFS= read -r row; do
          [ -z "$row" ] && continue
          if [ -z "$existing_rows" ] || ! echo "$existing_rows" | grep -qxF "$row" 2>/dev/null; then
            ROW_DATA="$row" awk '/^---$/ { print; print ENVIRON["ROW_DATA"]; next } { print }' \
              "$flat_health" > "$flat_health.tmp.$$" && mv "$flat_health.tmp.$$" "$flat_health"
          fi
        done <<< "$old_data"
      fi
      local old_avg_misses
      old_avg_misses=$(grep '^avg_reasoning_misses=' "$old_health" 2>/dev/null | cut -d= -f2-)
      local new_avg_misses
      new_avg_misses=$(grep '^avg_reasoning_misses=' "$flat_health" 2>/dev/null | cut -d= -f2-)
      if [ "${new_avg_misses:-0.0}" = "0.0" ] && [ -n "$old_avg_misses" ] && [ "$old_avg_misses" != "0.0" ]; then
        for field in avg_reasoning_misses avg_edits_per_commit avg_duration_min; do
          local old_val
          old_val=$(grep "^${field}=" "$old_health" 2>/dev/null | cut -d= -f2-)
          if [ -n "$old_val" ]; then
            sed "s|^${field}=.*|${field}=${old_val}|" "$flat_health" > "$flat_health.tmp.$$" \
              && mv "$flat_health.tmp.$$" "$flat_health"
          fi
        done
      fi
      rm -f "$old_health"
      echo "migrate_state_files: merged undercurrent health into cortex" >&2
    else
      mv "$old_health" "$flat_health" 2>/dev/null || true
    fi
  fi

  # --- Proposals/decisions: simple rename ---
  for suffix in proposals decisions; do
    local old_f="${STATE_DIR}/undercurrent-${suffix}.local.md"
    local new_f="${STATE_DIR}/cortex-${suffix}.local.md"
    if [ -f "$old_f" ]; then
      [ -f "$new_f" ] && rm -f "$old_f" || mv "$old_f" "$new_f" 2>/dev/null || true
    fi
  done

  # --- Session-scoped: undercurrent-state-* → cortex-state-* ---
  for old_file in "${STATE_DIR}"/undercurrent-state-*.local.md; do
    [ -f "$old_file" ] || continue
    local new_file="${old_file/undercurrent-/cortex-}"
    [ -f "$new_file" ] || mv "$old_file" "$new_file" 2>/dev/null || true
  done

  # === Phase 2: v3.7 directory reorganization ===
  # Sentinel check — skip if already migrated
  if [ -f "${CORTEX_DIR}/.migrated-v3.7" ]; then
    return 0
  fi

  # Create target directories
  mkdir -p "${CORTEX_DIR}" "${SESSIONS_DIR}"

  # --- Move singletons from flat .claude/ to cortex/ subdir ---
  for pair in \
    "cortex-health.local.md:health.local.md" \
    "cortex-proposals.local.md:proposals.local.md" \
    "cortex-decisions.local.md:decisions.local.md" \
    "cortex-cross-session.local.md:cross-session.local.md" \
    "cortex-profile.local:profile.local"; do
    local old_name="${pair%%:*}"
    local new_name="${pair##*:}"
    if [ -f "${STATE_DIR}/${old_name}" ]; then
      mv "${STATE_DIR}/${old_name}" "${CORTEX_DIR}/${new_name}" 2>/dev/null || true
      echo "migrate_state_files: moved ${old_name} → cortex/${new_name}" >&2
    fi
  done

  # --- Move session files into weekly buckets ---
  for f in "${STATE_DIR}"/cortex-state-*.local.md; do
    [ -f "$f" ] || continue
    # Get mtime epoch for week computation
    local file_epoch
    file_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
    local week
    if [ "$file_epoch" -gt 0 ]; then
      # Use ENVIRON pattern to avoid awk -v path mangling on Windows
      week=$(EPOCH="$file_epoch" bash -c 'date -d @"$EPOCH" +%G-W%V 2>/dev/null || date -r "$EPOCH" +%G-W%V 2>/dev/null || echo "unknown"')
    else
      week="unknown"
    fi
    # Extract session_id: strip prefix and suffix
    local base
    base=$(basename "$f")
    local sid="${base#cortex-state-}"
    sid="${sid%.local.md}"
    mkdir -p "${SESSIONS_DIR}/${week}"
    mv "$f" "${SESSIONS_DIR}/${week}/${sid}.local.md" 2>/dev/null || true
    echo "migrate_state_files: moved ${base} → sessions/${week}/${sid}.local.md" >&2
  done

  # --- Also move the legacy singleton cortex-state.local.md ---
  if [ -f "${STATE_DIR}/cortex-state.local.md" ]; then
    local sid
    sid=$(grep '^session_id=' "${STATE_DIR}/cortex-state.local.md" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    sid="${sid:-legacy}"
    local week
    week=$(date +%G-W%V 2>/dev/null || echo "unknown")
    mkdir -p "${SESSIONS_DIR}/${week}"
    mv "${STATE_DIR}/cortex-state.local.md" "${SESSIONS_DIR}/${week}/${sid}.local.md" 2>/dev/null || true
    echo "migrate_state_files: moved cortex-state.local.md → sessions/${week}/${sid}.local.md" >&2
  fi

  # --- Delete known junk files ---
  rm -f "${STATE_DIR}/old_state.md" 2>/dev/null || true
  rm -f "${STATE_DIR}/hook-fire-test.txt" 2>/dev/null || true
  rm -f "${STATE_DIR}/trace.log" 2>/dev/null || true
  rm -f "${STATE_DIR}/session-end-diagnostic.log" 2>/dev/null || true

  # Write sentinel
  echo "migrated $(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" > "${CORTEX_DIR}/.migrated-v3.7"
  echo "migrate_state_files: v3.7 migration complete" >&2
}

# read_field "field_name" "file_path"
# Returns the value for a key=value field. Empty string if not found.
read_field() {
  local field="$1"
  local file="${2:-$STATE_FILE}"
  if [ ! -f "$file" ]; then echo ""; return 0; fi
  grep "^${field}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true
}

# read_section "section_name" "file_path"
# Returns all lines between [section_name] and the next [section] header.
read_section() {
  local section="$1"
  local file="${2:-$STATE_FILE}"
  if [ ! -f "$file" ]; then echo ""; return 0; fi
  awk '/^\['"$section"'\]/{found=1;next} /^\[.*\]$/{found=0} found' "$file" | tr -d '\r' | sed '/^$/d'
}

# normalize_path "path"
# Normalizes a file path: backslash → forward slash, lowercase drive → uppercase.
# Used to prevent duplicate tracking of the same file with different path formats.
normalize_path() {
  local p="$1"
  # Backslash → forward slash
  p="${p//\\//}"
  # MSYS path /c/Users/... → C:/Users/...
  if [[ "$p" =~ ^/([a-zA-Z])/ ]]; then
    p="${BASH_REMATCH[1]^^}:/${p:3}"
  fi
  # Lowercase drive letter → uppercase (c:/ → C:/)
  if [[ "$p" =~ ^[a-z]:/ ]]; then
    p="${p^}"
  fi
  echo "$p"
}

# get_profile
# Returns the active Cortex profile: minimal, standard (default), or strict.
# Resolution: CORTEX_PROFILE env var → cortex/profile.local file → "standard".
get_profile() {
  local profile="${CORTEX_PROFILE:-}"
  if [ -z "$profile" ] && [ -f "${CORTEX_DIR:-}/profile.local" ]; then
    profile=$(head -1 "${CORTEX_DIR}/profile.local" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$profile" in
    minimal|strict) echo "$profile" ;;
    *) echo "standard" ;;
  esac
}

# Run migration on source (rename undercurrent-* -> cortex-*)
# Guard: only run once per process tree (prevents redundant work when sourced multiple times)
if [ "${_CORTEX_STATE_IO_MIGRATED:-}" != "1" ]; then
  migrate_state_files
  _CORTEX_STATE_IO_MIGRATED=1
fi
