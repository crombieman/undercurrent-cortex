#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"
source "$PLUGIN_ROOT/hooks/scripts/lib/housekeeping.sh"

begin_suite "housekeeping"

# CORTEX_PROJECT_DIR_OVERRIDE sandboxes _eio_sessions_dir/_eio_week_dir to
# this suite's temp dir for EVERY test below. Without this, the week-dir
# pruning would resolve against this repo's real .claude/cortex/sessions/
# (via git-toplevel fallback) and could delete real session data older than
# 90 days. Never remove this without re-verifying no cortex_housekeeping
# call in this file can escape the sandbox.
export CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR"

# A date well past the 90-day cutoff regardless of when this suite runs.
OLD_TS=$(date -d "100 days ago" +%Y%m%d0000 2>/dev/null || date -v-100d +%Y%m%d0000 2>/dev/null || echo "202001010000")

# --- Temp cleanup: a FRESH .tmp.* file survives (only >60 min is stale);
# an aged one is removed (when touch -t can backdate on this platform). ---
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
touch "$_TEST_TMPDIR/.claude/cortex/fresh.tmp.111"
touch "$_TEST_TMPDIR/.claude/cortex/stale.tmp.222"
touch -t "$OLD_TS" "$_TEST_TMPDIR/.claude/cortex/stale.tmp.222" 2>/dev/null || true
cortex_housekeeping 2>/dev/null || true
result="present"; [ -f "$_TEST_TMPDIR/.claude/cortex/fresh.tmp.111" ] || result="removed"
assert_eq "temp_cleanup_keeps_fresh_tmp" "present" "$result"
# Backdating may silently fail on some filesystems — only assert removal
# when the mtime actually took.
if [ -f "$_TEST_TMPDIR/.claude/cortex/stale.tmp.222" ]; then
  stale_epoch=$(stat -c %Y "$_TEST_TMPDIR/.claude/cortex/stale.tmp.222" 2>/dev/null || stat -f %m "$_TEST_TMPDIR/.claude/cortex/stale.tmp.222" 2>/dev/null || echo "$(date +%s)")
  if [ "$stale_epoch" -lt "$(( $(date +%s) - 3600 ))" ]; then
    assert_eq "temp_cleanup_removes_stale_tmp" "removed" "present"
  else
    skip_test "temp_cleanup_removes_stale_tmp" "touch -t could not backdate on this platform"
  fi
else
  assert_eq "temp_cleanup_removes_stale_tmp" "removed" "removed"
fi

# --- Backup cleanup: a fresh state-backup survives ---
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
touch "$_TEST_TMPDIR/.claude/cortex/state-backup-fresh"
cortex_housekeeping 2>/dev/null || true
result="present"; [ -f "$_TEST_TMPDIR/.claude/cortex/state-backup-fresh" ] || result="removed"
assert_eq "backup_cleanup_keeps_fresh_backup" "present" "$result"

# --- Week-bucket dir pruning (>90 days) — behaviors carried verbatim from
# the deleted healer (they always had a clean record) ---

# Old week dir (old dir mtime + old contained file mtime) is removed.
setup_test
old_dir="$(_eio_sessions_dir)/2020-W01"
mkdir -p "$old_dir"
touch "$old_dir/old-sid.local.md"
touch -t "$OLD_TS" "$old_dir/old-sid.local.md"
touch -t "$OLD_TS" "$old_dir"
cortex_housekeeping >/dev/null 2>&1 || true
result="present"; [ -d "$old_dir" ] || result="removed"
assert_eq "week_dir_pruning_removes_old_dir" "removed" "$result"

# Current week dir is never touched, even with artificially old mtimes.
setup_test
current_dir="$(_eio_week_dir)"
mkdir -p "$current_dir"
touch "$current_dir/current-sid.local.md"
touch -t "$OLD_TS" "$current_dir/current-sid.local.md"
touch -t "$OLD_TS" "$current_dir"
cortex_housekeeping >/dev/null 2>&1 || true
result="present"; [ -d "$current_dir" ] || result="removed"
assert_eq "week_dir_pruning_never_touches_current_week" "present" "$result"

