#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

begin_suite "profiles"

# eio_get_profile is the ONLY condition reader (state-io.sh deleted, T4).
# T6: values are core|lab; legacy names alias (minimal→core,
# standard/strict→lab); default is lab (the lived treatment).
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh" 2>/dev/null || true
export CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR"

# Test 1: Default condition is "lab" when no config and no env var
setup_test
unset CORTEX_PROFILE 2>/dev/null || true
mkdir -p "$_TEST_TMPDIR/.claude"
result=$(eio_get_profile)
assert_eq "default_is_lab" "lab" "$result"

# Test 2: native values pass through
setup_test
CORTEX_PROFILE="core"
assert_eq "env_var_core" "core" "$(eio_get_profile)"
CORTEX_PROFILE="lab"
assert_eq "env_var_lab" "lab" "$(eio_get_profile)"

# Test 3: legacy aliases map
setup_test
CORTEX_PROFILE="minimal"
assert_eq "alias_minimal_to_core" "core" "$(eio_get_profile)"
CORTEX_PROFILE="standard"
assert_eq "alias_standard_to_lab" "lab" "$(eio_get_profile)"
CORTEX_PROFILE="strict"
assert_eq "alias_strict_to_lab" "lab" "$(eio_get_profile)"

# Test 4: Config file works when env var is absent
setup_test
unset CORTEX_PROFILE 2>/dev/null || true
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
echo "core" > "$_TEST_TMPDIR/.claude/cortex/profile.local"
result=$(eio_get_profile)
assert_eq "config_file_core" "core" "$result"
rm -f "$_TEST_TMPDIR/.claude/cortex/profile.local"

# Test 5: Invalid value falls back to "lab"
setup_test
CORTEX_PROFILE="invalid_value"
result=$(eio_get_profile)
assert_eq "invalid_falls_back_to_lab" "lab" "$result"

# Test 6: Empty CORTEX_PROFILE with no config file falls back to "lab"
setup_test
CORTEX_PROFILE=""
mkdir -p "$_TEST_TMPDIR/.claude"
result=$(eio_get_profile)
assert_eq "empty_env_lab" "lab" "$result"

end_suite
