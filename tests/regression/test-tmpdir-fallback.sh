#!/usr/bin/env bash
set -euo pipefail
# Regression: begin_suite() must honor TEST_TMPDIR/TMPDIR overrides and fall
# back to a project-local .superpowers/tmp/ (created if needed) when mktemp
# -d fails entirely, instead of crashing under set -e before a suite's first
# test even runs (Task 8, wave 3, Codex M-2).
#
# Each probe sources test-framework.sh fresh in a NESTED bash process (env
# vars passed as a prefix, referenced by name so the child expands them, not
# this shell) — begin_suite/end_suite mutate global state (_TEST_TMPDIR,
# counters), so a nested invocation keeps the probe fully isolated from this
# suite's own sandbox.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

begin_suite "tmpdir-fallback"

# --- TEST_TMPDIR override is honored as the base dir ---
setup_test
override_base="$_TEST_TMPDIR/override-base"
mkdir -p "$override_base"
nested_result=$(TESTS_DIR="$TESTS_DIR" TEST_TMPDIR="$override_base" bash -c '
  set -euo pipefail
  source "$TESTS_DIR/lib/test-framework.sh"
  begin_suite "nested-probe" >/dev/null
  echo "$_TEST_TMPDIR"
  end_suite >/dev/null
')
starts_with_override="no"
[[ "$nested_result" == "$override_base"/* ]] && starts_with_override="yes"
assert_eq "test_tmpdir_env_override_honored" "yes" "$starts_with_override"

# --- TMPDIR is honored when TEST_TMPDIR is unset (pins existing behavior) ---
setup_test
tmpdir_base="$_TEST_TMPDIR/tmpdir-base"
mkdir -p "$tmpdir_base"
nested_result=$(TESTS_DIR="$TESTS_DIR" TMPDIR="$tmpdir_base" bash -c '
  set -euo pipefail
  unset TEST_TMPDIR 2>/dev/null || true
  source "$TESTS_DIR/lib/test-framework.sh"
  begin_suite "nested-probe" >/dev/null
  echo "$_TEST_TMPDIR"
  end_suite >/dev/null
')
starts_with_tmpdir="no"
[[ "$nested_result" == "$tmpdir_base"/* ]] && starts_with_tmpdir="yes"
assert_eq "tmpdir_env_honored_when_test_tmpdir_unset" "yes" "$starts_with_tmpdir"

# --- TEST_TMPDIR takes priority over TMPDIR when both are set ---
setup_test
priority_override="$_TEST_TMPDIR/priority-override"
priority_tmpdir="$_TEST_TMPDIR/priority-tmpdir"
mkdir -p "$priority_override" "$priority_tmpdir"
nested_result=$(TESTS_DIR="$TESTS_DIR" TEST_TMPDIR="$priority_override" TMPDIR="$priority_tmpdir" bash -c '
  set -euo pipefail
  source "$TESTS_DIR/lib/test-framework.sh"
  begin_suite "nested-probe" >/dev/null
  echo "$_TEST_TMPDIR"
  end_suite >/dev/null
')
used_override="no"
[[ "$nested_result" == "$priority_override"/* ]] && used_override="yes"
assert_eq "test_tmpdir_takes_priority_over_tmpdir" "yes" "$used_override"

# --- mktemp -d failure (bogus base is a FILE, not a dir) falls back to a
# project-local .superpowers/tmp/, created if needed, instead of crashing ---
setup_test
bogus_base="$_TEST_TMPDIR/not-a-directory"
touch "$bogus_base"
fallback_dir="$PLUGIN_ROOT/.superpowers/tmp"
pre_existed="no"; [ -d "$fallback_dir" ] && pre_existed="yes"

set +e
nested_result=$(TESTS_DIR="$TESTS_DIR" TEST_TMPDIR="$bogus_base" bash -c '
  set -euo pipefail
  source "$TESTS_DIR/lib/test-framework.sh"
  begin_suite "nested-probe" >/dev/null
  echo "$_TEST_TMPDIR"
  end_suite >/dev/null
')
nested_rc=$?
set -e

assert_eq "mktemp_failure_does_not_crash_the_suite" "0" "$nested_rc"
falls_back="no"
[[ "$nested_result" == "$fallback_dir"/* ]] && falls_back="yes"
assert_eq "mktemp_failure_falls_back_to_superpowers_tmp" "yes" "$falls_back"

parent_created="no"; [ -d "$fallback_dir" ] && parent_created="yes"
assert_eq "superpowers_tmp_parent_created" "yes" "$parent_created"

# Cleanup: end_suite already rm -rf'd the specific fallback subdir; remove
# the parent .superpowers/tmp/ too if this probe is what created it, so the
# repo tree is left exactly as it was found.
if [ "$pre_existed" = "no" ]; then
  rmdir "$fallback_dir" 2>/dev/null || true
fi

end_suite
