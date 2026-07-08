#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "session-start"

# Create sandbox once for the suite (symlinks the real session-start entry point
# + event-io.sh; state-io.sh is sed-patched to resolve PROJECT_DIR at tmpdir).
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export runs
# inside the $(...) subshell above and never reaches this shell — event-io.sh
# resolves the project dir from this env var at call time, so it must be set here
# explicitly (pattern: tests/integration/test-post-dispatch.sh:22).
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Neutralize any inherited profile so PROFILE resolves to "standard".
unset CORTEX_PROFILE 2>/dev/null || true

# Mock git/gh so sensory-check (runs under standard profile) never touches the
# real network or a real repo.
MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

# run_session_start <json> — pipes JSON to the session-start hook. HOME is
# redirected to the test tmpdir so bootstrap-hooks.sh writes an isolated
# settings.json and the synthesis COLLAB_FILE lookup stays out of the real HOME.
run_session_start() {
  local json="$1"
  printf '%s' "$json" | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" 2>/dev/null || true
}

# --- Test 1: creates the event log with the HARD session_start format ---
setup_test
sid="ss-create"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_file_exists "event_log_created_in_week_dir" "$NEW_LOG"

ss_val=$(last_event session_start "$NEW_LOG")
ss_first="${ss_val%% *}"
ss_second="${ss_val#* }"
# First value token MUST parse as an ISO-8601 UTC timestamp (stop-gate Gate 6
# consumes it as the git --since anchor).
if printf '%s' "$ss_first" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  printf "    ${_GREEN}PASS${_RESET}  %s\n" "session_start_first_token_is_iso8601"
  _PASS_COUNT=$((_PASS_COUNT + 1))
else
  printf "    ${_RED}FAIL${_RESET}  %s\n" "session_start_first_token_is_iso8601"
  printf "          not ISO-8601: '%s'\n" "$ss_first"
  _FAIL_COUNT=$((_FAIL_COUNT + 1))
fi
assert_eq "session_start_second_token_is_model" "unknown" "$ss_second"

# --- Test 2: mode_set / threshold_set / carry_over_age appended (defaults) ---
setup_test
sid="ss-events"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "mode_set_defaults_to_normal_boot" "normal boot" "$(last_event mode_set "$NEW_LOG")"
assert_eq "threshold_set_defaults_to_15" "15" "$(last_event threshold_set "$NEW_LOG")"
assert_eq "carry_over_age_zero_when_no_carryover" "0" "$(last_event carry_over_age "$NEW_LOG")"

# --- Test 3: degrading health drives mode_set=cautious + tightened threshold ---
setup_test
sid="ss-cautious"
HF="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$(dirname "$HF")"
cat > "$HF" << 'HEOF'
trend_direction=degrading
avg_reasoning_misses=1.5
avg_edits_per_commit=30.0
avg_duration_min=12
---
2026-03-14|2|30|yes|0|0|0|1|12|3|high-churn|scoring
HEOF
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "degrading_trend_sets_cautious_mode" "cautious trend" "$(last_event mode_set "$NEW_LOG")"
assert_eq "high_epc_tightens_threshold" "5" "$(last_event threshold_set "$NEW_LOG")"

# --- Test 4: current-session.id marker written ---
setup_test
sid="ss-marker"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
MARKER="$_TEST_TMPDIR/.claude/cortex/current-session.id"
assert_file_exists "current_session_id_written" "$MARKER"
assert_eq "current_session_id_content" "$sid" "$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')"

# --- Test 5: unaddressed carry-over in a prior event log resurfaces ---
setup_test
sid="ss-carryover"
create_event_log "$_TEST_TMPDIR/.claude" "prior-open" \
  "1700000100|carry_over|- Fix scoring null handling" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
new_items=$(list_events carry_over "$NEW_LOG")
assert_contains "carryover_reappended_into_new_log" "$new_items" "Fix scoring null handling"
assert_contains "carryover_surfaced_in_output_context" "$result" "Fix scoring null handling"
assert_contains "carryover_output_has_header" "$result" "Carry-over from prior session"
assert_eq "carry_over_age_incremented" "1" "$(last_event carry_over_age "$NEW_LOG")"

