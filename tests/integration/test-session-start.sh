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

# setup_opted_test — setup_test() wipes .claude/* before every test (fresh
# state per test), which also wipes the sentinel setup_script_sandbox stamped
# once at suite start. Unlike the other dispatcher suites, session-start is
# the CREATOR of the event log (never a create_event_log consumer that would
# re-stamp the sentinel as a side effect), so every test in this file must
# re-mark the project opted-in itself (spec §4.3 gate). Un-opted-repo
# behavior (incl. the T4 proof that grandfathering is GONE) is tested in
# tests/integration/test-opt-in-gate.sh — every test below exercises normal
# (already opted-in) session-start behavior.
setup_opted_test() {
  setup_test
  mkdir -p "$_TEST_TMPDIR/.claude/cortex"
  touch "$_TEST_TMPDIR/.claude/cortex/enabled"
}

# --- Test 1: creates the event log with the HARD session_start format ---
setup_opted_test
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

# --- Test 1b: a missing/malformed/rejected sid creates NOTHING (wave review
# I-5: the old epoch-PID fallback minted phantom sessions — logs with
# provenance and carry-over attributed to an identity nothing else knows.
# "No sid ⇒ skip and say nothing" now holds at the log CREATOR too.) ---
setup_opted_test
traversal_sid="../../../../escaped"
result=$(run_session_start "$(mock_json "session_id=$traversal_sid")")
assert_eq "rejected_sid_returns_empty" "{}" "$result"
# `find` on a dir the inert boot (correctly) never created exits 1 — pipefail-safe.
log_count=$(find "$(_eio_sessions_dir)" -name '*.events.log' 2>/dev/null | wc -l | tr -d ' ' || true)
assert_eq "rejected_sid_creates_no_log" "0" "${log_count:-0}"
escaped_outside="absent"
[ -f "$_TEST_TMPDIR/escaped.events.log" ] && escaped_outside="present"
assert_eq "traversal_sid_creates_no_outside_log" "absent" "$escaped_outside"

# And a payload with NO session_id at all: identical inertness.
setup_opted_test
result=$(run_session_start '{"no_sid":"here"}')
assert_eq "sidless_boot_returns_empty" "{}" "$result"
log_count=$(find "$(_eio_sessions_dir)" -name '*.events.log' 2>/dev/null | wc -l | tr -d ' ' || true)
assert_eq "sidless_boot_creates_no_log" "0" "${log_count:-0}"

# --- Test 2: mode_set / threshold_set / carry_over_age appended (defaults) ---
setup_opted_test
sid="ss-events"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "mode_set_defaults_to_normal_boot" "normal boot" "$(last_event mode_set "$NEW_LOG")"
assert_eq "threshold_set_defaults_to_15" "15" "$(last_event threshold_set "$NEW_LOG")"
assert_eq "carry_over_age_zero_when_no_carryover" "0" "$(last_event carry_over_age "$NEW_LOG")"

# --- Test 3: v2 health rows with a rising fix_ratio median (last-5 vs
# prior-5 delta > 0.15, spec §6.2 WAVE-4 TUNABLE) drive mode_set=cautious,
# reason token "fix_ratio". Commit-threshold adjustment from avg_edits_per_commit
# is GONE in v2 (that header field no longer exists) — threshold_set always
# carries the flat default now. ---
setup_opted_test
sid="ss-cautious"
HF="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$(dirname "$HF")"
create_health_file "$HF" \
  "v2|2026-06-01|old-sid-1|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-02|old-sid-2|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-03|old-sid-3|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-04|old-sid-4|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-05|old-sid-5|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-06|old-sid-6|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-07|old-sid-7|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-08|old-sid-8|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-09|old-sid-9|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-10|old-sid-10|2|5|0.50|0|0|pass|10|3|iterating|src|0"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "rising_fix_ratio_sets_cautious_mode" "cautious fix_ratio" "$(last_event mode_set "$NEW_LOG")"
