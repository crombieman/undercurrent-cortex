#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "post-bash-dispatch"

# Real git repo in the sandbox — the git-derived commit sensor enumerates
# `git log --since=<session anchor>`, so a mocked git (fixed canned output)
# can't exercise it.
#
# Suite-local setup_test override: every test starts with a COMMIT-FREE repo.
# The sensor enumerates the whole session window on ANY Bash observation, so
# commits left behind by an earlier test would leak into every later test's
# fresh event log (fixture anchor 2026-03-14 predates all test commits).
eval "orig_$(declare -f setup_test)"
setup_test() {
  orig_setup_test
  rm -rf "$_TEST_TMPDIR/.git"
  git -C "$_TEST_TMPDIR" init -q
  git -C "$_TEST_TMPDIR" config user.email "test@cortex.local"
  git -C "$_TEST_TMPDIR" config user.name "Cortex Test"
}
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

# Test 5: a new commit is captured by enumeration — COMMAND TEXT PLAYS NO
# ROLE (calibration wave, queue item 1): any exit-0 Bash observation after the
# commit picks it up from `git log --since=<anchor>`.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-fresh" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "feat: add fresh commit"
sha=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
run_post_bash "commit-fresh" "echo done" > /dev/null
result=$(list_events commit "$LOG")
count=$(count_events commit '' '' "$LOG")
assert_eq "commit_event_count_increments" "2" "$count"
assert_contains "commit_event_has_short_sha" "$result" "$sha"
assert_contains "commit_event_has_subject" "$result" "feat: add fresh commit"

# Test 5b: compound `git add ... && git commit` — trivially captured now (the
# lexical era needed a word-boundary regex for this; enumeration doesn't care).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-compound" \
  "1700000001|commit|abc1234 feat: prior commit")
make_commit "feat: compound form commit"
sha=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
run_post_bash "commit-compound" "git add -A && git commit -m feat-test" > /dev/null
count=$(count_events commit '' '' "$LOG")
assert_eq "compound_commit_event_appended" "2" "$count"
assert_contains "compound_commit_event_sha" "$(list_events commit "$LOG")" "$sha"

# Test 5c: command text mentioning "git commit" with NO actual new commit
# appends nothing — there is no lexical path left to forge through.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-prose" \
  "1700000001|commit|abc1234 feat: prior commit")
run_post_bash "commit-prose" "grep -rn 'git commit' docs/" > /dev/null
assert_eq "commit_mention_without_commit_appends_nothing" "1" \
  "$(count_events commit '' '' "$LOG")"

# Test 5d: multiple commits between observations all land, in CHRONOLOGICAL
# order (git enumerates newest-first; the sensor reverses before appending —
# line order is the authoritative event order).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-multi")
make_commit "feat: first of batch"
sha1=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
make_commit "feat: second of batch"
sha2=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
run_post_bash "commit-multi" "echo observed" > /dev/null
assert_eq "multi_commit_both_captured" "2" "$(count_events commit '' '' "$LOG")"
ordered=$(list_events commit "$LOG" | awk '{print $1}' | tr '\n' ' ')
assert_eq "multi_commit_chronological_order" "${sha1} ${sha2} " "$ordered"

# Test 6: git commit --amend REWRITES the sha — the amended commit is a new
# observation (accepted residual: the orphaned pre-amend sha's event remains;
# the health row's commit count is git-derived, so the ROW stays correct).
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-amend")
make_commit "feat: pre-amend base"
run_post_bash "commit-amend" "echo observe base" > /dev/null
assert_eq "amend_base_observed" "1" "$(count_events commit '' '' "$LOG")"
git -C "$_TEST_TMPDIR" commit -q --amend --allow-empty -m "feat: amended subject"
amended_sha=$(git -C "$_TEST_TMPDIR" rev-parse --short HEAD)
run_post_bash "commit-amend" "echo observe amend" > /dev/null
assert_eq "amended_sha_captured_as_new_observation" "2" \
  "$(count_events commit '' '' "$LOG")"
assert_contains "amended_sha_present" "$(list_events commit "$LOG")" "$amended_sha"

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

# Test 10: a commit whose committer date PRECEDES the session_start anchor is
# outside the session window — not this session's work, never enumerated.
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex/sessions/test-week"
mark_opted_in "$_TEST_TMPDIR/.claude"
LOG="$_TEST_TMPDIR/.claude/cortex/sessions/test-week/commit-stale.events.log"
make_commit "chore: pre-session commit" -1000
printf '%s|session_start|%s test-model\n' "$(date +%s)" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOG"
result=$(run_post_bash "commit-stale" "echo observe")
assert_eq "pre_session_commit_not_enumerated" "0" \
  "$(count_events commit '' '' "$LOG")"
assert_eq "pre_session_commit_no_prompt" "{}" "$result"

# Test 10b: anchor guard — a fallback-sid log carries "unknown" as its
# session_start value; enumeration must be skipped entirely rather than feed
# a non-ISO anchor to `git log --since` (plan-audit finding 1).
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex/sessions/test-week"
mark_opted_in "$_TEST_TMPDIR/.claude"
LOG="$_TEST_TMPDIR/.claude/cortex/sessions/test-week/commit-noanchor.events.log"
printf '1700000000|session_start|unknown unknown\n' > "$LOG"
make_commit "feat: commit with no valid anchor"
result=$(run_post_bash "commit-noanchor" "echo observe")
assert_eq "invalid_anchor_skips_enumeration" "0" \
  "$(count_events commit '' '' "$LOG")"
