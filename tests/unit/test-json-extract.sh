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

mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"
hide_command "$mock_bin" "python3"

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
# functions that fail closed (return 127) rather than mock-commands.sh's
# setup_mock_path/hide_command. That helper exports PATH from inside the
# $(...) command substitution used to capture its echoed mock-bin path — i.e.
# inside a subshell — so the mutation never reaches this caller (verified: on
# a box with a real python3 installed, `mock_bin=$(setup_mock_path ...);
# hide_command "$mock_bin" python3` leaves python3 fully resolvable
# afterward). The masked tests above/below only prove the bash fallback VALUE
# is correct, not that tier 3 alone produced it, whenever a real python3 is
# on PATH — jq's absence on this dev box was hiding that gap. See task report.
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

mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"

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
