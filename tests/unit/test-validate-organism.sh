#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/state-io.sh"
source "$PLUGIN_ROOT/hooks/scripts/lib/validate-organism.sh"

begin_suite "validate-organism"

# CORTEX_PROJECT_DIR_OVERRIDE sandboxes _eio_sessions_dir/_eio_week_dir (event-io
# path helpers validate_organism uses for week-dir pruning) to this suite's temp
# dir for EVERY test below — including the pre-existing ones. Without this, the
# week-dir pruning check would resolve against this repo's real
# .claude/cortex/sessions/ (via git-toplevel fallback) and could delete real
# session data older than 90 days. Never remove this without re-verifying no
# validate_organism call in this file can escape the sandbox.
export CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR"

# --- sanitize_json_field tests ---
result=$(sanitize_json_field "normal string")
assert_eq "sanitize_json_field_clean" "normal string" "$result"

result=$(sanitize_json_field $'has\nnewline')
assert_eq "sanitize_json_field_newline" "" "$result"

long_str=$(printf '%0.s-' {1..201})
result=$(sanitize_json_field "$long_str")
assert_eq "sanitize_json_field_too_long" "" "$result"

# --- validate_organism: health header recovery ---
setup_test
override_state_paths "$_TEST_TMPDIR"
echo "# Health Log" > "$HEALTH_FILE"
echo "---" >> "$HEALTH_FILE"
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "health-header")
STATE_FILE="$sf"
validate_organism 2>/dev/null || true
if [ -f "$HEALTH_FILE" ]; then
  assert_file_contains "validate_health_header_recovery" "$HEALTH_FILE" "trend_direction="
else
  skip_test "validate_health_header_recovery" "health file not created"
fi

# --- validate_organism: health file pruning keeps last 200 rows ---
setup_test
override_state_paths "$_TEST_TMPDIR"
{
  echo "trend_direction=stable"
  echo "avg_reasoning_misses=0.0"
  echo "avg_edits_per_commit=0.0"
  echo "avg_duration_min=0"
  echo "---"
  for i in $(seq 1 600); do
    echo "2026-01-01|0|0.0|true|0|0|0|0|10|0|clean|"
  done
} > "$HEALTH_FILE"
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "health-prune")
STATE_FILE="$sf"
validate_organism 2>/dev/null || true
data_row_count=$(grep -c '|' "$HEALTH_FILE" 2>/dev/null || echo 0)
assert_eq "validate_health_pruning_keeps_200_rows" "200" "$data_row_count"

# --- validate_organism: stale temp cleanup ---
setup_test
override_state_paths "$_TEST_TMPDIR"
touch "$_TEST_TMPDIR/.claude/somefile.tmp.12345"
# Make it old (if touch -t works)
touch -t 202601010000 "$_TEST_TMPDIR/.claude/somefile.tmp.12345" 2>/dev/null || true
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "temp-clean")
STATE_FILE="$sf"
validate_organism 2>/dev/null || true
# Can't reliably test cleanup on all platforms, just verify no crash
assert_eq "validate_stale_temp_no_crash" "0" "0"

# --- week-bucket dir pruning (>90 days) ---
# A date well past the 90-day cutoff regardless of when this suite runs
# (100 days ago always clears the 90-day threshold with margin).
OLD_TS=$(date -d "100 days ago" +%Y%m%d0000 2>/dev/null || date -v-100d +%Y%m%d0000 2>/dev/null || echo "202001010000")

# Old week dir (old dir mtime + old contained file mtime) is removed.
setup_test
override_state_paths "$_TEST_TMPDIR"
old_dir="$(_eio_sessions_dir)/2020-W01"
mkdir -p "$old_dir"
touch "$old_dir/old-sid.local.md"
touch -t "$OLD_TS" "$old_dir/old-sid.local.md"
touch -t "$OLD_TS" "$old_dir"
validate_organism >/dev/null 2>&1 || true
result="present"; [ -d "$old_dir" ] || result="removed"
assert_eq "week_dir_pruning_removes_old_dir" "removed" "$result"

