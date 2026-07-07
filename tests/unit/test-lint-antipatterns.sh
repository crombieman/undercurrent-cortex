#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

begin_suite "lint-antipatterns"

# grep -c prints "0" AND exits non-zero on no match; `|| echo 0` double-outputs ("0\n0").
# This bug class shipped twice (fixed v3.9.3, regressed by v3.16). Expected hits: none.
# ^[^#]* excludes comment lines; .* (not [^|]*) so a literal '|' in the grep
# pattern argument can't hide the antipattern (that's how session-start:211 slipped by).
hits=$(grep -rnE '^[^#]*grep -c.*\|\| *echo' "$PLUGIN_ROOT/hooks" --include='*.sh' --include='session-start' || true)
assert_eq "no_grep_c_or_echo_in_hooks" "" "$hits"

end_suite
