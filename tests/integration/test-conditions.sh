#!/usr/bin/env bash
set -euo pipefail

# Core/Lab experimental conditions (calibration wave T6, queue item 9; Codex
# plan-review C-1). The load-bearing claim: a CORE session emits ZERO
# adaptive output — no intervention events, no advisory systemMessages, no
# synthesis instructions — while recording, carry-over, and blocking gates
# run identically in both conditions. Without this, the experiment's control
# arm was never a control (the minimal-profile finding, synthesis limitation 9).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "conditions"

export CORTEX_PROJECT_DIR_OVERRIDE="$_TEST_TMPDIR"
export CORTEX_PROJECT_DIR="$_TEST_TMPDIR"

set_condition() { export CORTEX_PROFILE="$1"; }

run_hook() {
  local script="$1" json="$2"
  echo "$json" | bash "$PLUGIN_ROOT/hooks/scripts/${script}" 2>/dev/null || true
}

# =============================================================
# 1. Boot content: core vs lab pulse + provenance stamp
# =============================================================
setup_test
mark_opted_in "$_TEST_TMPDIR/.claude"
set_condition core
result=$(echo "$(mock_json "session_id=cond-core")" \
  | CORTEX_PROJECT_DIR="$_TEST_TMPDIR" HOME="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null) || true
LOG="$(_eio_week_dir)/cond-core.events.log"
assert_contains "core_pulse_declares_condition" "$result" "Condition: core"
assert_not_contains "core_pulse_no_collab_instruction" "$result" "collaboration.md"
assert_not_contains "core_pulse_no_synthesis_block" "$result" "REQUIRED: Synthesis Tasks"
assert_contains "core_boot_still_injects_sid" "$result" "Session id: cond-core"
prov=$(list_events provenance "$LOG")
assert_contains "core_provenance_condition" "$prov" "condition=core"
assert_contains "core_provenance_repo" "$prov" "repo="
assert_eq "core_mode_always_normal" "normal boot" "$(last_event mode_set "$LOG")"

setup_test
mark_opted_in "$_TEST_TMPDIR/.claude"
set_condition lab
# A collaboration file must exist for the lab synthesis directive to render.
mkdir -p "$_TEST_TMPDIR/.cortex/synthesis"
printf '# Collaboration Patterns\n' > "$_TEST_TMPDIR/.cortex/synthesis/collaboration.md"
result=$(echo "$(mock_json "session_id=cond-lab")" \
  | CORTEX_PROJECT_DIR="$_TEST_TMPDIR" HOME="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null) || true
LOG="$(_eio_week_dir)/cond-lab.events.log"
assert_contains "lab_pulse_declares_condition" "$result" "Condition: lab"
assert_contains "lab_pulse_has_collab_instruction" "$result" "collaboration.md"
assert_contains "lab_pulse_has_synthesis_block" "$result" "REQUIRED: Synthesis Tasks"
assert_contains "lab_provenance_condition" "$(list_events provenance "$LOG")" "condition=lab"

# Provenance is stamped ONCE — a resumed boot (same sid, log exists) must not
# duplicate it (no-clobber keeps prior events; the stamp rides creation only).
result=$(echo "$(mock_json "session_id=cond-lab")" \
  | CORTEX_PROJECT_DIR="$_TEST_TMPDIR" HOME="$_TEST_TMPDIR" \
    bash "$PLUGIN_ROOT/hooks/session-start" 2>/dev/null) || true
assert_eq "provenance_once_per_log" "1" "$(count_events provenance '' '' "$LOG")"

# =============================================================
# 2. ZERO-INTERVENTION CORE SESSION: drive every adaptive emitter's trigger
# condition under core — no intervention events, no advisory systemMessages.
# =============================================================
setup_test
set_condition core
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cond-quiet")

# (a) re-edit warning trigger: 3+ edits of the same path
for i in 1 2 3; do
  seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/hot.ts"
done
out=$(run_hook post-edit-dispatch.sh \
  "$(mock_json "session_id=cond-quiet" "tool_input.file_path=${_TEST_TMPDIR}/src/lib/hot.ts")")
assert_eq "core_re_edit_warning_silent" "{}" "$out"

# (b) commit nudge trigger: >15 r-edits since last commit
for i in $(seq 1 20); do
  seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/f${i}.ts"
done
out=$(run_hook post-edit-dispatch.sh \
  "$(mock_json "session_id=cond-quiet" "tool_input.file_path=${_TEST_TMPDIR}/src/lib/f1.ts")")
assert_eq "core_commit_nudge_silent" "{}" "$out"

# (c) journal checkpoint trigger: tool_call count at the modulo-25 boundary
for i in $(seq 1 24); do
  printf '%s|tool_call|Bash\n' "$(date +%s)" >> "$LOG"
done
out=$(run_hook post-dispatch.sh \
  "$(mock_json "tool_name=Read" "session_id=cond-quiet")")
assert_not_contains "core_checkpoint_silent" "$out" "checkpoint"

# (d) tdd-guard trigger: first /src/ production edit, no test files
out=$(echo "$(mock_json "tool_name=Edit" "session_id=cond-quiet" "tool_input.file_path=${_TEST_TMPDIR}/src/lib/prod.ts")" \
  | bash "$PLUGIN_ROOT/hooks/scripts/tdd-guard.sh" 2>/dev/null) || true
assert_eq "core_tdd_reminder_silent" "{}" "$out"

# (e) context-flow: keyword prompt fully inert under core
out=$(run_hook context-flow.sh \
  "$(mock_json "session_id=cond-quiet" "prompt=help me with pyproject.toml packaging")")
assert_eq "core_context_flow_inert" "{}" "$out"

# (f) THE CENSUS ASSERTION: after all of the above, the log holds ZERO
# intervention events of ANY kind.
assert_eq "core_session_zero_intervention_events" "0" \
  "$(count_events intervention '' '' "$LOG")"

# (g) ...while RECORDING kept working the whole time.
recorded_edits=$(count_events file_edit '' '' "$LOG")
if [ "$recorded_edits" -ge 24 ]; then
  assert_eq "core_recording_unaffected" "ok" "ok"
else
  assert_eq "core_recording_unaffected" "ok" "only ${recorded_edits} file_edit events"
fi

# =============================================================
# 3. Blocking gates keep their teeth under core; reminders vanish
# =============================================================
setup_test
set_condition core
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cond-block")
seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/dirty.ts"
git -C "$_TEST_TMPDIR" init -q 2>/dev/null || true
git -C "$_TEST_TMPDIR" config user.email t@t 2>/dev/null || true
git -C "$_TEST_TMPDIR" config user.name t 2>/dev/null || true
echo dirty > "$_TEST_TMPDIR/src/lib/dirty.ts" 2>/dev/null || true
git -C "$_TEST_TMPDIR" add -A 2>/dev/null || true
out=$(run_hook stop-gate.sh "$(mock_json "session_id=cond-block")")
assert_contains "core_stop_gate_still_blocks" "$out" '"decision":"block"'

# Same session under LAB with a plan_mode event: the codex reminder fires
# (proving the reminder path is condition-gated, not deleted).
setup_test
set_condition lab
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cond-remind" \
  "1700000002|plan_mode|used")
out=$(run_hook stop-gate.sh "$(mock_json "session_id=cond-remind")")
assert_contains "lab_codex_reminder_fires" "$out" "Codex review not dispatched"
assert_eq "lab_codex_intervention_recorded" "1" \
  "$(count_events intervention codex_reminder '' "$LOG")"

# And the SAME plan-mode-only session under core: approves silently.
setup_test
set_condition core
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cond-noremind" \
  "1700000002|plan_mode|used")
out=$(run_hook stop-gate.sh "$(mock_json "session_id=cond-noremind")")
assert_eq "core_reminders_fully_silent" "{}" "$out"
assert_eq "core_no_codex_intervention" "0" \
  "$(count_events intervention codex_reminder '' "$LOG")"

# =============================================================
# 4. Lab re-edit warning still fires (the treatment is gated, not gone)
# =============================================================
setup_test
set_condition lab
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cond-lab-warn")
for i in 1 2 3; do
  seed_file_edit "$LOG" r "${_TEST_TMPDIR}/src/lib/hot.ts"
done
out=$(run_hook post-edit-dispatch.sh \
  "$(mock_json "session_id=cond-lab-warn" "tool_input.file_path=${_TEST_TMPDIR}/src/lib/hot.ts")")
assert_contains "lab_re_edit_warning_fires" "$out" "Re-edit detected"
assert_eq "lab_re_edit_intervention_recorded" "1" \
  "$(count_events intervention re_edit_warning '' "$LOG")"

# =============================================================
# 5. Statusline: core shows receipts only (line 1); lab shows the organism
# =============================================================
setup_test
set_condition core
LOG=$(create_event_log "$_TEST_TMPDIR/.claude" "cond-sl" \
  "1700000002|file_edit|r ${_TEST_TMPDIR}/src/a.ts")
out=$(bash "$PLUGIN_ROOT/hooks/scripts/statusline.sh" "{\"session_id\":\"cond-sl\"}" 2>/dev/null) || true
assert_contains "core_statusline_line1" "$out" "edits"
assert_not_contains "core_statusline_no_organism_line" "$out" "mutations queued"
set_condition lab
out=$(bash "$PLUGIN_ROOT/hooks/scripts/statusline.sh" "{\"session_id\":\"cond-sl\"}" 2>/dev/null) || true
assert_contains "lab_statusline_organism_line" "$out" "mutations queued"

unset CORTEX_PROFILE
unset CORTEX_PROJECT_DIR_OVERRIDE

end_suite
