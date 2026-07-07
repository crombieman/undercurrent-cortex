#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "post-bash-dispatch"

# Real git repo in the sandbox — commit-recency guard reads actual git log
# timestamps, so a mocked git (fixed canned output) can't exercise it.
git -C "$_TEST_TMPDIR" init -q
git -C "$_TEST_TMPDIR" config user.email "test@cortex.local"
git -C "$_TEST_TMPDIR" config user.name "Cortex Test"

# Helper: run post-bash-dispatch directly (no sandbox needed — event-io resolves
# the project dir lazily via CORTEX_PROJECT_DIR_OVERRIDE, unlike state-io's
# source-time PROJECT_DIR assignment; see test-post-edit-dispatch.sh).
run_post_bash() {
  local sid="$1" command_str="$2"
  # Journal must pre-exist — the hook only appends to it, never creates it
  # (session-start owns creation in production).
  mkdir -p "$_TEST_TMPDIR/memory"
  echo "# Journal" > "$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
  local json
  json=$(mock_json "session_id=$sid" "tool_input.command=$command_str")
  echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/scripts/post-bash-dispatch.sh" 2>/dev/null || true
}

# make_commit <message> [epoch_offset_seconds]
# Creates a real, empty commit in the sandbox repo. offset shifts the author/
# committer date away from "now" — pass a large negative number to simulate a
# stale commit for the recency guard.
make_commit() {
  local message="$1" offset="${2:-0}"
  local ts=$(( $(date +%s) + offset ))
  GIT_AUTHOR_DATE="@${ts}" GIT_COMMITTER_DATE="@${ts}" \
    git -C "$_TEST_TMPDIR" commit -q --allow-empty -m "$message"
}

# Test 1: npm test appends a test_run event
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "test-npm")
run_post_bash "test-npm" "npm test" > /dev/null
result=$(list_events test_run "$LOG")
assert_contains "npm_test_appends_test_run_event" "$result" "vitest"

# Test 2: npx vitest also appends a test_run event
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "test-vitest")
run_post_bash "test-vitest" "npx vitest run" > /dev/null
result=$(list_events test_run "$LOG")
assert_contains "npx_vitest_appends_test_run_event" "$result" "vitest"

# Test 3: test command with no resolvable event log doesn't crash
setup_test
result=$(run_post_bash "notest-log" "npm test")
assert_eq "test_command_without_event_log_returns_empty" "{}" "$result"

# Test 4: non-git, non-test command returns {}
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "npm-install")
result=$(run_post_bash "npm-install" "npm install lodash")
assert_eq "non_git_non_test_command_returns_empty" "{}" "$result"

# Test 5: git commit appends a commit event whose value carries sha + subject
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-fresh" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "feat: add fresh commit"
sha=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
run_post_bash "commit-fresh" "git commit -m feat-test" > /dev/null
result=$(list_events commit "$LOG")
count=$(count_events commit '' '' "$LOG")
assert_eq "commit_event_count_increments" "2" "$count"
assert_contains "commit_event_has_short_sha" "$result" "$sha"
assert_contains "commit_event_has_subject" "$result" "feat: add fresh commit"

# Test 6: git commit --amend does not append a commit event (existing count unchanged)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-amend" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "feat: pre-amend base"
result=$(run_post_bash "commit-amend" "git commit --amend")
after=$(count_events commit '' '' "$LOG")
assert_eq "amend_does_not_append_commit_event" "1" "$after"
assert_eq "amend_returns_empty_response" "{}" "$result"

# Test 7: conventional commit message — no warning, but journal context nudge
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-conventional")
make_commit "feat: conventional commit message"
result=$(run_post_bash "commit-conventional" "git commit -m test")
assert_contains "conventional_commit_no_warning" "$result" "Commit logged"
assert_not_contains "conventional_commit_no_warning_text" "$result" "Non-conventional"

# Test 8: non-conventional commit message triggers the format warning
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-nonconventional")
make_commit "just a plain commit message"
result=$(run_post_bash "commit-nonconventional" "git commit -m test")
assert_contains "non_conventional_commit_warns" "$result" "Non-conventional commit"

# Test 9: commit logging appends a line to the daily journal
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-journal")
make_commit "fix: journal logging test"
run_post_bash "commit-journal" "git commit -m test" > /dev/null
journal="$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
assert_file_contains "journal_logs_commit_message" "$journal" "commit: fix: journal logging test"

# Test 10: stale HEAD (commit older than 60s) skips the commit event, but the
# journal write + systemMessage flow still runs (mapping-table resolution)
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-stale" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "chore: stale commit" -1000
result=$(run_post_bash "commit-stale" "git commit -m test")
after=$(count_events commit '' '' "$LOG")
assert_eq "stale_commit_skips_event" "1" "$after"
assert_contains "stale_commit_still_prompts" "$result" "Commit logged"
journal="$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
assert_file_contains "stale_commit_journal_still_written" "$journal" "stale commit"

# Test 11: missing event log (no session log on disk) still journals + prompts —
# journal/systemMessage are document writes and advisory messages, not state.
setup_test
make_commit "docs: no session log test"
result=$(run_post_bash "commit-no-log" "git commit -m test")
assert_contains "missing_event_log_still_prompts" "$result" "Commit logged"
journal="$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
assert_file_contains "missing_event_log_journal_written" "$journal" "no session log test"

# Test 12: non-amend commit with NO journal file — the hook contract (always
# exit 0, valid JSON) must hold even when the journal is missing. Bypasses
# run_post_bash (which pre-creates the journal) and captures the real exit code
# (no || true swallowing).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-no-journal")
make_commit "feat: no journal present"
json=$(mock_json "session_id=commit-no-journal" "tool_input.command=git commit -m test")
rc=0
result=$(echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
  bash "$PLUGIN_ROOT/hooks/scripts/post-bash-dispatch.sh" 2>/dev/null) || rc=$?
assert_eq "missing_journal_exits_zero" "0" "$rc"
assert_json_valid "missing_journal_valid_json" "$result"

end_suite