assert_eq "invalid_anchor_returns_empty" "{}" "$result"

# Test 11: missing event log — no enumeration baseline exists, so the commit
# flow is fully inert: no journal line, no prompt (a session that never
# booted has no session window to attribute commits to).
setup_test
make_commit "docs: no session log test"
result=$(run_post_bash "commit-no-log" "echo observe")
assert_eq "missing_event_log_fully_inert" "{}" "$result"
journal="$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
assert_not_contains "missing_event_log_no_journal_line" \
  "$(cat "$journal")" "no session log test"

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

# The custom pattern is COMMAND-POSITION anchored by the caller (Codex plan
# review I-8): the project configures the command, the anchoring is ours — a
# grep/echo MENTION of the configured pattern must not forge tests_pass.
setup_test
set_config "$_TEST_TMPDIR/.claude" "test_command" "make check"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-custom-grep")
run_post_bash "t-custom-grep" "grep -q 'make check' Makefile" > /dev/null
assert_eq "custom_pattern_grep_mention_silent" "" "$(last_event test_run "$LOG")"

setup_test
set_config "$_TEST_TMPDIR/.claude" "test_command" "make check"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-custom-echo")
run_post_bash "t-custom-echo" "echo make check" > /dev/null
assert_eq "custom_pattern_echo_mention_silent" "" "$(last_event test_run "$LOG")"

setup_test
set_config "$_TEST_TMPDIR/.claude" "test_command" "make check"
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "t-custom-chained")
run_post_bash "t-custom-chained" "cd sub && make check" > /dev/null
assert_eq "custom_pattern_chained_still_fires" "custom" "$(last_event test_run "$LOG")"

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

# --- Commit event dedup by sha (spec §3.3 "HEAD verified changed"): an
# already-observed sha is never re-logged — a duplicate appended after newer
# file_edits would falsely reset Gate 1's edits-since-commit anchor. (The
# race-safe backstop for async double-observation is read-side:
# eio_edits_since_last_commit, tested in test-event-io.sh.) ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-dedup")
make_commit "feat: dedup base"
run_post_bash "commit-dedup" "git commit -m feat-test" > /dev/null
assert_eq "dedup_first_commit_logged" "1" "$(count_events commit '' '' "$LOG")"
run_post_bash "commit-dedup" "echo git commit please" > /dev/null
assert_eq "observed_sha_never_relogged" "1" "$(count_events commit '' '' "$LOG")"
make_commit "feat: dedup second"
run_post_bash "commit-dedup" "git commit -m feat-test-2" > /dev/null
assert_eq "genuinely_new_commit_still_logged" "2" "$(count_events commit '' '' "$LOG")"

# --- Codex review detection (spec §5.6, D7/L9, T6) ---

# Non-prompting CLI probes do not prove a review happened.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-version")
run_post_bash "codex-version" "codex --version" > /dev/null
assert_eq "codex_version_no_review_event" "0" "$(count_events codex_review '' '' "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-help")
run_post_bash "codex-help" "codex --help" > /dev/null
assert_eq "codex_help_no_review_event" "0" "$(count_events codex_review '' '' "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-bare")
run_post_bash "codex-bare" "codex" > /dev/null
assert_eq "bare_codex_no_review_event" "0" "$(count_events codex_review '' '' "$LOG")"

# Command text that merely mentions an invocation is not itself an invocation.
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "codex-echo-mention")
run_post_bash "codex-echo-mention" "echo codex exec review" > /dev/null
assert_eq "echo_codex_exec_no_review_event" "0" "$(count_events codex_review '' '' "$LOG")"

setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "companion-echo-mention")
run_post_bash "companion-echo-mention" "echo node C:/tools/codex-companion.mjs result task-42" > /dev/null
assert_eq "echo_companion_no_review_event" "0" "$(count_events codex_review '' '' "$LOG")"

# Prompt-bearing `codex exec` invocation → codex_review event, value "cli"
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

# --- Sandbox tolerance: a READ-ONLY journal must not crash the hook on a
# commit command (cortex hooks fire inside Codex sandboxes; contract: exit 0
# with valid JSON even when document writes are denied) ---
setup_test
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "commit-rojournal")
make_commit "feat: readonly journal test"
mkdir -p "$_TEST_TMPDIR/memory"
journal="$_TEST_TMPDIR/memory/$(date +%Y-%m-%d).md"
echo "# Journal" > "$journal"
chmod 444 "$journal" 2>/dev/null || true
json=$(mock_json "session_id=commit-rojournal" "tool_input.command=git commit -m test")
set +e
result=$(echo "$json" | CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR" \
  bash "$PLUGIN_ROOT/hooks/scripts/post-bash-dispatch.sh" 2>/dev/null)
rc=$?
set -e
chmod 644 "$journal" 2>/dev/null || true
assert_eq "readonly_journal_exit_0" "0" "$rc"
assert_contains "readonly_journal_still_valid_json" "$result" "{"

end_suite
