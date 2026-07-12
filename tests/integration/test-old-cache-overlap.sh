#!/usr/bin/env bash
set -euo pipefail
# Old-cache-scripts bounded-overlap harness (spec §4.2, §12). Proves that if a
# STALE pre-conversion plugin cache (e.g. an old plugin-cache copy that
# predates the v4 append-only event-log storage migration) somehow still gets
# invoked against an ALREADY-CONVERTED v4 project — a plausible transition-
# window scenario, since Claude Code's plugin cache and a project's
# .claude/cortex/ state can independently be at different versions — it
# cannot corrupt v4 state. The archived scripts source lib/state-io.sh (the
# v3 *.local.md reader/writer) and have never heard of the v4 append-only
# event log at all: no --native flag, no native-hooks.ok check, no
# resolve_event_log call anywhere in that tree.
#
# 3522710 = last pre-conversion commit (immediately before the event-log
# storage migration began). Extracted via `git archive` (not per-file `git
# show`) so the archived tree's `source "$SCRIPT_DIR/lib/..."` relative-path
# sourcing resolves correctly against sibling files in the SAME archived tree.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "old-cache-overlap"

OLD_COMMIT="3522710"

# --- Extract the archived pre-conversion hooks/scripts tree ---
OLD_TREE="$_TEST_TMPDIR/old-tree"
mkdir -p "$OLD_TREE"
git -C "$PLUGIN_ROOT" archive "$OLD_COMMIT" hooks/scripts | tar -x -C "$OLD_TREE"

# Sanity check (explicit verification requirement): the archived
# post-dispatch.sh must source state-io.sh — confirms this really is a
# genuinely PRE-conversion tree (a false-passing empty extraction, or one
# that accidentally picked up the CURRENT event-io.sh-based scripts, would
# make every assertion below vacuous).
assert_file_exists "old_tree_post_dispatch_exists" "$OLD_TREE/hooks/scripts/post-dispatch.sh"
assert_contains "old_post_dispatch_sources_state_io" \
  "$(cat "$OLD_TREE/hooks/scripts/post-dispatch.sh")" 'source "$SCRIPT_DIR/lib/state-io.sh"'
assert_file_not_contains "old_post_dispatch_does_not_source_event_io" \
  "$OLD_TREE/hooks/scripts/post-dispatch.sh" "event-io.sh"

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

# run_old <script> <proj> <home> <json>
# HOME is redirected alongside CORTEX_PROJECT_DIR per the brief's explicit
# note: the old scripts run state-io.sh's migrate_state_files() at SOURCE
# TIME (unconditional top-level call, not gated behind any opt-in check —
# that gate didn't exist yet in this pre-conversion tree), so both must point
# into the sandbox before ANY of the 3 scripts below are invoked, guaranteeing
# nothing outside $_TEST_TMPDIR is ever touched.
run_old() {
  local script="$1" proj="$2" home="$3" json="$4"
  printf '%s' "$json" | CORTEX_PROJECT_DIR="$proj" HOME="$home" bash "$OLD_TREE/hooks/scripts/${script}.sh" 2>/dev/null
}

# ============================================================================
# Opted v4 project fixture: event log + sentinel + native marker present —
# the documented first-4.0-session state (spec §4.2) an old cached script
# could theoretically still run against mid-transition.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj"
HOME_DIR="$_TEST_TMPDIR/fake-home"
mkdir -p "$HOME_DIR"
SID="oc-test"
LOG=$(create_event_log "$PROJ/.claude" "$SID")
mkdir -p "$PROJ/.claude/cortex"
printf '3.18.1 2026-07-08T00:00:00Z\n' > "$PROJ/.claude/cortex/native-hooks.ok"

LOG_BEFORE=$(cat "$LOG")
TREE_BEFORE=$(find "$PROJ/.claude" | sort)

