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
# on a project with no sentinel yet — this is NOT unique to the archived old
# scripts: the CURRENT v4 lib/state-io.sh (still sourced by session-start,
# per hook-architecture.md) contains the exact same source-time
# migrate_state_files() call and writes the identical sentinel. It is
# idempotent (only the first of the 3 invocations above actually writes it;
# the other two see the sentinel and skip) and inert to v4's event-log-based
# reads. The two guarantees that actually matter for v4 correctness — event
# log integrity and no *.local.md creation — are asserted explicitly above;
# this assertion additionally proves nothing ELSE unexpected leaked out.
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

export PATH="$SAVED_PATH"
end_suite
