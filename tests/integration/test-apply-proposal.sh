#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

begin_suite "apply-proposal"

# Create sandbox once for the suite
SANDBOX=$(setup_script_sandbox "$_TEST_TMPDIR")

# setup_script_sandbox exports CORTEX_PROJECT_DIR internally, but that export
# runs inside the $(...) subshell above and never reaches this shell. apply-
# proposal.sh now derives PROPOSALS_FILE via event-io.sh's eio_proposals_file
# (which resolves from CORTEX_PROJECT_DIR), so it must be set here explicitly —
# same pattern as tests/integration/test-post-dispatch.sh. This lands the
# resolved PROPOSALS_FILE at $_TEST_TMPDIR/.claude/cortex/proposals.local.md,
# exactly where create_proposals_file writes below.
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

# Helper: run apply-proposal with given action
run_apply_proposal() {
  local action="${1:-approve}"
  bash "$SANDBOX/hooks/scripts/apply-proposal.sh" "$action" 2>/dev/null || true
}

# Test 1: Approve lesson proposal (appends body to target file)
setup_test
target_file="$_TEST_TMPDIR/tasks/lessons.md"
echo "# Lessons" > "$target_file"
create_proposals_file "$_TEST_TMPDIR/.claude/cortex/proposals.local.md" \
  "prop-001|pending|lesson|${target_file}|New lesson about pipefail|Always use || true after ls glob"
result=$(run_apply_proposal "approve")
assert_contains "approve_appends_to_target" "$result" "Applied proposal prop-001"
assert_file_contains "approve_body_in_target" "$target_file" "Always use || true after ls glob"

# Test 2: Reject proposal (status changes to rejected)
setup_test
target_file="$_TEST_TMPDIR/tasks/lessons.md"
echo "# Lessons" > "$target_file"
create_proposals_file "$_TEST_TMPDIR/.claude/cortex/proposals.local.md" \
  "prop-002|pending|lesson|${target_file}|Rejected lesson|This should not appear"
result=$(run_apply_proposal "reject")
assert_contains "reject_proposal_message" "$result" "Rejected proposal"
assert_file_contains "reject_status_changed" "$_TEST_TMPDIR/.claude/cortex/proposals.local.md" "status=rejected"

# Test 3: Empty proposals file (no pending proposals)
setup_test
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
> "$_TEST_TMPDIR/.claude/cortex/proposals.local.md"
result=$(run_apply_proposal "approve")
assert_contains "empty_proposals_file" "$result" "No pending proposals"

# Test 4: Approve sets applied_date
setup_test
target_file="$_TEST_TMPDIR/tasks/lessons.md"
echo "# Lessons" > "$target_file"
create_proposals_file "$_TEST_TMPDIR/.claude/cortex/proposals.local.md" \
  "prop-003|pending|lesson|${target_file}|Dated lesson|Lesson with date tracking"
run_apply_proposal "approve" > /dev/null
assert_file_contains "approve_sets_date" "$_TEST_TMPDIR/.claude/cortex/proposals.local.md" "applied_date="

# Test 5: No pending proposals message when all are already applied
setup_test
target_file="$_TEST_TMPDIR/tasks/lessons.md"
echo "# Lessons" > "$target_file"
create_proposals_file "$_TEST_TMPDIR/.claude/cortex/proposals.local.md" \
  "prop-004|applied|lesson|${target_file}|Already done|Already applied content"
result=$(run_apply_proposal "approve")
assert_contains "no_pending_proposals_message" "$result" "No pending proposals"

end_suite