# --- Run the 3 archived scripts against the SAME fixture, normal payloads ---
json_post=$(mock_json "tool_name=Bash" "session_id=$SID" "tool_input.command=echo hi")
set +e
out_post=$(run_old "post-dispatch" "$PROJ" "$HOME_DIR" "$json_post")
rc_post=$?
set -e
assert_eq "old_post_dispatch_exit_0" "0" "$rc_post"
assert_json_valid "old_post_dispatch_valid_json" "$out_post"

json_pre=$(mock_json "tool_name=Bash" "session_id=$SID" "tool_input.command=git push origin master")
set +e
out_pre=$(run_old "pre-dispatch" "$PROJ" "$HOME_DIR" "$json_pre")
rc_pre=$?
set -e
assert_eq "old_pre_dispatch_exit_0" "0" "$rc_pre"
assert_json_valid "old_pre_dispatch_valid_json" "$out_pre"
# git-push payload legitimately produces an advisory systemMessage (spec
# §4.2's "output {} or advisory-only systemMessage" clause) — must NOT be a
# blocking deny, which would be actual v4-corrupting interference.
assert_not_contains "old_pre_dispatch_no_deny" "$out_pre" '"deny"'

json_ctx=$(mock_json "user_prompt=please summarize the recent changes" "session_id=$SID")
set +e
out_ctx=$(run_old "context-flow" "$PROJ" "$HOME_DIR" "$json_ctx")
rc_ctx=$?
set -e
assert_eq "old_context_flow_exit_0" "0" "$rc_ctx"
assert_json_valid "old_context_flow_valid_json" "$out_ctx"

# ============================================================================
# Assertion 1: event log byte-for-byte unchanged — old scripts never append
# to it. They don't know it exists: state-io.sh's resolve_state_file only
# ever touches *.local.md paths, and append_event/resolve_event_log (the only
# v4 write primitives) are not present anywhere in the archived tree.
# ============================================================================
LOG_AFTER=$(cat "$LOG")
assert_eq "old_scripts_event_log_byte_unchanged" "$LOG_BEFORE" "$LOG_AFTER"

