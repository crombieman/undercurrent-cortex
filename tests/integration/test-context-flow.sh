#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "context-flow"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")
create_context_dir "$SANDBOX"

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell — event-io.sh
# resolves the project dir from this env var at call time, so it must be set
# here explicitly (pattern: tests/integration/test-post-dispatch.sh:22).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run context-flow with given user prompt and optional seed events
# (event log is recreated fresh each call — "epoch|type|value" lines appended
# after the fixture's default session_start line).
run_context_flow_with_events() {
  local prompt="$1" sid="$2"
  shift 2
  create_event_log "$_TEST_TMPDIR/.claude" "$sid" "$@" > /dev/null
  local json
  json=$(mock_json "user_prompt=$prompt" "session_id=$sid")
  echo "$json" | bash "$SANDBOX/hooks/scripts/context-flow.sh" 2>/dev/null || true
}

# Helper: run context-flow with given user prompt (no extra seed events)
run_context_flow() {
  local prompt="$1" sid="${2:-ctx-test}"
  run_context_flow_with_events "$prompt" "$sid"
}

# Test 1: "scoring" injects scoring-architecture content
setup_test
result=$(run_context_flow "update the scoring engine")
assert_contains "scoring_keyword" "$result" "Scoring architecture"

# Test 2: "migration" injects migration-lessons content
setup_test
result=$(run_context_flow "write a new migration")
assert_contains "migration_keyword" "$result" "Migration lessons"

# Test 3: "pipeline" injects pipeline-constraints content
setup_test
result=$(run_context_flow "fix the pipeline worker")
assert_contains "pipeline_keyword" "$result" "Pipeline constraints"

# Test 4: "deploy" injects deploy-readiness content
setup_test
result=$(run_context_flow "deploy to production")
assert_contains "deploy_keyword" "$result" "Deploy readiness"

# Test 5: "vitest" injects testing-conventions content
setup_test
result=$(run_context_flow "run vitest on this module")
assert_contains "vitest_keyword" "$result" "Testing conventions"

# Test 6: "stripe" injects payment-integration content
setup_test
result=$(run_context_flow "update stripe webhook handler")
assert_contains "stripe_keyword" "$result" "Payment integration"

# Test 7: "formula" injects math-review content
setup_test
result=$(run_context_flow "check the formula for z-scores")
assert_contains "formula_keyword" "$result" "Math review"

# Test 8: "typescript" injects typescript-discipline content
setup_test
result=$(run_context_flow "fix the typescript error")
assert_contains "typescript_keyword" "$result" "TypeScript discipline"

# Test 9: No keyword match returns {}
setup_test
result=$(run_context_flow "hello world")
assert_eq "no_match_empty" "{}" "$result"

# Test 10: Case insensitive matching
setup_test
result=$(run_context_flow "update the SCORING system")
assert_contains "case_insensitive_scoring" "$result" "Scoring architecture"

# Test 11: "python" injects python-patterns content
setup_test
result=$(run_context_flow "set up the python virtual environment")
assert_contains "python_keyword" "$result" "Python patterns"

# Test 12: "pytest" injects python-patterns content
setup_test
result=$(run_context_flow "run pytest on this module")
assert_contains "pytest_keyword" "$result" "Python patterns"

# Test 13: "golang" injects go-patterns content
setup_test
result=$(run_context_flow "refactor the golang service")
assert_contains "golang_keyword" "$result" "Go patterns"

# Test 14: "goroutine" injects go-patterns content
setup_test
result=$(run_context_flow "fix the goroutine leak")
assert_contains "goroutine_keyword" "$result" "Go patterns"

# Test 15: "rustc" injects rust-patterns content
setup_test
result=$(run_context_flow "install rustc and cargo toolchain")
assert_contains "rustc_keyword" "$result" "Rust patterns"

# Test 16: "cargo.toml" injects rust-patterns content
setup_test
result=$(run_context_flow "edit the cargo.toml workspace")
assert_contains "cargo_toml_keyword" "$result" "Rust patterns"

# Test 17: "change" does NOT inject go-patterns (chan collision avoided)
setup_test
result=$(run_context_flow "change the variable name")
assert_eq "no_chan_collision" "{}" "$result"

# Test 18: "engine" does NOT inject go-patterns (gin collision avoided)
setup_test
result=$(run_context_flow "update the search engine")
assert_eq "no_gin_collision" "{}" "$result"

# Test 19: "trust" does NOT inject rust-patterns (rust collision avoided)
setup_test
result=$(run_context_flow "I trust this approach")
assert_eq "no_rust_collision" "{}" "$result"

# Test 20: "borrow" does NOT inject rust-patterns (borrow collision avoided)
setup_test
result=$(run_context_flow "borrow the logic from that module")
assert_eq "no_borrow_collision" "{}" "$result"

# Test 21: "[decision]" in prompt triggers decision message
setup_test
result=$(run_context_flow "[decision] use Postgres for this")
assert_contains "decision_keyword" "$result" "Decision detected"

