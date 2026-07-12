#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

begin_suite "profiles"

# eio_get_profile is the ONLY profile reader (state-io.sh deleted, T4)
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh" 2>/dev/null || true
export CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR"

# Test 1: Default profile is "standard" when no config and no env var
setup_test
unset CORTEX_PROFILE 2>/dev/null || true
STATE_DIR="$_TEST_TMPDIR/.claude"
mkdir -p "$STATE_DIR"
result=$(eio_get_profile)
assert_eq "default_is_standard" "standard" "$result"

# Test 2: CORTEX_PROFILE=minimal returns "minimal"
setup_test
CORTEX_PROFILE="minimal"
result=$(eio_get_profile)
assert_eq "env_var_minimal" "minimal" "$result"

# Test 3: CORTEX_PROFILE=strict returns "strict"
setup_test
CORTEX_PROFILE="strict"
result=$(eio_get_profile)
assert_eq "env_var_strict" "strict" "$result"

# Test 4: Config file works when env var is absent
setup_test
unset CORTEX_PROFILE 2>/dev/null || true
CORTEX_DIR="$_TEST_TMPDIR/.claude/cortex"
mkdir -p "$CORTEX_DIR"
echo "strict" > "$CORTEX_DIR/profile.local"
result=$(eio_get_profile)
assert_eq "config_file_strict" "strict" "$result"
rm -f "$CORTEX_DIR/profile.local"

# Test 5: Invalid profile value falls back to "standard"
setup_test
CORTEX_PROFILE="invalid_value"
result=$(eio_get_profile)
assert_eq "invalid_falls_back" "standard" "$result"

# Test 6: Empty CORTEX_PROFILE with no config file falls back to "standard"
setup_test
CORTEX_PROFILE=""
STATE_DIR="$_TEST_TMPDIR/.claude"
mkdir -p "$STATE_DIR"
result=$(eio_get_profile)
assert_eq "empty_env_standard" "standard" "$result"

end_suite
