#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

begin_suite "migration-v37"

# This test sources the real state-io.sh (not sandbox) to test migration.
# Unset CI so the CI guard in migrate_state_files doesn't skip migration.
unset CI 2>/dev/null || true
# Reset the sentinel so migration runs on each source
unset _CORTEX_STATE_IO_MIGRATED 2>/dev/null || true

# Test 1: Flat session files migrate to weekly buckets
setup_test
# Create flat cortex-state-* files in .claude/ (pre-v3.7 layout)
mkdir -p "$_TEST_TMPDIR/.claude"
cat > "$_TEST_TMPDIR/.claude/cortex-state-abc123.local.md" << 'EOF'
session_id=abc123
session_start=2026-03-15T00:00:00Z
model_name=test
commits_count=0
edits_since_last_commit=0
tool_calls_count=0
tests_run=false
docs_updated=false
carry_over_addressed=false
stop_hook_active=false
consecutive_blocks=0
health_written=false

[files_modified]

[carry_over]

[activity_log]
EOF

cat > "$_TEST_TMPDIR/.claude/cortex-state-def456.local.md" << 'EOF'
session_id=def456
session_start=2026-03-16T00:00:00Z
model_name=test
commits_count=0
edits_since_last_commit=0
tool_calls_count=0
tests_run=false
docs_updated=false
carry_over_addressed=false
stop_hook_active=false
consecutive_blocks=0
health_written=false

[files_modified]

[carry_over]

[activity_log]
EOF

# Create flat singleton files
echo "# Cortex Health Log" > "$_TEST_TMPDIR/.claude/cortex-health.local.md"
echo "# Proposals" > "$_TEST_TMPDIR/.claude/cortex-proposals.local.md"
echo "# Decisions" > "$_TEST_TMPDIR/.claude/cortex-decisions.local.md"
echo "# Cross-Session" > "$_TEST_TMPDIR/.claude/cortex-cross-session.local.md"
echo "strict" > "$_TEST_TMPDIR/.claude/cortex-profile.local"

# Run migration by sourcing state-io.sh
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"
source "$TESTS_DIR/../hooks/scripts/lib/state-io.sh" 2>/dev/null || true

# Assert: cortex/ directory exists
assert_eq "cortex_dir_created" "yes" "$([ -d "$_TEST_TMPDIR/.claude/cortex" ] && echo yes || echo no)"
assert_eq "sessions_dir_created" "yes" "$([ -d "$_TEST_TMPDIR/.claude/cortex/sessions" ] && echo yes || echo no)"

# Assert: singletons moved to cortex/
assert_file_exists "health_migrated" "$_TEST_TMPDIR/.claude/cortex/health.local.md"
assert_file_exists "proposals_migrated" "$_TEST_TMPDIR/.claude/cortex/proposals.local.md"
assert_file_exists "decisions_migrated" "$_TEST_TMPDIR/.claude/cortex/decisions.local.md"
assert_file_exists "cross_session_migrated" "$_TEST_TMPDIR/.claude/cortex/cross-session.local.md"
assert_file_exists "profile_migrated" "$_TEST_TMPDIR/.claude/cortex/profile.local"

# Assert: flat singletons removed
assert_eq "health_flat_removed" "no" "$([ -f "$_TEST_TMPDIR/.claude/cortex-health.local.md" ] && echo yes || echo no)"
assert_eq "proposals_flat_removed" "no" "$([ -f "$_TEST_TMPDIR/.claude/cortex-proposals.local.md" ] && echo yes || echo no)"
assert_eq "decisions_flat_removed" "no" "$([ -f "$_TEST_TMPDIR/.claude/cortex-decisions.local.md" ] && echo yes || echo no)"

# Assert: session files moved into weekly buckets (exact week depends on mtime)
# Just check they're gone from flat and exist somewhere in sessions/
assert_eq "session_abc_flat_removed" "no" "$([ -f "$_TEST_TMPDIR/.claude/cortex-state-abc123.local.md" ] && echo yes || echo no)"
assert_eq "session_def_flat_removed" "no" "$([ -f "$_TEST_TMPDIR/.claude/cortex-state-def456.local.md" ] && echo yes || echo no)"
# At least 2 session files should exist in sessions/
session_count=$(find "$_TEST_TMPDIR/.claude/cortex/sessions" -name "*.local.md" 2>/dev/null | wc -l | tr -d ' ')
result=$([ "$session_count" -ge 2 ] && echo "yes" || echo "no")
assert_eq "sessions_migrated_count" "yes" "$result"

# Assert: sentinel file exists
assert_file_exists "sentinel_written" "$_TEST_TMPDIR/.claude/cortex/.migrated-v3.7"

# Test 2: Sentinel prevents re-migration
setup_test
# Create a fresh flat file AFTER migration
mkdir -p "$_TEST_TMPDIR/.claude"
echo "# Should stay" > "$_TEST_TMPDIR/.claude/cortex-state-should-stay.local.md"
# Ensure sentinel exists
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
echo "migrated 2026-03-17T00:00:00" > "$_TEST_TMPDIR/.claude/cortex/.migrated-v3.7"
# Re-source state-io.sh — migration should be skipped (by .migrated-v3.7 sentinel)
unset _CORTEX_STATE_IO_MIGRATED 2>/dev/null || true
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"
source "$TESTS_DIR/../hooks/scripts/lib/state-io.sh" 2>/dev/null || true
# The flat file should still be there (not migrated)
assert_file_exists "sentinel_prevents_remigration" "$_TEST_TMPDIR/.claude/cortex-state-should-stay.local.md"

# Test 3: get_profile reads from cortex/profile.local
setup_test
unset _CORTEX_STATE_IO_MIGRATED 2>/dev/null || true
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"
mkdir -p "$_TEST_TMPDIR/.claude/cortex"
echo "migrated" > "$_TEST_TMPDIR/.claude/cortex/.migrated-v3.7"
source "$TESTS_DIR/../hooks/scripts/lib/state-io.sh" 2>/dev/null || true
unset CORTEX_PROFILE 2>/dev/null || true
echo "minimal" > "$_TEST_TMPDIR/.claude/cortex/profile.local"
result=$(get_profile)
assert_eq "profile_from_cortex_dir" "minimal" "$result"

end_suite
