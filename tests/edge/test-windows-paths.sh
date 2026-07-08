#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/state-io.sh"

begin_suite "windows-paths"

# Test 1: Backslash to forward slash
setup_test
result=$(normalize_path 'C:\Users\testuser\Desktop\project\src\lib\utils.ts')
assert_eq "backslash_to_forward_slash" "C:/Users/testuser/Desktop/project/src/lib/utils.ts" "$result"

# Test 2: MSYS /c/ to C:/
setup_test
result=$(normalize_path '/c/Users/testuser/Desktop/project/src/lib/utils.ts')
assert_eq "msys_to_windows_drive" "C:/Users/testuser/Desktop/project/src/lib/utils.ts" "$result"

# Test 3: Uppercase drive letter
setup_test
result=$(normalize_path 'c:/Users/testuser/Desktop/project/src/lib/utils.ts')
assert_eq "uppercase_drive_letter" "C:/Users/testuser/Desktop/project/src/lib/utils.ts" "$result"

# Test 4: Windows path in a section is read back unmangled
# (append_to_section was deleted — write it directly via ENVIRON, same
# backslash-safety technique it used, since sed's `a` command interprets
# backslashes as escapes and would mangle this path; this exercises the
# read_section path only.)
setup_test
override_state_paths "$_TEST_TMPDIR"
sf=$(create_state_file "$_TEST_TMPDIR/.claude" "win-path-test")
windows_path='C:\Users\testuser\src\test.ts'
WP="$windows_path" awk '
  /^\[files_modified\]/ { print; print ENVIRON["WP"]; next }
  { print }
' "$sf" > "$sf.new" && mv "$sf.new" "$sf"
section_content=$(read_section "files_modified" "$sf")
assert_contains "windows_path_in_section" "$section_content" 'C:\Users\testuser\src\test.ts'

# Test 5: MSYS uppercase drive /D/ path normalization
setup_test
result=$(normalize_path '/D/projects/myapp/src/lib/utils.ts')
assert_eq "msys_uppercase_drive_letter" "D:/projects/myapp/src/lib/utils.ts" "$result"

end_suite
