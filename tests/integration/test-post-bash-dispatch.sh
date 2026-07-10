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

# Test 5b: compound `git add ... && git commit` ALSO appends the commit event.
# The line-anchored form silently dropped every compound-command commit — the
# session's edits-since-commit never reset, and (worse, post-T5) every
# commit_nudge in such a session scored as not-followed, poisoning the
# follow-through stats. The HEAD-recency guard, not the anchor, is what keeps
# non-committing invocations out.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-compound" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "feat: compound form commit"
sha=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
run_post_bash "commit-compound" "git add -A && git commit -m feat-test" > /dev/null
count=$(count_events commit '' '' "$LOG")
assert_eq "compound_commit_event_appended" "2" "$count"
assert_contains "compound_commit_event_sha" "$(list_events commit "$LOG")" "$sha"

# Test 5c: a QUOTED "git commit" inside another command (grep, echo "...") does
# not fire — the boundary class excludes quote characters
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-prose" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "feat: fresh head but not a commit command"
run_post_bash "commit-prose" "grep -rn 'git commit' docs/" > /dev/null
assert_eq "quoted_git_commit_does_not_fire" "1" "$(count_events commit '' '' "$LOG")"

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

# --- Per-language test detection (wave 4, spec §5.4/L6) ---

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-pytest")
run_post_bash "t-pytest" "pytest tests/unit" > /dev/null
assert_eq "pytest_appends_test_run" "pytest" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-pymod")
run_post_bash "t-pymod" "python3 -m pytest -x" > /dev/null
assert_eq "python_m_pytest_appends_test_run" "pytest" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-go")
run_post_bash "t-go" "go test ./..." > /dev/null
assert_eq "go_test_appends_test_run" "gotest" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-cargo")
run_post_bash "t-cargo" "cargo test --workspace" > /dev/null
assert_eq "cargo_test_appends_test_run" "cargotest" "$(last_event test_run "$LOG")"

# False positives: substrings and lookalike words must NOT fire
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-fp1")
run_post_bash "t-fp1" "echo pytest-docs" > /dev/null
assert_eq "pytest_substring_silent" "" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-fp2")
run_post_bash "t-fp2" "cat mypytest.log" > /dev/null
assert_eq "pytest_wordpart_silent" "" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-fp3")
run_post_bash "t-fp3" "echo let us go testing later" > /dev/null
assert_eq "go_prose_silent" "" "$(last_event test_run "$LOG")"

# Per-project test_command config ERE wins (checked FIRST)
setup_test
set_config "$_TEST_TMPDIR/.claude" "test_command" "make check"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-custom")
run_post_bash "t-custom" "make check" > /dev/null
assert_eq "custom_test_command_appends_custom" "custom" "$(last_event test_run "$LOG")"

# --- JS/TS test detection is word-boundary anchored like the other languages
# (Codex W4 review I-2): word-part lookalikes must not forge a test_run ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-fp-vitest")
run_post_bash "t-fp-vitest" "./mvitest run" > /dev/null
assert_eq "mvitest_wordpart_silent" "" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-fp-npmtesting")
run_post_bash "t-fp-npmtesting" "npm testing something" > /dev/null
assert_eq "npm_testing_wordpart_silent" "" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-vitest-anchored")
run_post_bash "t-vitest-anchored" "npx vitest run --coverage" > /dev/null
assert_eq "npx_vitest_still_fires" "vitest" "$(last_event test_run "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-npmtest-anchored")
run_post_bash "t-npmtest-anchored" "npm test" > /dev/null
assert_eq "npm_test_still_fires" "vitest" "$(last_event test_run "$LOG")"

# --- Commit event dedup against the last recorded commit (Codex W4 review
# I-3, spec §3.3 "HEAD verified changed"): a matched command that created no
# NEW commit within the recency window must not re-log the previous commit —
# re-logging it after newer file_edits would falsely reset Gate 1's
# edits-since-commit anchor ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-dedup")
make_commit "feat: dedup base"
run_post_bash "commit-dedup" "git commit -m feat-test" > /dev/null
assert_eq "dedup_first_commit_logged" "1" "$(count_events commit '' '' "$LOG")"
run_post_bash "commit-dedup" "echo git commit please" > /dev/null
assert_eq "unquoted_mention_does_not_relog_same_sha" "1" "$(count_events commit '' '' "$LOG")"
make_commit "feat: dedup second"
run_post_bash "commit-dedup" "git commit -m feat-test-2" > /dev/null
assert_eq "genuinely_new_commit_still_logged" "2" "$(count_events commit '' '' "$LOG")"

# --- Codex review detection (spec §5.6, D7/L9, T6) ---

# Bare `codex` CLI invocation → codex_review event, value "cli"
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-cli")
run_post_bash "codex-cli" "codex exec 'review the wave 4 diff'" > /dev/null
assert_eq "codex_cli_logs_review_event" "cli" "$(last_event codex_review "$LOG")"

# Chained codex (word-boundary form, not line-anchored) still matches
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-chained")
run_post_bash "codex-chained" "cd /tmp && codex resume task-x" > /dev/null
assert_eq "codex_chained_logs_review_event" "cli" "$(last_event codex_review "$LOG")"

# Companion runtime invocation (dispatch OR harvest step) → event
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-companion")
run_post_bash "codex-companion" "node C:/tools/codex-companion.mjs result task-42" > /dev/null
assert_eq "codex_companion_logs_review_event" "cli" "$(last_event codex_review "$LOG")"

# `codexify` (leading substring) must NOT match — word boundary required
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codexify")
run_post_bash "codexify" "codexify --run all" > /dev/null
assert_eq "codexify_no_event" "0" "$(count_events codex_review '' '' "$LOG")"

# `mycodex` (trailing substring) must NOT match either
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "mycodex")
run_post_bash "mycodex" "./mycodex status" > /dev/null
assert_eq "mycodex_no_event" "0" "$(count_events codex_review '' '' "$LOG")"

# A search/prose MENTION of the companion file must NOT fire (Codex W4 review
# M-1): only a node invocation shape counts as exercising the review loop
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-mention")
run_post_bash "codex-mention" "rg codex-companion.mjs docs/" > /dev/null
assert_eq "companion_mention_no_event" "0" "$(count_events codex_review '' '' "$LOG")"

end_suite