# ============================================================================
# Assertion 2: no v3 *.local.md state file created anywhere under .claude —
# the actual "no state-file creation" guarantee spec §4.2 documents.
# resolve_state_file() (called by all 3 scripts) only ever SETS the STATE_FILE
# path variable; it never creates the file itself (only init_state_file,
# which none of these 3 dispatchers call, does that) — verified empirically.
# ============================================================================
LOCAL_MD_COUNT=$(find "$PROJ/.claude" -name '*.local.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "old_scripts_no_local_md_created" "0" "$LOCAL_MD_COUNT"

# ============================================================================
# Assertion 3: the ONLY new filesystem entries anywhere under .claude are
# empty directories and/or state-io.sh's `.migrated-v3.7` sentinel file.
#
# NOTE — this is a deliberately corrected version of the brief's "delta
# contains NO files, only possibly empty dirs" prediction. Empirically
# verified (see task-7-report.md) that source-time migrate_state_files()
# DOES write .claude/cortex/.migrated-v3.7 (a one-line completion sentinel)
# on a project with no sentinel yet. The writer here is the ARCHIVED tree's
# own state-io.sh copy — the CURRENT plugin deleted state-io.sh entirely in
# the calibration wave (T4), so live code can never write this sentinel; the
# allowance below exists purely for the archived-scripts overlap scenario.
# It is idempotent (only the first of the 3 invocations above actually
# writes it; the other two see the sentinel and skip) and inert to v4's
# event-log-based reads. The two guarantees that actually matter for v4
# correctness — event log integrity and no *.local.md creation — are
# asserted explicitly above; this assertion additionally proves nothing
# ELSE unexpected leaked out.
# ============================================================================
TREE_AFTER=$(find "$PROJ/.claude" | sort)
NEW_ENTRIES=$(comm -13 <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER"))
UNEXPECTED_NEW_FILES=""
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  [ -d "$entry" ] && continue                                  # empty dirs OK
  [ "$(basename "$entry")" = ".migrated-v3.7" ] && continue     # documented sentinel OK
  UNEXPECTED_NEW_FILES="${UNEXPECTED_NEW_FILES}${entry}"$'\n'
done <<< "$NEW_ENTRIES"
assert_eq "old_scripts_no_unexpected_new_files" "" "$UNEXPECTED_NEW_FILES"

# ============================================================================
# UPGRADED-PROJECT overlap (Codex I-5): an ALREADY-v4 project that ALSO still
# carries a leftover legacy v3 *.local.md state file (a realistic mid-upgrade
# shape) — run the OTHER three archived stop/end/compact scripts (the write-
# heavy ones state-io.sh backs) against it. These v3 scripts legitimately write
# v3 artifacts (health.local.md, cross-session.local.md, stop-gate-counter,
# .migrated-v3.7) off the legacy state file — that's expected v3 behavior in
# the overlap window, so this block does NOT assert a byte-frozen tree. It pins
# the boundary that actually matters for v4 correctness: the v4 EVENT LOG is
# byte-unchanged and NO new *.events.log file is ever created (the archived
# tree has no append_event / resolve_event_log — it cannot touch event logs).
# ============================================================================
setup_test
UPROJ="$_TEST_TMPDIR/uproj"
UHOME="$_TEST_TMPDIR/uhome"
mkdir -p "$UHOME"
USID_LOG="oc-up-eventlog"
USID_STATE="oc-up-legacy"
ULOG=$(create_event_log "$UPROJ/.claude" "$USID_LOG")     # v4 event log + sentinel
create_state_file "$UPROJ/.claude" "$USID_STATE" > /dev/null  # leftover v3 *.local.md
create_journal "$UPROJ" "$(date +%Y-%m-%d)"                # gives session-end a PROJECT_DIR/memory

ULOG_BEFORE=$(cat "$ULOG")
EVENTLOG_COUNT_BEFORE=$(find "$UPROJ/.claude" -name '*.events.log' 2>/dev/null | wc -l | tr -d ' ')

# resolve_state_file (v3) keys off the legacy .local.md, so pass its sid.
u_json_stop=$(mock_json "session_id=$USID_STATE")
set +e
u_out_stop=$(run_old "stop-gate" "$UPROJ" "$UHOME" "$u_json_stop")
u_rc_stop=$?
set -e
assert_eq "upgraded_old_stop_gate_exit_0" "0" "$u_rc_stop"
assert_json_valid "upgraded_old_stop_gate_valid_json" "$u_out_stop"

u_json_end=$(mock_json "session_id=$USID_STATE")
set +e
u_out_end=$(run_old "session-end-dispatch" "$UPROJ" "$UHOME" "$u_json_end")
u_rc_end=$?
set -e
assert_eq "upgraded_old_session_end_exit_0" "0" "$u_rc_end"
assert_json_valid "upgraded_old_session_end_valid_json" "$u_out_end"

u_json_compact=$(mock_json "session_id=$USID_STATE")
set +e
u_out_compact=$(run_old "pre-compact" "$UPROJ" "$UHOME" "$u_json_compact")
u_rc_compact=$?
set -e
assert_eq "upgraded_old_pre_compact_exit_0" "0" "$u_rc_compact"
assert_json_valid "upgraded_old_pre_compact_valid_json" "$u_out_compact"

# Boundary 1: the v4 event log is byte-for-byte unchanged.
ULOG_AFTER=$(cat "$ULOG")
assert_eq "upgraded_old_scripts_event_log_byte_unchanged" "$ULOG_BEFORE" "$ULOG_AFTER"

# Boundary 2: no NEW *.events.log created anywhere (count stays exactly 1).
EVENTLOG_COUNT_AFTER=$(find "$UPROJ/.claude" -name '*.events.log' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "upgraded_old_scripts_event_log_count_unchanged" "$EVENTLOG_COUNT_BEFORE" "$EVENTLOG_COUNT_AFTER"
assert_eq "upgraded_old_scripts_no_new_event_log" "1" "$EVENTLOG_COUNT_AFTER"

export PATH="$SAVED_PATH"
end_suite
