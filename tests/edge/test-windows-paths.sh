#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# normalize_path lives in event-io.sh (state-io.sh deleted, calibration T4)
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

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

# (Test 4, the read_section round-trip, died with the legacy state reader —
# calibration T4. Windows paths in EVENT LOG values are covered by the
# event-io and post-edit suites.)

# Test 5: MSYS uppercase drive /D/ path normalization
setup_test
result=$(normalize_path '/D/projects/myapp/src/lib/utils.ts')
assert_eq "msys_uppercase_drive_letter" "D:/projects/myapp/src/lib/utils.ts" "$result"

end_suite
