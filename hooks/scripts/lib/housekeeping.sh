#!/usr/bin/env bash
# Housekeeping — the hygiene that survived the healer's deletion (calibration
# wave, queue item 7). validate-organism.sh is GONE: its health-file
# rebuild/prune checks were instrument defects (the D4 ping-pong; the eaten
# title line) — health.local.md is create-once + append-only now, enforced by
# the lint suite. What lives here is the maintenance with a clean record:
# temp-file cleanup, old-backup cleanup, and week-bucket dir pruning. Silent
# by design — no issues/repairs report, no "self-repair" vocabulary.
# Sourced by hooks/session-start after event-io.sh (path helpers).

# Guard against double-sourcing when tested standalone.
if ! type _eio_sessions_dir &>/dev/null; then
  _HOUSEKEEPING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_HOUSEKEEPING_DIR/event-io.sh"
fi

# cortex_housekeeping
# Best-effort, silent, side-effect only. Never fails the caller.
cortex_housekeeping() {
  local cortex_dir
  cortex_dir="$(_eio_cortex_dir)"

  # --- 1. Stale temp cleanup (>60 min): orphaned document-rewrite temps
  # (*.tmp.$$ from proposals/collab single-writer sites) live in cortex/. ---
  if [ -d "$cortex_dir" ]; then
    find "$cortex_dir" -maxdepth 1 -name "*.tmp.*" -mmin +60 -delete 2>/dev/null || true
  fi

  # --- 2. Old backup cleanup (>7 days) ---
  if [ -d "$cortex_dir" ]; then
    find "$cortex_dir" -maxdepth 1 -name "state-backup-*" -mmin +10080 -delete 2>/dev/null || true
  fi

  # --- 3. Week-bucket dir pruning (>90 days) ---
  # A week dir is prunable when its OWN mtime AND every file it contains are
  # older than 90 days. The current week dir is NEVER touched, even if its
  # mtime looks stale (clock skew) — guarded by path comparison, not just age.
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
        fi
      done
    fi
  fi

  return 0
}
