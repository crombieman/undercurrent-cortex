#!/usr/bin/env bash
set -euo pipefail
# Direct unit coverage for tests/lib/mock-commands.sh itself (Task 8, wave 3).
# Previously only exercised indirectly through consumer test files — this
# suite pins down the two root-cause bugs fixed in this task: (A)
# setup_mock_path's PATH export used to run inside a $(...) subshell and
# never reached the caller; (B) create_mock_date's 2nd+ call resolved "the
# real date binary" via a PATH search that, by the 2nd call, found the FIRST
# mock instead — baking a self-reference that recurses forever on any
# non-"+%j" invocation.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

begin_suite "mock-commands"

# --- setup_mock_path: prints the mock dir, does NOT mutate the caller's PATH ---
setup_test
BEFORE_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
dir_result="missing"; [ -d "$mock_bin" ] && dir_result="present"
assert_eq "setup_mock_path_creates_dir" "present" "$dir_result"
assert_eq "setup_mock_path_does_not_mutate_caller_path" "$BEFORE_PATH" "$PATH"

# Documented usage pattern (ORIGINAL_PATH save + explicit PATH mutation in
# THIS shell, not inside a $(...) capture) actually masks a command once applied.
hide_command "$mock_bin" "___cortex_probe_cmd___"
ORIGINAL_PATH="$PATH"
PATH="$mock_bin:$PATH"
masked_resolves="no"
[ "$(command -v ___cortex_probe_cmd___ 2>/dev/null)" = "$mock_bin/___cortex_probe_cmd___" ] && masked_resolves="yes"
assert_eq "documented_usage_pattern_masks_command" "yes" "$masked_resolves"
restore_path
assert_eq "restore_path_restores_original_path" "$BEFORE_PATH" "$PATH"

# --- create_mock_date: 2nd+ creation must not recurse into itself ---
# Reproduces the exact failure condition: mock_bin is ALREADY on PATH (from
# the 1st create_mock_date's caller having applied it) when the 2nd
# create_mock_date call regenerates the script. Pre-fix, `which date` at
# that point resolves to the 1st mock's own script; post-fix, the real
# system date is resolved independent of what's currently on PATH.
#
# SAFETY (do not remove): a self-referential mock, when actually EXECUTED,
# forks an UNBOUNDED chain of child processes — one bash.exe per recursive
# step, each blocking on the next. On this Windows/MSYS box a `timeout 5`
# guard around the dynamic call did NOT reliably contain it: `timeout` only
# signals the direct child it launched, and by the time that signal lands
# the chain has already forked a new leaf that inherits no relationship to
# the killed process and keeps recursing independently. Developing this very
# test against the pre-fix code forkbombed ~10,000 orphaned bash.exe
# processes before they were found and killed by PID (see task report) —
# `timeout` alone was not the safety net it looks like. So: check the
# generated script's content STATICALLY first (self-reference is fully
# determined by what got written to disk — no execution needed to know it
# would recurse) and only attempt the dynamic exec if that check already
# proves it's safe. A future regression then fails loud on the static
# assertion instead of hanging/forking.
setup_test
mock_bin2=$(setup_mock_path "$_TEST_TMPDIR")
create_mock_date "$mock_bin2" "42"
ORIGINAL_PATH="$PATH"
PATH="$mock_bin2:$PATH"
create_mock_date "$mock_bin2" "99"   # 2nd call, mock_bin2 already on PATH
PATH="$ORIGINAL_PATH"

self_referential="no"
grep -qF "\"${mock_bin2}/date\"" "$mock_bin2/date" && self_referential="yes"
assert_eq "second_mock_date_not_self_referential" "no" "$self_referential"

if [ "$self_referential" = "yes" ]; then
  skip_test "second_mock_date_creation_does_not_hang" "static self-reference check already failed — skipping dynamic exec to avoid a runaway recursive fork chain"
  skip_test "second_mock_date_passthrough_returns_epoch" "static self-reference check already failed — skipping dynamic exec"
  skip_test "second_mock_date_j_format_no_hang" "static self-reference check already failed — skipping dynamic exec"
  skip_test "second_mock_date_j_format_returns_latest_value" "static self-reference check already failed — skipping dynamic exec"
else
  set +e
  result=$(timeout -s KILL 3 "$mock_bin2/date" +%s 2>/dev/null)
  rc=$?
  set -e
  assert_eq "second_mock_date_creation_does_not_hang" "0" "$rc"
  looks_numeric="no"
  [[ "$result" =~ ^[0-9]+$ ]] && looks_numeric="yes"
  assert_eq "second_mock_date_passthrough_returns_epoch" "yes" "$looks_numeric"

  # The mocked +%j format still returns the LATEST creation's value — proves
  # the regenerated script is the 2nd mock's own logic, not a stale copy.
  set +e
  result_j=$(timeout -s KILL 3 "$mock_bin2/date" +%j 2>/dev/null)
  rc_j=$?
  set -e
  assert_eq "second_mock_date_j_format_no_hang" "0" "$rc_j"
  assert_eq "second_mock_date_j_format_returns_latest_value" "99" "$result_j"
fi

end_suite