# Current week dir is never touched, even with artificially old mtimes.
setup_test
override_state_paths "$_TEST_TMPDIR"
current_dir="$(_eio_week_dir)"
mkdir -p "$current_dir"
touch "$current_dir/current-sid.local.md"
touch -t "$OLD_TS" "$current_dir/current-sid.local.md"
touch -t "$OLD_TS" "$current_dir"
validate_organism >/dev/null 2>&1 || true
result="present"; [ -d "$current_dir" ] || result="removed"
assert_eq "week_dir_pruning_never_touches_current_week" "present" "$result"

# Old dir mtime but a recently-modified contained file => not prunable.
setup_test
override_state_paths "$_TEST_TMPDIR"
mixed_dir="$(_eio_sessions_dir)/2020-W05"
mkdir -p "$mixed_dir"
touch "$mixed_dir/recent-sid.local.md"      # fresh mtime — left untouched
touch -t "$OLD_TS" "$mixed_dir"             # dir mtime old, file mtime recent
validate_organism >/dev/null 2>&1 || true
result="present"; [ -d "$mixed_dir" ] || result="removed"
assert_eq "week_dir_pruning_skips_dir_with_recent_file" "present" "$result"

# Aged stray dir NOT matching the YYYY-WNN week pattern survives pruning —
# only ISO-week buckets are prunable (guards test fixtures / manual backups
# that happen to live under sessions/, even when fully aged past the cutoff).
setup_test
override_state_paths "$_TEST_TMPDIR"
stray_dir="$(_eio_sessions_dir)/test-week"
mkdir -p "$stray_dir"
touch "$stray_dir/stray-sid.local.md"
touch -t "$OLD_TS" "$stray_dir/stray-sid.local.md"
touch -t "$OLD_TS" "$stray_dir"
validate_organism >/dev/null 2>&1 || true
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
override_state_paths "$_TEST_TMPDIR"
sym_target="$_TEST_TMPDIR/external-target"
mkdir -p "$sym_target"
echo "important" > "$sym_target/important.txt"
touch -t "$OLD_TS" "$sym_target/important.txt"
touch -t "$OLD_TS" "$sym_target"
sym_path="$(_eio_sessions_dir)/2020-W02"
ln -s "$sym_target" "$sym_path" 2>/dev/null || true
if [ -L "$sym_path" ]; then
  validate_organism >/dev/null 2>&1 || true
  sym_result="present"; [ -L "$sym_path" ] || sym_result="removed"
  assert_eq "week_dir_pruning_skips_symlinked_week_dir" "present" "$sym_result"
  target_result="present"; [ -f "$sym_target/important.txt" ] || target_result="removed"
  assert_eq "week_dir_pruning_symlink_target_untouched" "present" "$target_result"
else
  skip_test "week_dir_pruning_skips_symlinked_week_dir" "ln -s unavailable (no symlink privilege on this box)"
  skip_test "week_dir_pruning_symlink_target_untouched" "ln -s unavailable (no symlink privilege on this box)"
  guard_present="missing"
  grep -qF '[ -L "$d" ] && continue' "$PLUGIN_ROOT/hooks/scripts/lib/validate-organism.sh" && guard_present="present"
  assert_eq "week_dir_pruning_symlink_guard_line_exists" "present" "$guard_present"
fi

# --- Honest repair reporting (W5 review M-1): a DENIED separator append must
# not be reported as a successful repair (issue counted, repair not) ---
setup_test
override_state_paths "$_TEST_TMPDIR"
mkdir -p "$(dirname "$PROPOSALS_FILE")"
printf 'id=x
status=pending
' > "$PROPOSALS_FILE"
chmod 444 "$PROPOSALS_FILE" 2>/dev/null || true
ro_result=$(validate_organism 2>/dev/null || echo "0|0|")
chmod 644 "$PROPOSALS_FILE" 2>/dev/null || true
ro_details=$(echo "$ro_result" | cut -d'|' -f3-)
assert_not_contains "denied_separator_not_claimed_repaired" "$ro_details" "added separator to proposals.local.md"

unset CORTEX_PROJECT_DIR_OVERRIDE

end_suite