# Old dir mtime but a recently-modified contained file => not prunable.
setup_test
mixed_dir="$(_eio_sessions_dir)/2020-W05"
mkdir -p "$mixed_dir"
touch "$mixed_dir/recent-sid.local.md"      # fresh mtime — left untouched
touch -t "$OLD_TS" "$mixed_dir"             # dir mtime old, file mtime recent
cortex_housekeeping >/dev/null 2>&1 || true
result="present"; [ -d "$mixed_dir" ] || result="removed"
assert_eq "week_dir_pruning_skips_dir_with_recent_file" "present" "$result"

# Aged stray dir NOT matching the YYYY-WNN week pattern survives pruning —
# only ISO-week buckets are prunable (guards test fixtures / manual backups
# that happen to live under sessions/, even when fully aged past the cutoff).
setup_test
stray_dir="$(_eio_sessions_dir)/test-week"
mkdir -p "$stray_dir"
touch "$stray_dir/stray-sid.local.md"
touch -t "$OLD_TS" "$stray_dir/stray-sid.local.md"
touch -t "$OLD_TS" "$stray_dir"
cortex_housekeeping >/dev/null 2>&1 || true
result="present"; [ -d "$stray_dir" ] || result="removed"
assert_eq "week_dir_pruning_skips_non_week_named_dirs" "present" "$result"

# A symlink literally named like an ISO-week bucket (matches the pruning
# loop's name-pattern guard) whose TARGET is some unrelated external
# directory full of aged files must survive pruning untouched, and the
# target's contents must not be touched either. Without a symlink check,
# `find "$d" -mindepth 1 -maxdepth 1 -type f -delete` on a `$d` that is
# actually a symlink follows it and deletes files INSIDE THE TARGET.
# `ln -s` on Windows without Developer Mode / admin either fails outright or
# (observed on this box) silently succeeds by copying the target instead of
# creating a real symlink — `test -L` catches both: if it's not a real
# symlink afterward, skip with a grep fallback proving the guard line exists.
setup_test
sym_target="$_TEST_TMPDIR/external-target"
mkdir -p "$sym_target"
echo "important" > "$sym_target/important.txt"
touch -t "$OLD_TS" "$sym_target/important.txt"
touch -t "$OLD_TS" "$sym_target"
sym_path="$(_eio_sessions_dir)/2020-W02"
mkdir -p "$(_eio_sessions_dir)"
ln -s "$sym_target" "$sym_path" 2>/dev/null || true
if [ -L "$sym_path" ]; then
  cortex_housekeeping >/dev/null 2>&1 || true
  sym_result="present"; [ -L "$sym_path" ] || sym_result="removed"
  assert_eq "week_dir_pruning_skips_symlinked_week_dir" "present" "$sym_result"
  target_result="present"; [ -f "$sym_target/important.txt" ] || target_result="removed"
  assert_eq "week_dir_pruning_symlink_target_untouched" "present" "$target_result"
else
  skip_test "week_dir_pruning_skips_symlinked_week_dir" "ln -s unavailable (no symlink privilege on this box)"
  skip_test "week_dir_pruning_symlink_target_untouched" "ln -s unavailable (no symlink privilege on this box)"
  guard_present="missing"
  grep -qF '[ -L "$d" ] && continue' "$PLUGIN_ROOT/hooks/scripts/lib/housekeeping.sh" && guard_present="present"
  assert_eq "week_dir_pruning_symlink_guard_line_exists" "present" "$guard_present"
fi

# --- Silence contract: housekeeping echoes NOTHING (no issues/repairs
# report — "self-repair" vocabulary died with the healer) ---
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
out=$(cortex_housekeeping 2>/dev/null)
assert_eq "housekeeping_is_silent" "" "$out"

unset CORTEX_PROJECT_DIR_OVERRIDE

end_suite