# --- Test 6: an addressed item (hash present in same log) does NOT resurface ---
setup_test
sid="ss-addressed"
addr_item="- Addressed handling zzz"
addr_hash=$(eio_item_hash "$addr_item")
create_event_log "$_TEST_TMPDIR/.claude" "prior-closed" \
  "1700000100|carry_over|$addr_item" \
  "1700000200|carry_addressed|$addr_hash" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
new_items=$(list_events carry_over "$NEW_LOG")
assert_not_contains "addressed_item_not_reappended" "$new_items" "Addressed handling zzz"
assert_not_contains "addressed_item_absent_from_output" "$result" "Addressed handling zzz"

# --- Test 7: cross-log addressing (item in log A, hash in log B) reconciles ---
# Proves the union-first set-difference: an item addressed in a DIFFERENT log
# must still be suppressed.
setup_test
sid="ss-crosslog"
xitem="- Cross log handling qqq"
xhash=$(eio_item_hash "$xitem")
create_event_log "$_TEST_TMPDIR/.claude" "prior-A" "1700000100|carry_over|$xitem" > /dev/null
create_event_log "$_TEST_TMPDIR/.claude" "prior-B" "1700000200|carry_addressed|$xhash" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
new_items=$(list_events carry_over "$NEW_LOG")
assert_not_contains "cross_log_addressed_suppressed" "$new_items" "Cross log handling qqq"

# --- Test 7b: a re-raised item (carry epoch AFTER the addressed epoch) resurfaces ---
# Proves epoch ordering (spec §3.5 amendment): addressing does NOT permanently
# suppress an item — re-raising identical text later resurrects it.
setup_test
sid="ss-reraise"
ritem="- Reraised handling ccc"
rhash=$(eio_item_hash "$ritem")
create_event_log "$_TEST_TMPDIR/.claude" "prior-reraise" \
  "1700000100|carry_over|$ritem" \
  "1700000200|carry_addressed|$rhash" \
  "1700000300|carry_over|$ritem" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
new_items=$(list_events carry_over "$NEW_LOG")
assert_contains "reraised_item_resurfaces_in_new_log" "$new_items" "Reraised handling ccc"
assert_contains "reraised_item_surfaced_in_output" "$result" "Reraised handling ccc"

# --- Test 8: legacy *.local.md carry-over is still read + re-surfaced ---
setup_test
sid="ss-legacy"
mkdir -p "$_TEST_TMPDIR/.claude/cortex/sessions/legacy-week"
cat > "$_TEST_TMPDIR/.claude/cortex/sessions/legacy-week/legacy-sess.local.md" << 'LEOF'
session_id=legacy-sess
carry_over_age=0

[files_modified]

[carry_over]
- Legacy carryover item
[activity_log]
LEOF
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
new_items=$(list_events carry_over "$NEW_LOG")
assert_contains "legacy_carryover_read_into_output" "$result" "Legacy carryover item"
assert_contains "legacy_carryover_reappended_to_log" "$new_items" "Legacy carryover item"

