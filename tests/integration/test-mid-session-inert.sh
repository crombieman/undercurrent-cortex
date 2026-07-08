#!/usr/bin/env bash
set -euo pipefail
# Mid-session opt-in inertness (Codex I-1/I-3). An OPTED project (sentinel
# present) whose CURRENT session has NO event log yet — the mid-session
# activation window — must stay fully inert: routing a Write through
# post-dispatch.sh --native, or invoking the routed sub-handlers directly,
# must NOT trigger lib/state-io.sh's source-time migrate_state_files() side
# effects (mkdir sessions/, write .migrated-v3.7).
#
# Pre-fix RED: pattern-template.sh / plan-file-guard.sh / migration-linter.sh /
# apply-proposal.sh each `source lib/state-io.sh`, whose UNGUARDED source-time
# migrate_state_files() call runs Phase 2 (mkdir + .migrated-v3.7 sentinel) the
# instant they're sourced in an opted, not-yet-migrated project. Post-fix they
# source lib/event-io.sh (side-effect-free) or nothing from that pair.
#
# CI="" is forced on every invocation so migrate_state_files()'s
# `[ "${CI:-}" = "true" ] && return 0` early-out never masks the leak — keeping
# this a genuine RED-before / GREEN-after regardless of the runner's CI env
# (GitHub Actions sets CI=true, which would otherwise make the pre-fix leak
# invisible on CI).
#
# Scripts run DIRECTLY against the real plugin (not setup_script_sandbox, which
# sed-disables migration in its patched state-io.sh copy and so structurally
# cannot observe this leak).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_ROOT/hooks/scripts"

begin_suite "mid-session-inert"

MOCK_BIN="$_TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
create_mock_git "$MOCK_BIN" "clean"
create_mock_gh "$MOCK_BIN" "success"

# assert_tree_unchanged <label> <before> <after>
assert_tree_unchanged() {
  local label="$1" before="$2" after="$3"
  if [ "$before" = "$after" ]; then
    printf "    ${_GREEN}PASS${_RESET}  %s\n" "$label"
    _PASS_COUNT=$((_PASS_COUNT + 1))
  else
    printf "    ${_RED}FAIL${_RESET}  %s\n" "$label"
    printf "          .claude tree changed:\n"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null | sed 's/^/          /' || true
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
}

# make_opted_no_log <proj> — opted project (sentinel present, cortex/ exists)
# with NO session event log and NO .migrated-v3.7 sentinel. Exactly the
# mid-session activation window: the gate passes, but this session's log was
# never created (session-start is the sole creator, and it didn't run for this
# session).
make_opted_no_log() {
  local proj="$1"
  mkdir -p "$proj/.claude/cortex"
  mark_opted_in "$proj/.claude"   # writes .claude/cortex/enabled
}

no_migration_sentinel() {
  [ -f "$1/.claude/cortex/.migrated-v3.7" ] && echo yes || echo no
}
no_sessions_dir() {
  [ -d "$1/.claude/cortex/sessions" ] && echo yes || echo no
}

# ============================================================================
# 1. post-dispatch.sh --native, Write payload, opted + NO event log. Routes to
#    post-edit-dispatch.sh (no log => {}) + pattern-template.sh. Pre-fix,
#    pattern-template sourcing state-io.sh migrates => sessions/ + .migrated-v3.7
#    leak. Post-fix: zero writes.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-post-native"
make_opted_no_log "$PROJ"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "tool_name=Write" "session_id=msi-post" "tool_input.file_path=${PROJ}/src/new.ts")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" CI="" bash "$SCRIPTS/post-dispatch.sh" --native 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "post_native_exit_0" "0" "$rc"
assert_json_valid "post_native_valid_json" "$result"
assert_tree_unchanged "post_native_tree_byte_identical" "$before" "$after"
assert_eq "post_native_no_migration_sentinel" "no" "$(no_migration_sentinel "$PROJ")"
assert_eq "post_native_no_sessions_dir" "no" "$(no_sessions_dir "$PROJ")"

# ============================================================================
# 2. pattern-template.sh direct — Write file_path, no exemplars dir => {} and
#    zero writes.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-pt"
make_opted_no_log "$PROJ"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "tool_input.file_path=${PROJ}/src/foo.ts")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" CI="" bash "$SCRIPTS/pattern-template.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "pattern_template_exit_0" "0" "$rc"
assert_tree_unchanged "pattern_template_no_writes" "$before" "$after"
assert_eq "pattern_template_no_migration_sentinel" "no" "$(no_migration_sentinel "$PROJ")"

# ============================================================================
# 3. plan-file-guard.sh direct — non-plan file_path => {} and zero writes.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-pfg"
make_opted_no_log "$PROJ"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "tool_input.file_path=${PROJ}/src/foo.ts")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" CI="" bash "$SCRIPTS/plan-file-guard.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "plan_file_guard_exit_0" "0" "$rc"
assert_tree_unchanged "plan_file_guard_no_writes" "$before" "$after"
assert_eq "plan_file_guard_no_migration_sentinel" "no" "$(no_migration_sentinel "$PROJ")"

# ============================================================================
# 4. migration-linter.sh direct — non-migration file_path => {} and zero writes.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-ml"
make_opted_no_log "$PROJ"
before=$(find "$PROJ/.claude" | sort)
json=$(mock_json "tool_input.file_path=${PROJ}/src/foo.ts" "tool_input.content=const x = 1;")
set +e
result=$(printf '%s' "$json" | CORTEX_PROJECT_DIR="$PROJ" CI="" bash "$SCRIPTS/migration-linter.sh" 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "migration_linter_exit_0" "0" "$rc"
assert_tree_unchanged "migration_linter_no_writes" "$before" "$after"
assert_eq "migration_linter_no_migration_sentinel" "no" "$(no_migration_sentinel "$PROJ")"

# ============================================================================
# 5. apply-proposal.sh direct — no proposals file => "No proposals file." plain
#    text, exit 0, zero writes.
# ============================================================================
setup_test
PROJ="$_TEST_TMPDIR/proj-ap"
make_opted_no_log "$PROJ"
before=$(find "$PROJ/.claude" | sort)
set +e
result=$(CORTEX_PROJECT_DIR="$PROJ" CI="" bash "$SCRIPTS/apply-proposal.sh" approve 2>/dev/null)
rc=$?
set -e
after=$(find "$PROJ/.claude" | sort)
assert_eq "apply_proposal_exit_0" "0" "$rc"
assert_tree_unchanged "apply_proposal_no_writes" "$before" "$after"
assert_eq "apply_proposal_no_migration_sentinel" "no" "$(no_migration_sentinel "$PROJ")"

export PATH="$SAVED_PATH"
end_suite