# Test 22: "done for today" triggers session-end reminder
setup_test
result=$(run_context_flow "done for today")
assert_contains "session_end_reminder" "$result" "session-end"

# --- Mode derivation: read_field "mode" -> last_event mode_set (first token, default normal) ---

# Test 23: mode_set=cautious + edit-related prompt injects the cautious-mode warning
setup_test
result=$(run_context_flow_with_events "edit the auth handler" "ctx-cautious" \
  "1700000001|mode_set|cautious")
assert_contains "cautious_mode_injects_warning" "$result" "Cautious mode active"

# Test 24: no mode_set event (default "normal") does NOT inject the cautious warning,
# even for an edit-related prompt that would trigger it under cautious mode
setup_test
result=$(run_context_flow "edit the auth handler")
assert_not_contains "default_mode_no_cautious_warning" "$result" "Cautious mode active"

# Test 25: mode_set with trailing tokens ("cautious <reason>") still matches via
# first-token extraction (${mode%% *})
setup_test
result=$(run_context_flow_with_events "fix the login bug" "ctx-cautious-reason" \
  "1700000001|mode_set|cautious high-churn")
assert_contains "cautious_mode_first_token_extraction" "$result" "Cautious mode active"

# Test 26: cautious injection fires ONCE per session — a second cautious-
# eligible prompt in the same session stays silent because the first firing
# appended `intervention cautious_mode` (spec §3.3 vocabulary), and the guard
# checks that event's presence rather than a keyword list (R4: the old
# keyword list — edit|fix|add|implement|build|refactor|change|update — is
# deleted entirely; ANY prompt is now cautious-eligible on the session's
# first opportunity).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "ctx-cautious-once" \
  "1700000001|mode_set|cautious")
json1=$(mock_json "user_prompt=hello there" "session_id=ctx-cautious-once")
result1=$(echo "$json1" | bash "$SANDBOX/hooks/scripts/context-flow.sh" 2>/dev/null || true)
json2=$(mock_json "user_prompt=implement the new feature" "session_id=ctx-cautious-once")
result2=$(echo "$json2" | bash "$SANDBOX/hooks/scripts/context-flow.sh" 2>/dev/null || true)
assert_contains "cautious_fires_once_first_call" "$result1" "Cautious mode active"
assert_not_contains "cautious_fires_once_second_call_silent" "$result2" "Cautious mode active"
intervention_count=$(count_events intervention cautious_mode '' "$LOG")
assert_eq "cautious_intervention_appended_exactly_once" "1" "$intervention_count"

# Test 26b: the once-per-session gate is content-independent — a SECOND
# cautious-eligible prompt stays silent even when it contains "additional"/
# "fixture" (the substrings the old keyword list falsely matched on "add"/
# "fix" — R4). Proves the fix isn't just "these two words are special-cased"
# but that no prompt re-fires once the session's one opportunity is spent.
setup_test
result=$(run_context_flow_with_events "additional context here" "ctx-cautious-collision" \
  "1700000001|mode_set|cautious" \
  "1700000002|intervention|cautious_mode")
assert_not_contains "collision_additional_no_retrigger" "$result" "Cautious mode active"
result=$(run_context_flow_with_events "fixture setup" "ctx-cautious-collision2" \
  "1700000001|mode_set|cautious" \
  "1700000002|intervention|cautious_mode")
assert_not_contains "collision_fixture_no_retrigger" "$result" "Cautious mode active"

# --- R4 collision fixes: cautious keyword-list deleted, wrap-up trigger narrowed ---

# Test 27: "additional context here" triggers NOTHING in a normal (non-
# cautious) session — general inertness check, same pattern as the
# no_chan/no_gin/no_rust/no_borrow collision tests above (old keyword list
# matched "add" as a substring of "additional" — R4).
setup_test
result=$(run_context_flow "additional context here")
assert_eq "collision_additional_triggers_nothing" "{}" "$result"

# Test 28: "fixture setup" triggers NOTHING in a normal session (old keyword
# list matched "fix" as a substring of "fixture" — R4).
setup_test
result=$(run_context_flow "fixture setup")
assert_eq "collision_fixture_triggers_nothing" "{}" "$result"

# Test 29: "call it with these args" does NOT trigger the wrap-up reminder —
# narrowed from the bare "call it" substring to
# "call it a day|call it a night|calling it".
setup_test
result=$(run_context_flow "call it with these args")
assert_eq "collision_call_it_with_args_triggers_nothing" "{}" "$result"

# Test 30: "call it a day" still triggers the wrap-up reminder
setup_test
result=$(run_context_flow "let's call it a day")
assert_contains "wrapup_call_it_a_day" "$result" "session-end"

# Test 31: "call it a night" still triggers the wrap-up reminder
setup_test
result=$(run_context_flow "going to call it a night")
assert_contains "wrapup_call_it_a_night" "$result" "session-end"

# Test 32: "calling it" still triggers the wrap-up reminder
setup_test
result=$(run_context_flow "I'm calling it for today")
assert_contains "wrapup_calling_it" "$result" "session-end"

end_suite
