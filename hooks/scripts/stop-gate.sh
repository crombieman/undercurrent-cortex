#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/event-io.sh"    || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh" || { printf '{}'; exit 0; }

# --native flag (Task 5: native hooks.json registration): consumed before any
# other arg handling. Its ABSENCE plus the native-hooks.ok marker (written
# every session by session-start once its opt-in gate passes) means this
# invocation is the stale ~/.claude/settings.json bootstrap-hooks.sh entry
# firing alongside the native hooks.json registration — see the
# native-suppression check below.
NATIVE=false
[ "${1:-}" = "--native" ] && { NATIVE=true; shift; }

# Buffer stdin ONCE (C1 fix — extract_json_field uses cat internally)
INPUT=$(cat)

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup or session-start's grandfathering check.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

# Native dual-fire suppression (spec §4.2, hardened Codex I-2): suppress ONLY
# when the native-hooks.ok marker's 3rd token (session_id, written by
# session-start THIS session) equals THIS payload's session_id — proof native
# registration is demonstrably alive for this very session. A marker with a
# mismatched or missing 3rd token (downgrade, legacy 2-token marker), or a
# payload carrying no session_id, does NOT suppress (compat: proceed normally).
# Presence alone is insufficient — it can outlive an active native registration.
if [ "$NATIVE" != true ]; then
  _marker="$(_eio_cortex_dir)/native-hooks.ok"
  if [ -f "$_marker" ]; then
    _marker_sid=$(awk 'NR==1{print $3}' "$_marker" 2>/dev/null | tr -d '[:space:]' || true)
    _payload_sid=$(_eio_extract_sid "$INPUT")
    if [ -n "$_payload_sid" ] && [ "$_marker_sid" = "$_payload_sid" ]; then
      printf '{}'
      exit 0
    fi
  fi
fi

# Resolve session-scoped event log from session_id in hook JSON
resolve_event_log "$INPUT"

# Debug: trace event log resolution for forensic analysis
[ "${CORTEX_DEBUG:-}" = "true" ] && echo "stop-gate: resolved EVENT_LOG=$(basename "${EVENT_LOG:-}" 2>/dev/null)" >&2

# No event log → nothing to gate. A session without a log has no recorded
# obligations (no legacy state-file fallback in v4 — the log IS the state).
if [ -z "$EVENT_LOG" ] || [ ! -f "$EVENT_LOG" ]; then
  printf '{}'
  exit 0
fi

PROJECT_DIR="$(eio_project_dir)"

# --- ESCAPE HATCH: consecutive stop_blocked events since the last approve/force ---
consecutive=$(count_events stop_blocked '' 'stop_approved|stop_forced')
[ "${CORTEX_DEBUG:-}" = "true" ] && echo "stop-gate: consecutive_blocks=${consecutive}" >&2

if [ "$consecutive" -ge 2 ]; then
  append_event "stop_forced" "true"
  msg=$(escape_for_json "Stop gate: force-approved after acknowledgment. Some obligations may be unmet.")
  printf '{"systemMessage":"%s"}' "$msg"
  exit 0
fi

# --- GATE CHECKS ---
failures=""
blocked_gates=""
reminders=""

# add_failure <gate_name> <reason_line> — accumulates both the human-readable
# reason text (for the block JSON) and the short gate-name list (for the
# stop_blocked event value, spec: comma-separated gate names).
add_failure() {
  failures="${failures}- ${2}\n"
  blocked_gates="${blocked_gates:+${blocked_gates},}${1}"
}

# add_reminder <gate_name> <reason_line> — parallel accumulator for demoted
# gates (locked D5: Gates 2/6/7 verify nothing block-worthy — docs/root-cause/
# decisions capture can't be checked for correctness, only touched — so they
# ride the approve path as a non-blocking systemMessage instead of
# decision:block). Text is the gate's OLD reason line verbatim, no "Reminder:"
# prefix or other block framing. <gate_name> is accepted for call-signature
# symmetry with add_failure but isn't otherwise tracked — reminders never
# feed the stop_blocked event value (blocked_gates stays failure-only).
add_reminder() {
  reminders="${reminders}- ${2}\n"
}

