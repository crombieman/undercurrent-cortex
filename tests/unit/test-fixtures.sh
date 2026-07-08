#!/usr/bin/env bash
set -euo pipefail
# Direct unit coverage for tests/lib/fixtures.sh's seed_file_edit helper
# (Task 8, wave 3, W6). Guards the fixture/production drift W6 identified:
# production only ever writes flag "r" for an ABSOLUTE path under
# PROJECT_DIR (post-edit-dispatch.sh's `[[ "$file_path" == "${PROJECT_DIR}"*
# ]]` check) — a fixture seeding "r" with a relative path represents a
# scenario production can never produce.
#
# Every seed_file_edit call below is wrapped in set +e/set -e, even the
# ones expected to succeed: this file runs under set -e, and a bare call
# whose return code is checked on the NEXT line would abort the whole
# script (via errexit) before that check ever ran if the call unexpectedly
# failed — turning a specific, named assertion failure into an opaque
# CRASHED suite. Guarding uniformly means every outcome, expected or not,
# surfaces as a normal PASS/FAIL.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

begin_suite "fixtures"

# --- seed_file_edit: flag "r" with an absolute path succeeds ---
setup_test
LOG="$_TEST_TMPDIR/absolute.events.log"
: > "$LOG"
set +e
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/lib/ok.ts"
rc=$?
set -e
assert_eq "seed_file_edit_r_absolute_returns_0" "0" "$rc"
line_result="missing"
grep -qF "|file_edit|r ${_TEST_TMPDIR}/src/lib/ok.ts" "$LOG" && line_result="present"
assert_eq "seed_file_edit_r_absolute_appends_line" "present" "$line_result"

# --- seed_file_edit: flag "r" with a Windows drive-letter absolute path succeeds ---
setup_test
LOG="$_TEST_TMPDIR/windows.events.log"
: > "$LOG"
set +e
seed_file_edit "$LOG" "r" "C:/Users/test/src/win.ts"
rc=$?
set -e
assert_eq "seed_file_edit_r_windows_absolute_returns_0" "0" "$rc"
line_result="missing"
grep -qF "|file_edit|r C:/Users/test/src/win.ts" "$LOG" && line_result="present"
assert_eq "seed_file_edit_r_windows_absolute_appends_line" "present" "$line_result"

# --- seed_file_edit: flag "x" with a relative path succeeds (no constraint) ---
setup_test
LOG="$_TEST_TMPDIR/external.events.log"
: > "$LOG"
set +e
seed_file_edit "$LOG" "x" "some/relative/plan.md"
rc=$?
set -e
assert_eq "seed_file_edit_x_relative_returns_0" "0" "$rc"
line_result="missing"
grep -qF "|file_edit|x some/relative/plan.md" "$LOG" && line_result="present"
assert_eq "seed_file_edit_x_relative_appends_line" "present" "$line_result"

# --- seed_file_edit: flag "r" with a RELATIVE path is REFUSED (drift guard) ---
setup_test
LOG="$_TEST_TMPDIR/refused.events.log"
: > "$LOG"
set +e
stderr_out=$(seed_file_edit "$LOG" "r" "src/lib/relative.ts" 2>&1 1>/dev/null)
rc=$?
set -e
assert_eq "seed_file_edit_r_relative_returns_1" "1" "$rc"
has_message="no"
echo "$stderr_out" | grep -qF "refusing" && has_message="yes"
assert_eq "seed_file_edit_r_relative_writes_stderr_message" "yes" "$has_message"
line_result="present"
grep -qF "relative.ts" "$LOG" || line_result="absent"
assert_eq "seed_file_edit_r_relative_appends_nothing" "absent" "$line_result"

# --- seed_file_edit: successive calls produce strictly increasing epochs
# (ordering-sensitive consumers like count_events's anchor logic depend on
# monotonic epoch order within a log) ---
setup_test
LOG="$_TEST_TMPDIR/ordering.events.log"
: > "$LOG"
set +e
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/a.ts"
seed_file_edit "$LOG" "r" "${_TEST_TMPDIR}/src/b.ts"
set -e
epoch1=$(sed -n '1p' "$LOG" | cut -d'|' -f1)
epoch2=$(sed -n '2p' "$LOG" | cut -d'|' -f1)
strictly_increasing="no"
[ "$epoch2" -gt "$epoch1" ] && strictly_increasing="yes"
assert_eq "seed_file_edit_epochs_strictly_increasing" "yes" "$strictly_increasing"

end_suite