# --- Test 9: NO .local.md state file is created for the new session ---
setup_test
sid="ss-nostatefile"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
md_count=$(find "$(_eio_week_dir)" -name '*.local.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no_local_md_state_file_created" "0" "$md_count"

# --- Test 10: output is valid JSON carrying additional_context ---
setup_test
sid="ss-json"
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_json_valid "output_is_valid_json" "$result"
assert_contains "output_has_additional_context" "$result" "additional_context"
assert_contains "output_has_session_start_marker" "$result" "cortex-session-start"

# --- Test 11: empty stdin still exits 0 with valid JSON ---
setup_test
set +e
result=$(printf '' | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" 2>/dev/null)
rc=$?
set -e
assert_eq "empty_stdin_exit_0" "0" "$rc"
assert_json_valid "empty_stdin_valid_json" "$result"

# --- Test 12: malformed (non-JSON) stdin still exits 0 with valid JSON ---
# jq/python3 sid-extraction exit non-zero on garbage; under set -euo pipefail the
# failing command substitution must not kill the hook (contract: exit 0 + JSON).
setup_test
set +e
result=$(printf 'not valid json {{{' | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" 2>/dev/null)
rc=$?
set -e
assert_eq "malformed_stdin_exit_0" "0" "$rc"
assert_json_valid "malformed_stdin_valid_json" "$result"

# --- Test 13: a pre-existing event log is NOT clobbered by a same-sid start ---
# session-start must skip the `>` create when the log already exists, so prior
# events (e.g. from a resumed session with the same id) survive.
setup_test
sid="ss-noclobber"
mkdir -p "$(_eio_week_dir)"
PRELOG="$(_eio_week_dir)/${sid}.events.log"
printf '%s|session_start|2026-03-14T00:00:00Z unknown\n' "1700000000" > "$PRELOG"
printf '%s|tool_call|SentinelTool\n' "1700000009" >> "$PRELOG"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
assert_contains "preexisting_event_survives_second_start" \
  "$(list_events tool_call "$PRELOG")" "SentinelTool"

# --- Test 14: header-only health file (zero data rows) does not crash start ---
# The health-file grep pipelines exit non-zero when a grep -v chain empties out;
# under pipefail the unguarded assignment would kill the hook mid-flight.
setup_test
sid="ss-headeronly-health"
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
create_health_file "$_TEST_TMPDIR/.claude/cortex/health.local.md"
set +e
result=$(printf '%s' "$(mock_json "session_id=$sid")" | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" 2>/dev/null)
rc=$?
set -e
assert_eq "header_only_health_exit_0" "0" "$rc"
assert_json_valid "header_only_health_valid_json" "$result"

# --- Test 15 (Commit 2): carry_over_age counts only logs with surviving items ---
# Log A carries item X (age 4) but X is addressed in log B; log B also carries a
# fresh unaddressed item Y (age 0). The new age must derive from Y's log (0+1=1),
# NOT bleed A's stale age (would give 5). Y resurfaces, X does not.
setup_test
sid="ss-age-survivors"
xitem="- Stale addressed item aaa"
xhash=$(eio_item_hash "$xitem")
yitem="- Fresh surviving item bbb"
create_event_log "$_TEST_TMPDIR/.claude" "age-A" \
  "1700000100|carry_over|$xitem" \
  "1700000101|carry_over_age|4" > /dev/null
create_event_log "$_TEST_TMPDIR/.claude" "age-B" \
  "1700000200|carry_addressed|$xhash" \
  "1700000201|carry_over|$yitem" \
  "1700000202|carry_over_age|0" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
new_items=$(list_events carry_over "$NEW_LOG")
assert_eq "age_counts_only_surviving_logs" "1" "$(last_event carry_over_age "$NEW_LOG")"
assert_contains "fresh_item_survives" "$new_items" "Fresh surviving item bbb"
assert_not_contains "stale_addressed_item_suppressed" "$new_items" "Stale addressed item aaa"

# --- Test 15b: age survival compares HASHES, not raw text (whitespace drift) ---
# eio_item_hash trims whitespace precisely because LLM-typed carry-over drifts:
# the same logical item may be carried whitespace-padded in one log and trimmed
# in another (hash-equal, text-unequal). The unresolved set dedups by hash and
# keeps only the FIRST-SEEN text variant — so a raw-text survival check misses
# the padded variant in the later-scanned log and drops its age.
# Fixture: age-drift-1 (scanned first, glob order) carries the item unpadded
# with age 1; age-drift-2 carries the SAME item with trailing spaces and age 6.
# Nothing addressed => the item survives. Both logs must be credited:
# new age = max(6,1)+1 = 7 — NOT 2 (text comparison credits only age-drift-1).
setup_test
sid="ss-age-drift"
ditem="- Whitespace drift item ddd"
create_event_log "$_TEST_TMPDIR/.claude" "age-drift-1" \
  "1700000100|carry_over|$ditem" \
  "1700000101|carry_over_age|1" > /dev/null
create_event_log "$_TEST_TMPDIR/.claude" "age-drift-2" \
  "1700000200|carry_over|${ditem}   " \
  "1700000201|carry_over_age|6" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "age_survival_matches_by_hash_not_text" "7" "$(last_event carry_over_age "$NEW_LOG")"
assert_contains "whitespace_drift_item_still_resurfaces" \
  "$(list_events carry_over "$NEW_LOG")" "Whitespace drift item ddd"

export PATH="$SAVED_PATH"
end_suite
