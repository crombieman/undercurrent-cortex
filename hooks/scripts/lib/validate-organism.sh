#!/usr/bin/env bash
# Healing/Repair System — Organism v3, System 10 (slimmed v4).
# The state-file corruption/clamp/dedup checks were deleted: their patients
# (active state-file mutation) died when hooks moved to the append-only event
# log (event-io.sh). What remains: health-file self-repair, temp/backup
# cleanup, cross-session pruning, and week-bucket dir pruning (new in v4).
# Sourced by session-start, after state-io.sh (for STATE_FILE/HEALTH_FILE/
# PROPOSALS_FILE/DECISIONS_FILE/CORTEX_DIR/PROJECT_DIR).

# Source event-io defensively for the week-dir path helpers (_eio_sessions_dir,
# _eio_week_dir). session-start already sources both state-io.sh and
# event-io.sh before this file — guard against double-sourcing when
# validate-organism.sh is tested/sourced standalone.
if ! type _eio_sessions_dir &>/dev/null; then
  _VALIDATE_ORGANISM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_VALIDATE_ORGANISM_DIR/event-io.sh"
fi

# sanitize_json_field "value"
# Returns empty if value contains newlines or exceeds 200 chars.
sanitize_json_field() {
  local val="$1"
  case "$val" in
    *$'\n'*) echo ""; return 0 ;;
  esac
  if [ "${#val}" -gt 200 ]; then
    echo ""
    return 0
  fi
  echo "$val"
}