assert_eq "threshold_set_flat_default_in_v2" "15" "$(last_event threshold_set "$NEW_LOG")"

# --- Test 3b: the SAME rising fix_ratio pattern with fewer than 10 non-idle
# v2 rows must NOT trigger cautious mode (spec §6.2: trend requires >=10
# non-idle v2 rows; "no cautious mode from trend" below that). ---
setup_opted_test
sid="ss-not-enough-rows"
HF="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$(dirname "$HF")"
create_health_file "$HF" \
  "v2|2026-06-01|old-sid-1|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-02|old-sid-2|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-06|old-sid-6|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-07|old-sid-7|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-08|old-sid-8|2|5|0.50|0|0|pass|10|3|iterating|src|0"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "below_10_rows_no_cautious_mode" "normal boot" "$(last_event mode_set "$NEW_LOG")"

# --- Test 3c: legacy (non-v2) rows are counted for row totals elsewhere but
# EXCLUDED from the >=10 gate — 5 legacy + 5 v2 (rising) rows still stays
# below threshold on the v2-only count, so no cautious mode fires even though
# the file has 10 data rows total. ---
setup_opted_test
sid="ss-legacy-excluded"
HF="$_TEST_TMPDIR/.claude/cortex/health.local.md"
mkdir -p "$(dirname "$HF")"
create_health_file "$HF" \
  "2026-05-01|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-05-02|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-05-03|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-05-04|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "2026-05-05|0|1.0|true|0|0|0|0|10|1|focused|proj" \
  "v2|2026-06-01|old-sid-1|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-02|old-sid-2|2|5|0.00|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-06|old-sid-6|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-07|old-sid-7|2|5|0.50|0|0|pass|10|3|iterating|src|0" \
  "v2|2026-06-08|old-sid-8|2|5|0.50|0|0|pass|10|3|iterating|src|0"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_eq "legacy_rows_excluded_from_trend_gate" "normal boot" "$(last_event mode_set "$NEW_LOG")"

# --- Test 4: NO singleton identity files (calibration wave T5, queue item
# 6): current-session.id and native-hooks.ok are DELETED — the sid travels
# explicitly via the injected context (asserted below). A guest boot can no
# longer clobber a shared marker because there is no shared marker. ---
setup_opted_test
sid="ss-marker"
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_eq "no_current_session_id_created" "no" \
  "$([ -f "$_TEST_TMPDIR/.claude/cortex/current-session.id" ] && echo yes || echo no)"
assert_eq "no_native_hooks_marker_created" "no" \
  "$([ -f "$_TEST_TMPDIR/.claude/cortex/native-hooks.ok" ] && echo yes || echo no)"
assert_contains "sid_injected_into_context" "$result" "Session id: ${sid}"

# --- Test 5: unaddressed carry-over in a prior event log resurfaces ---
setup_opted_test
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
setup_opted_test
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
setup_opted_test
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
setup_opted_test
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

# --- Test 8: legacy *.local.md files are INERT (calibration T4: the legacy
# carry-over reader died with state-io.sh — event logs are the SOLE carry-over
# source; a leftover v3 file on disk is ignored, not surfaced) ---
setup_opted_test
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
assert_not_contains "legacy_carryover_not_surfaced" "$result" "Legacy carryover item"
assert_not_contains "legacy_carryover_not_reappended" "$new_items" "Legacy carryover item"
assert_file_exists "legacy_file_left_on_disk_untouched" \
  "$_TEST_TMPDIR/.claude/cortex/sessions/legacy-week/legacy-sess.local.md"