# Gate 1: Uncommitted changes
edits=$(count_events file_edit r commit)
edits="${edits:-0}"
if [ "$edits" -gt 0 ]; then
  # Belt-and-suspenders: verify with git status (catches gitignored,
  # already-committed, or otherwise stale-looking counts).
  if git -C "${PROJECT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    # grep -v exits 1 when nothing is filtered out (i.e. repo is clean) — under
    # pipefail that would kill the pipeline before wc/tr run; `|| true` on the
    # whole pipe keeps the captured stdout while swallowing that exit code
    # (pipe-safety idiom, see CLAUDE.md "ls glob | head -1 || true").
    actual_changes=$(git -C "${PROJECT_DIR}" status --porcelain 2>/dev/null | grep -vE '^\?\?' | wc -l | tr -d ' ' || true)
    actual_changes="${actual_changes:-0}"
    if [ "$actual_changes" -eq 0 ]; then
      edits=0
    fi
  fi

  if [ "$edits" -gt 0 ]; then
    add_failure "uncommitted" "Uncommitted changes (${edits} edits since last commit)"
  fi
fi

# Gates 2 & 3 only fire when many files modified (avoid nagging on quick fixes)
files_modified=$(list_events file_edit | sed 's/^[rx] //' | sort -u)
file_count=0
if [ -n "$files_modified" ]; then
  file_count=$(echo "$files_modified" | wc -l | tr -d ' ')
fi

if [ "$file_count" -gt 3 ]; then

  # Gate 2: <docs_file> not updated after architectural changes. Per-project
  # config (spec §7.1) — architectural_patterns has NO default, so an
  # unconfigured project leaves this gate fully inactive (keeps
  # Undercurrent-specific vocabulary out of the public plugin).
  docs_edit_count=$(count_events docs_edit)
  if [ "$docs_edit_count" -eq 0 ]; then
    arch_patterns=$(eio_config_get architectural_patterns)
    if [ -n "$arch_patterns" ] && echo "$files_modified" | grep -qiE "$arch_patterns"; then
      docs_file=$(eio_config_get docs_file "documentation.md")
      add_reminder "docs" "${docs_file} not updated after architectural changes"
    fi
  fi

  # Gate 3: Tests not run after modifying source files (language-neutral,
  # locked D5: verified-blocking when a test ecosystem is detectable this
  # session, else demotes to reminder — replaces the old TypeScript-only
  # `.ts`/`.tsx` regex, which falsely implied test-running was a TS-specific
  # obligation). Detection order: (b) an edited path already looks like a
  # test file, (c) a project language/test marker file exists at the project
  # root, (d) a per-project test_command override is configured. The
  # >3-unique-files threshold above is the noise guard; this check itself
  # stays a plain whole-session `count_events test_run` (no after-anchor).
  tests_run_count=$(count_events test_run)
  if [ "$tests_run_count" -eq 0 ]; then
    ecosystem_detected=false
    if echo "$files_modified" | grep -qiE '\.(test|spec)\.(ts|tsx|js|jsx)$|__tests__/|_test\.(go|py|rs)$|test_.*\.py$'; then
      ecosystem_detected=true
    elif [ -f "${PROJECT_DIR}/package.json" ] || [ -f "${PROJECT_DIR}/go.mod" ] \
         || [ -f "${PROJECT_DIR}/Cargo.toml" ] || [ -f "${PROJECT_DIR}/pyproject.toml" ] \
         || [ -f "${PROJECT_DIR}/setup.py" ]; then
      ecosystem_detected=true
    elif [ -n "$(eio_config_get test_command)" ]; then
      ecosystem_detected=true
    fi

    if [ "$ecosystem_detected" = true ]; then
      add_failure "tests" "Tests not run after modifying source files"
    else
      add_reminder "tests" "Tests not run after modifying source files"
    fi
  fi
