#!/usr/bin/env bash
set -euo pipefail
# Regression: run-all.sh must display a red CRASHED indicator for a suite
# file that produces no SUITE summary line (i.e. it crashed before reaching
# end_suite), never a green "PASS (0 tests)" line (Task 8, wave 3, Codex
# M-2). The end-of-run "Failed suites" summary already listed "(CRASHED)"
# correctly pre-fix — the bug is specifically in the PER-SUITE inline status
# line printed during the main loop.
#
# Runs a SANDBOXED COPY of run-all.sh against a throwaway temp test tree —
# never touches or pollutes the real tests/ directory.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"

begin_suite "run-all-crashed-suite"

setup_test
SANDBOX="$_TEST_TMPDIR/run-all-sandbox"
mkdir -p "$SANDBOX/unit" "$SANDBOX/integration" "$SANDBOX/edge" "$SANDBOX/regression"
cp "$TESTS_DIR/run-all.sh" "$SANDBOX/run-all.sh"

# A fixture suite that crashes (via `false` under set -e) before ever
# printing a SUITE summary line.
cat > "$SANDBOX/unit/test-crasher.sh" << 'FIXEOF'
#!/usr/bin/env bash
set -euo pipefail
echo "about to crash"
false
FIXEOF
chmod +x "$SANDBOX/unit/test-crasher.sh"

set +e
output=$(bash "$SANDBOX/run-all.sh" 2>&1)
rc=$?
set -e

assert_eq "sandboxed_run_all_overall_exit_nonzero" "1" "$rc"

# Literal substring match (not word-bounded): the ANSI color code preceding
# "PASS" ends in a literal "m", which is itself a word character and blocks
# a \b boundary right before "PASS" — a \bPASS\b pattern silently never
# matches colored output and would make this assertion vacuously pass.
has_zero_tests_line="no"
echo "$output" | grep -qF "crasher (0 tests)" && has_zero_tests_line="yes"
assert_eq "crashed_suite_not_shown_as_pass" "no" "$has_zero_tests_line"

has_crashed_inline="no"
echo "$output" | grep -qE 'CRASHED.*crasher|crasher.*CRASHED' && has_crashed_inline="yes"
assert_eq "crashed_suite_shows_crashed_indicator" "yes" "$has_crashed_inline"

end_suite