# --- Test 9: NO .local.md state file is created for the new session ---
setup_opted_test
sid="ss-nostatefile"
run_session_start "$(mock_json "session_id=$sid")" > /dev/null
md_count=$(find "$(_eio_week_dir)" -name '*.local.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no_local_md_state_file_created" "0" "$md_count"

# --- Test 10: output is valid JSON carrying additional_context ---
setup_opted_test
sid="ss-json"
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_json_valid "output_is_valid_json" "$result"
assert_contains "output_has_additional_context" "$result" "additional_context"
assert_contains "output_has_session_start_marker" "$result" "cortex-session-start"

# --- Test 11: empty stdin still exits 0 with valid JSON ---
setup_opted_test
set +e
result=$(printf '' | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" 2>/dev/null)
rc=$?
set -e
assert_eq "empty_stdin_exit_0" "0" "$rc"
assert_json_valid "empty_stdin_valid_json" "$result"

# --- Test 12: malformed (non-JSON) stdin still exits 0 with valid JSON ---
# jq/python3 sid-extraction exit non-zero on garbage; under set -euo pipefail the
# failing command substitution must not kill the hook (contract: exit 0 + JSON).
setup_opted_test
set +e
result=$(printf 'not valid json {{{' | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" 2>/dev/null)
rc=$?
set -e
assert_eq "malformed_stdin_exit_0" "0" "$rc"
assert_json_valid "malformed_stdin_valid_json" "$result"

# --- Test 12b: pretty-printed stdin + jq/python3 masked → tier-3 bash/awk
# fallback alone extracts session_id and the log is created with the correct
# sid (Codex I-3, end-to-end). Uses a scoped mock-bin with its own PATH
# prepend/restore (not the suite-level MOCK_BIN) so other tests in this file
# keep real jq/python3 + git/gh available. Direct `export PATH=` (not
# mock-commands.sh's setup_mock_path) — that helper exports PATH from inside
# the $(...) command substitution used to capture its echoed mock-bin path,
# i.e. inside a subshell, so the mutation never reaches the caller; see task
# report.
setup_opted_test
sid="ss-pretty-tier3"
TIER3_MOCK="$_TEST_TMPDIR/tier3-mock-bin"
mkdir -p "$TIER3_MOCK"
hide_command "$TIER3_MOCK" "jq"
hide_command "$TIER3_MOCK" "python3"
SAVED_PATH_TIER3="$PATH"
export PATH="$TIER3_MOCK:$PATH"
pretty_json=$(printf '{\n  "session_id": "%s",\n  "source": "startup"\n}' "$sid")
printf '%s' "$pretty_json" | HOME="$_TEST_TMPDIR" bash "$SANDBOX/hooks/session-start" > /dev/null 2>&1 || true
export PATH="$SAVED_PATH_TIER3"
NEW_LOG="$(_eio_week_dir)/${sid}.events.log"
assert_file_exists "pretty_json_tier3_creates_log" "$NEW_LOG"
assert_eq "pretty_json_tier3_correct_sid" "$sid" "$(basename "$NEW_LOG" .events.log)"

# --- Test 13: a pre-existing event log is NOT clobbered by a same-sid start ---
# session-start must skip the `>` create when the log already exists, so prior
# events (e.g. from a resumed session with the same id) survive.
setup_opted_test
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
setup_opted_test
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
setup_opted_test
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
setup_opted_test
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

# --- Test 16: every-10th-session intervention report (spec §6.3, T5p2) ---
# Exactly 10 prior logs (count % 10 == 0, count > 0) → session-start surfaces
# the 30-day follow-through report in its context output.
setup_opted_test
sid="ss-ir-10th"
for i in $(seq 1 9); do
  create_event_log "$_TEST_TMPDIR/.claude" "prior-ir-$i" > /dev/null
done
create_event_log "$_TEST_TMPDIR/.claude" "prior-ir-10" \
  "1700000002|intervention|commit_nudge" \
  "1700000003|commit|abc1 feat: y" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_contains "tenth_session_surfaces_intervention_report" "$result" "Intervention follow-through"
assert_contains "tenth_session_report_counts" "$result" "commit_nudge: 1/1"

# --- Test 16b: 9 prior logs (count % 10 != 0) → NO report block, even though
# intervention data exists ---
setup_opted_test
sid="ss-ir-9th"
for i in $(seq 1 8); do
  create_event_log "$_TEST_TMPDIR/.claude" "prior-ir9-$i" > /dev/null
done
create_event_log "$_TEST_TMPDIR/.claude" "prior-ir9-9" \
  "1700000002|intervention|commit_nudge" \
  "1700000003|commit|abc1 feat: y" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_not_contains "ninth_session_no_intervention_report" "$result" "Intervention follow-through"

# --- Test 16c: retirement candidates (WAVE-4 TUNABLE: >=10 fires AND <20%
# follow-through) — commit_nudge at 1/10 (10%) IS flagged; journal_checkpoint
# at exactly 2/10 (20%) is NOT (strict <). The "- consider" suffix directly
# after the kind pins that commit_nudge is the ONLY listed candidate. ---
setup_opted_test
sid="ss-ir-retire"
for i in $(seq 1 9); do
  create_event_log "$_TEST_TMPDIR/.claude" "prior-ret-$i" > /dev/null
done
retire_seed=(
  "1700000001|intervention|commit_nudge"
  "1700000002|commit|abc1 feat: a"
)
for i in $(seq 3 11); do
  retire_seed+=("$((1700000000 + i))|intervention|commit_nudge")
done
for i in $(seq 12 16); do
  retire_seed+=("$((1700000000 + i))|file_edit|r C:/p/exhaust${i}.ts")
done
retire_seed+=(
  "1700000017|intervention|journal_checkpoint"
  "1700000018|intervention|journal_checkpoint"
  "1700000019|journal_edit|memory/2026-07-10.md"
)
for i in $(seq 20 27); do
  retire_seed+=("$((1700000000 + i))|intervention|journal_checkpoint")
done
for i in $(seq 28 37); do
  retire_seed+=("$((1700000000 + i))|tool_call|Read")
done
create_event_log "$_TEST_TMPDIR/.claude" "prior-ret-10" "${retire_seed[@]}" > /dev/null
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_contains "retirement_candidate_flagged" "$result" "Retirement candidate"
assert_contains "retirement_candidate_only_commit_nudge" "$result" "commit_nudge - consider"
assert_contains "boundary_20pct_reported_not_flagged" "$result" "journal_checkpoint: 2/10"

# --- Test 17: hot-files social warning is DERIVED from prior event logs
# (wave 5, locked D6) — cross-session.local.md is neither read nor written;
# a legacy tracker file with a poison path must not leak into the output ---
setup_opted_test
sid="ss-hotfiles"
for i in $(seq 1 4); do
  create_event_log "$_TEST_TMPDIR/.claude" "hot-$i" \
    "1700000002|file_edit|r ${_TEST_TMPDIR}/src/lib/recurring.ts" > /dev/null
done
printf '# Cross-Session File Edit Tracker\nC:/poison/old-tracker.ts|9|2026-07-01\n' \
  > "$_TEST_TMPDIR/.claude/cortex/cross-session.local.md"
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_contains "hot_files_derived_from_logs" "$result" "Frequently edited files"
assert_contains "hot_files_lists_path_with_count" "$result" "recurring.ts (4 sessions)"
assert_not_contains "legacy_tracker_file_not_read" "$result" "old-tracker.ts"

# --- Test 18: context diet (spec §10/R6) — the wholesale SKILL.md body is no
# longer injected every boot; a compact pulse with a pointer to the full
# skill replaces it (per-session data blocks are unaffected) ---
setup_opted_test
sid="ss-diet"
result=$(run_session_start "$(mock_json "session_id=$sid")")
assert_contains "diet_pulse_pointer_present" "$result" "full protocol: /cortex:session-start"
assert_not_contains "diet_full_skill_body_absent" "$result" "references/memory-tiers.md"

export PATH="$SAVED_PATH"
end_suite