fi

# Gate 4: Carry-over items not addressed. Epoch-ordered reconciliation (spec §3.5
# amendment) via the shared eio_unresolved_items helper — the single source of
# truth shared with pre-compact and session-start. An item is unresolved iff its
# latest carry_over epoch strictly exceeds its latest carry_addressed epoch
# (re-raising identical text after addressing resurrects it).
if [ -n "$(eio_unresolved_items "$EVENT_LOG")" ]; then
  add_failure "carry_over" "Carry-over items from prior session not addressed"
fi

# Gate 5: Stale carry-over (3+ sessions unresolved) — written once by
# session-start at boot; stop-gate only reads it (keeps the hot Stop path
# free of a cross-session log scan).
carry_over_age=$(last_event carry_over_age)
carry_over_age="${carry_over_age:-0}"
if [ "$carry_over_age" -ge 3 ]; then
  add_failure "stale_carry_over" "Stale carry-over: items unresolved for ${carry_over_age} sessions. Address or explicitly discard."
fi

# Gate 7: Decisions captured after plan-mode session
plan_mode_used_count=$(count_events plan_mode)
decisions_logged_count=$(count_events decision_logged)
commits_for_g7=$(count_events commit)
if [ "$plan_mode_used_count" -gt 0 ] && [ "$commits_for_g7" -gt 0 ] && [ "$decisions_logged_count" -eq 0 ]; then
  add_reminder "decisions" "Decisions not captured: plan-audit Gate 17 not run this session. Log decisions to .claude/cortex/decisions.local.md before stopping."
fi

# Gate 6: Root cause documentation for fix: commits
commits_count_g6=$(count_events commit)
if [ "$commits_count_g6" -gt 0 ]; then
  session_start_g6=$(last_event session_start)
  session_start_ts="${session_start_g6%% *}"
  has_fix_commit=false
  if [ -n "$session_start_ts" ] && git -C "${PROJECT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    fix_commits=$(git -C "${PROJECT_DIR}" log --format=%s --since="${session_start_ts}" --grep="^fix:" 2>/dev/null || true)
    if [ -n "$fix_commits" ]; then
      has_fix_commit=true
    fi
  fi
  if [ "$has_fix_commit" = true ]; then
    root_cause_documented=$(count_events root_cause_logged)
    if [ "$root_cause_documented" -eq 0 ]; then
      profile=$(eio_get_profile)
      case "$profile" in
        minimal) ;; # no enforcement
        *)
          lessons_file=$(eio_config_get lessons_file "tasks/lessons.md")
          add_reminder "root_cause" "Root cause not documented after fix: commit. Update ${lessons_file} with pattern + prevention rule."
          ;;
      esac
    fi
  fi
fi

# --- DECISION ---
if [ -n "$failures" ]; then
  append_event "stop_blocked" "$blocked_gates"
  [ "${CORTEX_DEBUG:-}" = "true" ] && echo "stop-gate: BLOCKED — gates: ${blocked_gates}" >&2

  reason_text="Stop blocked. Address obligations above, then stop again to override.\nUnmet gates:\n${failures}"
  if [ -n "$reminders" ]; then
    reason_text="${reason_text}\nReminders (non-blocking):\n${reminders}"
  fi
  reason=$(escape_for_json "$reason_text")
  printf '{"decision":"block","reason":"%s"}' "$reason"
  exit 0
fi

# All blocking gates pass → approve. Reminders (if any) ride along as a
# non-blocking systemMessage — spec locked D5: demoted gates never emit
# decision:block, even alone.
append_event "stop_approved" "true"
if [ -n "$reminders" ]; then
  msg=$(escape_for_json "Reminders: ${reminders}")
  printf '{"systemMessage":"%s"}' "$msg"
else
  printf '{}'
fi
exit 0
