#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

begin_suite "pattern-template"

SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell.
# pattern-template.sh now derives PROJECT_DIR via event-io.sh's
# eio_project_dir() (resolved from this env var at call time), not from the
# sandbox's sed-patched state-io.sh copy — so it must be set here explicitly
# (same pattern as tests/integration/test-post-dispatch.sh).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run pattern-template with a given file path
run_pattern_template() {
  local file_path="$1"
  local json
  json=$(mock_json "tool_input.file_path=$file_path")
  echo "$json" | bash "$SANDBOX/hooks/scripts/pattern-template.sh" 2>/dev/null || true
}

# Helper: create exemplar file in .claude/exemplars/
create_exemplar() {
  local filename="$1"
  mkdir -p "$_TEST_TMPDIR/.claude/exemplars"
  printf '%s\n%s\n' "-- Exemplar content for testing" "-- Line 2 of exemplar" > "$_TEST_TMPDIR/.claude/exemplars/$filename"
}

clean_exemplars() {
  rm -rf "$_TEST_TMPDIR/.claude/exemplars" 2>/dev/null || true
}

# Test 1: SQL exemplar matches .sql file
setup_test
clean_exemplars
create_exemplar "migration-pattern.sql"
result=$(run_pattern_template "supabase/migrations/073_new_table.sql")
assert_contains "sql_exemplar_match" "$result" "migration pattern"

# Test 2: TSX exemplar matches .tsx file
setup_test
clean_exemplars
create_exemplar "component-pattern.tsx"
result=$(run_pattern_template "src/components/stock/insider-trades.tsx")
assert_contains "tsx_exemplar_match" "$result" "component pattern"

# Test 3: TS exemplar matches .ts file
setup_test
clean_exemplars
create_exemplar "utility-pattern.ts"
result=$(run_pattern_template "src/lib/data-sources/yahoo.ts")
assert_contains "ts_exemplar_match" "$result" "utility pattern"

# Test 4: No exemplar for extension -> returns {}
setup_test
clean_exemplars
create_exemplar "migration-pattern.sql"
result=$(run_pattern_template "package.json")
assert_eq "no_matching_extension" "{}" "$result"

# Test 5: No exemplar dir at all -> returns {}
setup_test
clean_exemplars
result=$(run_pattern_template "src/lib/utils.ts")
assert_eq "no_exemplar_dir" "{}" "$result"

# Test 6: Empty file path -> returns {}
setup_test
clean_exemplars
result=$(run_pattern_template "")
assert_eq "empty_file_path" "{}" "$result"

# Test 7: Output contains systemMessage when matched
setup_test
clean_exemplars
create_exemplar "migration-pattern.sql"
result=$(run_pattern_template "supabase/migrations/073_new_table.sql")
assert_contains "output_has_system_message" "$result" "systemMessage"

# Test 8: Windows backslash paths normalized
setup_test
clean_exemplars
create_exemplar "migration-pattern.sql"
result=$(run_pattern_template 'supabase\migrations\080_new.sql')
assert_contains "windows_backslash_match" "$result" "migration pattern"

end_suite
