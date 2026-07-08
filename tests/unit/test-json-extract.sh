#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

begin_suite "json-extract"

load_extract() {
  source "$PLUGIN_ROOT/hooks/scripts/lib/json-extract.sh"
}

load_extract
result=$(echo '{"session_id":"abc-123"}' | extract_json_field "session_id")
assert_eq "extract_top_level_field" "abc-123" "$result"

load_extract
result=$(echo '{"tool_input":{"file_path":"src/test.ts"}}' | extract_json_field "tool_input.file_path")
assert_eq "extract_nested_field" "src/test.ts" "$result"

load_extract
result=$(echo '{"session_id":"abc"}' | extract_json_field "nonexistent")
assert_eq "extract_missing_field_returns_empty" "" "$result"

load_extract
result=$(echo '' | extract_json_field "session_id")
assert_eq "extract_empty_input_returns_empty" "" "$result"

load_extract
result=$(echo '{"path":"src/lib/scoring:v11.ts"}' | extract_json_field "path")
assert_eq "extract_field_with_special_chars" "src/lib/scoring:v11.ts" "$result"

# Genuinely mask jq AND python3 so extract_json_field can only reach tier 3
# (bash/awk). setup_mock_path only PRINTS the mock dir — PATH must be
# mutated here, in this shell, not inside the `$(...)` that captures it (a
# command substitution runs in a subshell; a PATH export there never reaches
# the caller). See mock-commands.sh's setup_mock_path doc comment.
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"
hide_command "$mock_bin" "python3"
PATH="$mock_bin:$PATH"

load_extract
result=$(echo '{"session_id":"fallback-test"}' | extract_json_field "session_id")
assert_eq "extract_bash_fallback_simple" "fallback-test" "$result"

load_extract
result=$(echo '{"tool_input":{"file_path":"src/x.ts"}}' | extract_json_field "tool_input.file_path")
assert_eq "extract_bash_fallback_nested_leaf" "src/x.ts" "$result"

load_extract
result=$(echo '{"count":"42"}' | extract_json_field "count")
assert_eq "extract_numeric_string_value" "42" "$result"

load_extract
result=$(echo '{"a":"1","b":"2","c":"3","d":"4","e":"5","f":"6","g":"7","h":"8","i":"9","j":"10","target":"found"}' | extract_json_field "target")
assert_eq "extract_from_large_json" "found" "$result"

restore_path

# --- Tier-3 pretty-JSON tolerance (Codex I-3): jq/python3 shadowed with
# functions that fail closed (return 127) instead of mock-commands.sh's
# setup_mock_path/hide_command. Both approaches are equally valid masking
# strategies now that setup_mock_path's PATH-mutation-in-a-subshell bug is
# fixed (see above and task report) — this block keeps direct function
# shadowing since it was never affected by that bug and needs no PATH
# save/restore bookkeeping.
jq() { return 127; }
python3() { return 127; }
export -f jq python3
jq_masked=no; jq >/dev/null 2>&1 || jq_masked=yes
py_masked=no; python3 >/dev/null 2>&1 || py_masked=yes
assert_eq "tier3_pretty_jq_masked" "yes" "$jq_masked"
assert_eq "tier3_pretty_python3_masked" "yes" "$py_masked"

load_extract
result=$(printf '{\n  "tool_input": {\n    "file_path": "src/pretty.ts"\n  }\n}' | extract_json_field "tool_input.file_path")
assert_eq "extract_tier3_pretty_nested" "src/pretty.ts" "$result"
unset -f jq python3

ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"
# Remove any stale python3 stub left in this shared mock dir by earlier masked
# blocks — with it on PATH, `command -v python3` resolves the 127-stub and
# these "tier-2" tests silently exercise tier 3 instead (review finding).
rm -f "$mock_bin/python3"
PATH="$mock_bin:$PATH"

if command -v python3 >/dev/null 2>&1; then
  load_extract
  result=$(echo '{"session_id":"py-test"}' | extract_json_field "session_id")
  assert_eq "extract_python3_fallback" "py-test" "$result"

  load_extract
  result=$(echo '{"tool_input":{"file_path":"py/nested.ts"}}' | extract_json_field "tool_input.file_path")
  assert_eq "extract_nested_python3_fallback" "py/nested.ts" "$result"
else
  skip_test "extract_python3_fallback" "python3 not available"
  skip_test "extract_nested_python3_fallback" "python3 not available"
fi

restore_path

load_extract
result=$(echo '{
  "session_id": "multiline-test",
  "other": "value"
}' | extract_json_field "session_id")
assert_eq "extract_multiline_json" "multiline-test" "$result"

load_extract
result=$(echo '{"path":"C:\\Users\\test\\file.ts"}' | extract_json_field "path")
assert_contains "extract_backslash_path" "$result" "Users"

end_suite
