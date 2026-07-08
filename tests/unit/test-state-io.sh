#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/state-io.sh"

begin_suite "state-io"

# --- read_field tests ---
setup_test
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "test-123")
result=$(read_field "session_id" "$sf")
assert_eq "read_field_existing" "test-123" "$result"

result=$(read_field "nonexistent_field" "$sf" || true)
assert_eq "read_field_missing" "" "$result"

result=$(read_field "session_id" "$_TEST_TMPDIR/does-not-exist.md" || true)
assert_eq "read_field_missing_file" "" "$result"

setup_test
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "eq-test" "last_ci_status=a=b=c")
result=$(read_field "last_ci_status" "$sf")
assert_eq "read_field_with_equals_in_value" "a=b=c" "$result"

setup_test
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "cr-test")
printf "custom_field=value_with_cr\r\n" >> "$sf"
result=$(read_field "custom_field" "$sf")
assert_eq "read_field_strips_carriage_return" "value_with_cr" "$result"

# --- read_section tests ---
# Sections are populated via direct file writes (append_to_section was
# deleted — nothing in the live hook path writes state files anymore).
setup_test
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "section-test")
sed -i '/^\[files_modified\]/a src/lib/test.ts' "$sf"
result=$(read_section "files_modified" "$sf")
assert_contains "read_section_basic" "$result" "src/lib/test.ts"

sed -i '/^\[files_modified\]/a src/lib/other.ts' "$sf"
result=$(read_section "files_modified" "$sf")
assert_contains "read_section_multiple" "$result" "src/lib/other.ts"

sed -i '/^\[files_modified\]/a C:/Users/test/file.ts' "$sf"
result=$(read_section "files_modified" "$sf")
assert_contains "read_section_windows_path" "$result" "C:/Users/test/file.ts"

setup_test
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "empty-section")
result=$(read_section "files_modified" "$sf")
assert_eq "read_section_empty" "" "$result"

# --- normalize_path tests ---
result=$(normalize_path 'C:\Users\test\file.ts')
assert_eq "normalize_path_backslash" "C:/Users/test/file.ts" "$result"

result=$(normalize_path '/c/Users/test')
assert_eq "normalize_path_msys" "C:/Users/test" "$result"

result=$(normalize_path 'c:/foo/bar')
assert_eq "normalize_path_lowercase_drive" "C:/foo/bar" "$result"

end_suite
