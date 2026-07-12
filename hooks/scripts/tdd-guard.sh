#!/usr/bin/env bash
set -euo pipefail
# TDD guard — PreToolUse handler for Write/Edit on production code.
# Warns (standard) or denies (strict) edits to src/ files when no test file
# has been created/edited this session. Called from pre-dispatch.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"     || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh"  || { printf '{}'; exit 0; }

# Buffer stdin ONCE
INPUT=$(cat)

# Resolve session-scoped event log
resolve_event_log "$INPUT"
[ -n "$EVENT_LOG" ] && [ -f "$EVENT_LOG" ] || { printf '{}'; exit 0; }

# Extract file path from tool input
file_path=$(printf '%s' "$INPUT" | extract_json_field "tool_input.file_path")
[ -z "$file_path" ] && { printf '{}'; exit 0; }

# Normalize for Windows path consistency
file_path=$(normalize_path "$file_path")

# Skip: test files themselves (never block writing tests)
if echo "$file_path" | grep -qiE '\.(test|spec)\.(ts|tsx|js|jsx)$|__tests__/'; then
  printf '{}'
  exit 0
fi

# Skip: not in src/ (non-production code)
if ! echo "$file_path" | grep -qiE '/src/'; then
  printf '{}'
  exit 0
fi

# Skip: type definitions
if echo "$file_path" | grep -qiE '\.d\.ts$'; then
  printf '{}'
  exit 0
fi

# Check if any test file was created/edited this session — derived from
# file_edit events (no dedicated counter in the event log; spec §3). Guarded
# under errexit since grep -q's non-match is expected control flow, not a failure.
test_files=""
if list_events file_edit | sed 's/^[rx] //' | grep -qiE '\.(test|spec)\.(ts|tsx|js|jsx)$|__tests__/'; then
  test_files="yes"
fi
if [ -n "$test_files" ]; then
  # Test file exists — TDD discipline satisfied
  printf '{}'
  exit 0
fi

# No test files this session — LAB-only reminder (T6 emitter census: the
# advisory TDD nudge is treatment; "strict"'s deny retired with the profile
# name — the plugin's protection tier is the blocking gates, not TDD
# enforcement). Locked D5 rationale stands: test-writing can't be verified
# for correctness, only for existence, so this never blocks.
case "$(eio_get_profile)" in
  core)
    printf '{}'
    ;;
  *)
    # lab — once-per-session reminder: fires only when the
    # log has ZERO prior /src/ production file_edit events (i.e. THIS edit
    # is the session's first). pre-dispatch runs before post-edit-dispatch
    # appends the current edit's own event, so the log at check time reflects
    # only prior edits. Errexit-safe grep -q under a plain if.
    prior_src_edits=""
    if list_events file_edit | sed 's/^[rx] //' | grep -qiE '/src/'; then
      prior_src_edits="yes"
    fi
    if [ -z "$prior_src_edits" ]; then
      msg=$(escape_for_json "TDD guard: editing production code without a test file this session. Consider writing a failing test first (RED phase).")
      printf '{"systemMessage":"%s"}' "$msg"
    else
      printf '{}'
    fi
    ;;
esac
exit 0
