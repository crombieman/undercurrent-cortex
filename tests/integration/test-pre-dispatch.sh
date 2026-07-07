#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "pre-dispatch"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell — event-io.sh
# (unlike the sandbox's sed-patched state-io.sh copy) resolves the project dir
# from this env var at call time, so it must be set here explicitly (same pattern
# as tests/integration/test-post-dispatch.sh).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run pre-dispatch with given JSON
run_pre_dispatch() {
  local json_input="$1"
  echo "$json_input" | bash "$SANDBOX/hooks/scripts/pre-dispatch.sh" 2>/dev/null || true
}

# Test 1: Write to migration file routes to migration-linter (deny path)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=supabase/migrations/074_test.sql" \
  "tool_input.content=CREATE INDEX idx ON t (id) WHERE d > CURRENT_DATE")
result=$(run_pre_dispatch "$json")
assert_contains "route_write_to_migration_linter" "$result" "deny"

# Test 2: Edit to migration file also routes to migration-linter
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Edit" "session_id=pd-test" \
  "tool_input.file_path=supabase/migrations/074_test.sql" \
  "tool_input.new_string=CREATE TABLE edit_table (id serial PRIMARY KEY)")
result=$(run_pre_dispatch "$json")
assert_contains "route_edit_to_migration_linter" "$result" "ROW LEVEL SECURITY"

# Test 3: Write to .claude/plans/ routes to plan-file-guard
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
# Create an existing plan file with >50 lines
plan_file="$_TEST_TMPDIR/.claude/plans/design-feature.md"
mkdir -p "$_TEST_TMPDIR/.claude/plans"
for i in $(seq 1 60); do
  echo "Line $i of the plan" >> "$plan_file"
done
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=$_TEST_TMPDIR/.claude/plans/design-feature.md" \
  "tool_input.content=Overwritten plan content")
result=$(run_pre_dispatch "$json")
assert_contains "route_write_to_plan_file_guard" "$result" "deny"

# Test 4: Propagate deny from migration-linter (immutability violation)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=supabase/migrations/074_test.sql" \
  "tool_input.content=CREATE INDEX idx ON t (id) WHERE ts > now()")
result=$(run_pre_dispatch "$json")
assert_contains "propagate_deny_from_linter" "$result" "deny"

# Test 5: Non-Write/Edit tool returns {}
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Read" "session_id=pd-test" \
  "tool_input.file_path=src/lib/utils.ts")
result=$(run_pre_dispatch "$json")
assert_eq "ignore_non_write_tools" "{}" "$result"

# Test 6: REGRESSION — Write to migration with warning (not deny) preserves linter warning
# Bug: plan-file-guard overwrote $result, losing migration-linter warnings for Write ops
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=supabase/migrations/074_test.sql" \
  "tool_input.content=CREATE TABLE warning_table (id serial PRIMARY KEY)")
result=$(run_pre_dispatch "$json")
assert_contains "write_preserves_linter_warning" "$result" "ROW LEVEL SECURITY"

# Test 7: Edit to migration with warning also preserves linter warning
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Edit" "session_id=pd-test" \
  "tool_input.file_path=supabase/migrations/074_test.sql" \
  "tool_input.new_string=INSERT INTO test_table (id, name) VALUES (1, 'foo')")
result=$(run_pre_dispatch "$json")
assert_contains "edit_preserves_linter_warning" "$result" "WHERE EXISTS"

# Test 8: ExitPlanMode appends a plan_mode event when the log resolves
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "pd-test")
json=$(mock_json "tool_name=ExitPlanMode" "session_id=pd-test")
result=$(run_pre_dispatch "$json")
assert_eq "exit_plan_mode_returns_empty" "{}" "$result"
plan_mode_value=$(last_event plan_mode "$LOG")
assert_eq "exit_plan_mode_appends_event" "used" "$plan_mode_value"

# Test 9: ExitPlanMode with no event log on disk — no crash, routing still returns {}
setup_test
json=$(mock_json "tool_name=ExitPlanMode" "session_id=pd-nolog")
result=$(run_pre_dispatch "$json")
assert_eq "exit_plan_mode_no_log_returns_empty" "{}" "$result"

# Test 10: TDD guard warns on a src/ edit with no test-file events (standard profile)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=${_TEST_TMPDIR}/src/lib/foo.ts" \
  "tool_input.content=export const foo = 1;")
result=$(run_pre_dispatch "$json")
assert_contains "tdd_guard_warns_standard_profile" "$result" "TDD guard"

# Test 11: TDD guard stays silent when a test-file file_edit event exists this session
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" \
  "1700000001|file_edit|r ${_TEST_TMPDIR}/src/lib/foo.test.ts" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=${_TEST_TMPDIR}/src/lib/bar.ts" \
  "tool_input.content=export const bar = 1;")
result=$(run_pre_dispatch "$json")
assert_eq "tdd_guard_silent_with_test_file_event" "{}" "$result"

# Test 12: TDD guard denies in strict profile
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=${_TEST_TMPDIR}/src/lib/foo.ts" \
  "tool_input.content=export const foo = 1;")
export CORTEX_PROFILE=strict
result=$(run_pre_dispatch "$json")
unset CORTEX_PROFILE
assert_contains "tdd_guard_denies_strict_profile" "$result" "deny"
assert_contains "tdd_guard_denies_strict_profile_message" "$result" "TDD enforcement"

# Test 13: TDD guard skips test files themselves (never block writing tests)
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=${_TEST_TMPDIR}/src/lib/foo.test.ts" \
  "tool_input.content=describe('foo', () => {});")
result=$(run_pre_dispatch "$json")
assert_eq "tdd_guard_skips_test_files" "{}" "$result"

# Test 14: TDD guard skips .d.ts files
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=${_TEST_TMPDIR}/src/lib/types.d.ts" \
  "tool_input.content=export type Foo = string;")
result=$(run_pre_dispatch "$json")
assert_eq "tdd_guard_skips_dts_files" "{}" "$result"

# Test 15: TDD guard skips non-src/ paths
setup_test
create_event_log "$_TEST_TMPDIR/.claude" "pd-test" > /dev/null
json=$(mock_json "tool_name=Write" "session_id=pd-test" \
  "tool_input.file_path=${_TEST_TMPDIR}/scripts/build.js" \
  "tool_input.content=console.log('build');")
result=$(run_pre_dispatch "$json")
assert_eq "tdd_guard_skips_non_src_paths" "{}" "$result"

end_suite