# validate_organism
# Returns "issues|repairs|detail1, detail2, ..." via stdout.
# Call from session-start BEFORE reading carry-over from the old state file.
validate_organism() {
  local issues=0 repairs=0 details=""
  local claude_dir
  claude_dir="$(dirname "$STATE_FILE")"

  # --- 1. Health file header recovery ---
  if [ -f "$HEALTH_FILE" ]; then
    if ! grep -q '^trend_direction=' "$HEALTH_FILE" 2>/dev/null; then
      # Extract data rows (contain |), rebuild header + data
      local data_rows
      data_rows=$(grep '|' "$HEALTH_FILE" 2>/dev/null || echo "")
      {
        echo "trend_direction=stable"
        echo "avg_reasoning_misses=0.0"
        echo "avg_edits_per_commit=0.0"
        echo "avg_duration_min=0"
        echo "---"
        if [ -n "$data_rows" ]; then
          echo "$data_rows"
        fi
      } > "$HEALTH_FILE.tmp.$$" && mv "$HEALTH_FILE.tmp.$$" "$HEALTH_FILE"
      issues=$((issues + 1))
      repairs=$((repairs + 1))
      details="${details}rebuilt health file header, "
    fi
  fi

  # --- 2. Health file pruning (>500 lines → header + last 200 rows) ---
  if [ -f "$HEALTH_FILE" ]; then
    local total_lines=0
    total_lines=$(wc -l < "$HEALTH_FILE" | tr -d ' ')
    if [ "${total_lines:-0}" -gt 500 ]; then
      # Keep header (non-pipe lines before first pipe line) + last 200 data rows
      local header_lines data_rows
      header_lines=$(awk '/\|/ { exit } { print }' "$HEALTH_FILE")
      data_rows=$(grep '|' "$HEALTH_FILE" 2>/dev/null | tail -200)
      {
        echo "$header_lines"
        if [ -n "$data_rows" ]; then
          echo "$data_rows"
        fi
      } > "$HEALTH_FILE.tmp.$$" && mv "$HEALTH_FILE.tmp.$$" "$HEALTH_FILE"
      issues=$((issues + 1))
      repairs=$((repairs + 1))
      details="${details}pruned health file from ${total_lines} to ~200 rows, "
    fi
  fi

  # --- 3-4. Proposals + decisions file separator check ---
  for f in "$PROPOSALS_FILE" "$DECISIONS_FILE"; do
    if [ -f "$f" ] && ! grep -q '^---' "$f" 2>/dev/null; then
      echo "---" >> "$f"
      issues=$((issues + 1))
      repairs=$((repairs + 1))
      details="${details}added separator to $(basename "$f"), "
    fi
  done

  # --- 5. Temp file cleanup ---
  local stale=0
  if [ -d "$claude_dir" ]; then
    stale=$(find "$claude_dir" -maxdepth 1 -name "*.tmp.*" -mmin +60 2>/dev/null | wc -l | tr -d ' ')
    if [ "${stale:-0}" -gt 0 ]; then
      find "$claude_dir" -maxdepth 1 -name "*.tmp.*" -mmin +60 -delete 2>/dev/null || true
      issues=$((issues + 1))
      repairs=$((repairs + 1))
      details="${details}cleaned ${stale} stale temp files, "
    fi
  fi

  # --- 6. Cross-session file pruning (>500 lines) ---
  local cross_file="${CORTEX_DIR:-${PROJECT_DIR}/.claude/cortex}/cross-session.local.md"
  if [ -f "$cross_file" ]; then
    local cross_lines
    cross_lines=$(wc -l < "$cross_file" | tr -d ' ')
    if [ "${cross_lines:-0}" -gt 500 ]; then
      local cutoff
      cutoff=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "")
      if [ -n "$cutoff" ]; then
        CUTOFF="$cutoff" awk -F'|' '
          /^#/ { print; next }
          NF < 3 { print; next }
          $3 >= ENVIRON["CUTOFF"] { print }
        ' "$cross_file" > "$cross_file.tmp.$$" && mv "$cross_file.tmp.$$" "$cross_file"
        local new_lines
        new_lines=$(wc -l < "$cross_file" | tr -d ' ')
        issues=$((issues + 1))
        repairs=$((repairs + 1))
        details="${details}pruned cross-session file from ${cross_lines} to ${new_lines} lines, "
      fi
    fi
  fi

  # --- 7. Old backup cleanup (>7 days) ---
  if [ -d "$claude_dir" ]; then
    local old_backups=0
    old_backups=$(find "$claude_dir" -maxdepth 1 -name "state-backup-*" -mmin +10080 2>/dev/null | wc -l | tr -d ' ')
    if [ "${old_backups:-0}" -gt 0 ]; then
      find "$claude_dir" -maxdepth 1 -name "state-backup-*" -mmin +10080 -delete 2>/dev/null || true
      issues=$((issues + 1))
      repairs=$((repairs + 1))
      details="${details}cleaned ${old_backups} old state backups, "
    fi
  fi

  # --- 8. Week-bucket dir pruning (>90 days) ---
  # A week dir is prunable when its OWN mtime AND every file it contains have
  # an mtime older than 90 days. The current week dir is NEVER touched, even
  # if its mtime looks stale (e.g. clock skew) — guarded by path comparison,
  # not just age.
  local wbd_sessions_dir wbd_current_week
  wbd_sessions_dir="$(_eio_sessions_dir)"
  wbd_current_week="$(_eio_week_dir)"
  if [ -d "$wbd_sessions_dir" ]; then
    local wbd_cutoff
    wbd_cutoff=$(date -d "90 days ago" +%s 2>/dev/null || date -v-90d +%s 2>/dev/null || echo "0")
    if [ "$wbd_cutoff" -gt 0 ]; then
      local d
      for d in "$wbd_sessions_dir"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        # Never touch the current week dir.
        [ "$d" = "${wbd_current_week%/}" ] && continue
        # Never follow a symlink standing in for a week dir. `[ -d "$d" ]`
        # above resolves through symlinks, so a symlink named like an ISO
        # week bucket would otherwise reach the delete/rmdir below and the
        # `find ... -delete` would follow it straight into whatever external
        # directory it points at.
        [ -L "$d" ] && continue
        # Only ISO-week-named buckets (YYYY-WNN) are prunable — never stray
        # dirs (test fixtures, manual backups) that happen to live under
        # sessions/, no matter how old they are.
        case "$(basename "$d")" in
          [0-9][0-9][0-9][0-9]-W[0-9][0-9]) ;;
          *) continue ;;
        esac

        local d_epoch
        d_epoch=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo "0")
        [ "${d_epoch:-0}" -eq 0 ] && continue
        [ "$d_epoch" -ge "$wbd_cutoff" ] && continue

        # All contained files must also be older than the cutoff.
        local all_old=1 f f_epoch
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          f_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
          if [ "${f_epoch:-0}" -eq 0 ] || [ "$f_epoch" -ge "$wbd_cutoff" ]; then
            all_old=0
            break
          fi
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)

        if [ "$all_old" -eq 1 ]; then
          find "$d" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
          rmdir "$d" 2>/dev/null || true
          if [ ! -d "$d" ]; then
            issues=$((issues + 1))
            repairs=$((repairs + 1))
            details="${details}pruned old week dir $(basename "$d"), "
          fi
        fi
      done
    fi
  fi

  # Strip trailing ", "
  details="${details%, }"

  echo "${issues}|${repairs}|${details}"
}
