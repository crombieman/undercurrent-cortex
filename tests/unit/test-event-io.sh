#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"

begin_suite "event-io"

# --- append_event: basic format ---
TDIR=$(mktemp -d)
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-test")
append_event "file_edit" "r C:/Users/x/src/a.ts"
line=$(tail -1 "$EVENT_LOG")
assert_contains "append_basic_value" "$line" "|file_edit|r C:/Users/x/src/a.ts"
is_numeric=no; case "${line%%|*}" in ''|*[!0-9]*) : ;; *) is_numeric=yes ;; esac
assert_eq "append_epoch_numeric" "yes" "$is_numeric"

# --- append_event: silent no-op when log missing (mid-session opt-in inertness) ---
EVENT_LOG="$TDIR/nonexistent/x.events.log"
append_event "file_edit" "r C:/a.ts"     # must not error under set -e
missing=yes; [ -f "$EVENT_LOG" ] && missing=no
assert_eq "append_no_log_is_noop" "yes" "$missing"

# --- append_event: T1 metachar class inert in values ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-meta")
append_event "commit" 'abc1234 fix: a|b & \back $dollar'
assert_contains "append_metachars_inert" "$(tail -1 "$EVENT_LOG")" 'a|b & \back $dollar'

# --- append_event: newline flattening ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-nl")
append_event "carry_over" "$(printf 'line1\nline2')"
assert_eq "append_flattens_newlines" "2" "$(wc -l < "$EVENT_LOG" | tr -d ' ')"
assert_contains "append_flatten_content" "$(tail -1 "$EVENT_LOG")" "line1 line2"

# --- resolve_event_log: finds week-bucket log by session_id ---
TDIR2=$(mktemp -d)
f=$(create_event_log "$TDIR2/.claude" "abc-123")
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR2"
resolve_event_log '{"session_id":"abc-123"}'
assert_eq "resolve_from_session_id" "$f" "$EVENT_LOG"

# --- resolve_event_log: missing session_id => EVENT_LOG empty (appends dropped) ---
resolve_event_log '{"no_sid":"here"}'
assert_eq "resolve_missing_sid_blocks_appends" "" "$EVENT_LOG"
unset CORTEX_PROJECT_DIR_OVERRIDE

# --- count_events: basic + prefix filter ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-count")
append_event "file_edit" "r C:/a.ts"
append_event "file_edit" "x C:/tmp/notes.md"
append_event "file_edit" "r C:/b.ts"
assert_eq "count_unfiltered" "3" "$(count_events file_edit)"
assert_eq "count_prefix_r_flag" "2" "$(count_events file_edit r)"

# --- count_events: after-anchor (edits since last commit, spec §3.5) ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-anchor")
append_event "file_edit" "r C:/a.ts"
append_event "commit" "abc1234 feat: x"
append_event "file_edit" "r C:/b.ts"
append_event "file_edit" "r C:/c.ts"
assert_eq "count_after_anchor" "2" "$(count_events file_edit r commit)"

# --- count_events: anchor ERE alternation (escape hatch, spec §3.5) ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-ere")
append_event "stop_blocked" "gate1"
append_event "stop_forced" "true"
append_event "stop_blocked" "gate1"
assert_eq "count_anchor_ere_alternation" "1" "$(count_events stop_blocked '' 'stop_approved|stop_forced')"

# --- spec §3.5 required sequence: block, block, pass, block => no force ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-seq")
append_event "stop_blocked" "g1"; append_event "stop_blocked" "g1"
append_event "stop_approved" "true"
append_event "stop_blocked" "g1"
assert_eq "block_block_pass_block_no_force" "1" "$(count_events stop_blocked '' 'stop_approved|stop_forced')"

# --- last_event: empty when absent, last wins ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-last")
assert_eq "last_event_empty_when_absent" "" "$(last_event mode_set)"
append_event "mode_set" "normal boot"
append_event "mode_set" "cautious fix_ratio"
assert_eq "last_event_last_wins" "cautious fix_ratio" "$(last_event mode_set)"

# --- list_events: file order, pipes preserved in values ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-list")
append_event "carry_over" "item with | pipe"
append_event "carry_over" "second"
expected="item with | pipe
second"
assert_eq "list_events_order_and_pipes" "$expected" "$(list_events carry_over)"

# --- malformed lines skipped; CRLF tolerated ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-mal")
printf 'garbage no pipes\n' >> "$EVENT_LOG"
printf '1700000009|file_edit|r C:/crlf.ts\r\n' >> "$EVENT_LOG"
printf '|||\n' >> "$EVENT_LOG"
assert_eq "malformed_skipped_crlf_counted" "1" "$(count_events file_edit)"
assert_eq "crlf_value_clean" "r C:/crlf.ts" "$(last_event file_edit)"

# --- embedded pipes AND CRLF on the same line (interaction) ---
EVENT_LOG=$(create_event_log "$TDIR/.claude" "s-pipecrlf")
printf '1700000010|carry_over|fix a|b handling\r\n' >> "$EVENT_LOG"
assert_eq "pipes_plus_crlf_value" "fix a|b handling" "$(last_event carry_over)"
assert_eq "pipes_plus_crlf_list" "fix a|b handling" "$(list_events carry_over)"

# --- resolve_event_log: pretty-printed JSON (spaces/newlines around keys) ---
TDIR3=$(mktemp -d)
f3=$(create_event_log "$TDIR3/.claude" "sid-pretty")
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR3"
resolve_event_log "$(printf '{\n  "session_id": "sid-pretty",\n  "tool_name": "Bash"\n}')"
assert_eq "resolve_pretty_json" "$f3" "$EVENT_LOG"

# --- resolve_event_log_readonly: falls back to current-session.id for reads ---
mkdir -p "$TDIR3/.claude/cortex"
printf 'sid-pretty\n' > "$TDIR3/.claude/cortex/current-session.id"
resolve_event_log_readonly '{"no_sid":"here"}'
assert_eq "readonly_falls_back_to_marker" "$f3" "$EVENT_LOG"

# --- resolve_event_log (write path): does NOT use the marker fallback ---
resolve_event_log '{"no_sid":"here"}'
assert_eq "write_resolution_never_uses_marker" "" "$EVENT_LOG"
unset CORTEX_PROJECT_DIR_OVERRIDE

# --- resolve_event_log: tier-3 (bash/awk) fallback ALONE resolves pretty JSON.
# jq/python3 are shadowed with functions that fail closed (return 127, mimicking
# "command not found" once invoked). NOTE: `command -v jq` still reports success
# for a defined function (same as it would for a real binary) — that's fine and
# expected; what actually forces the fallthrough is that CALLING jq/python3
# fails, which the tier 1/2 blocks' `2>/dev/null || true` swallows exactly like
# a malformed-JSON parser error. export -f makes the stubs visible to any child
# bash process too (not required here — resolve_event_log runs in-process —
# but keeps the pattern reusable). Deliberately NOT using mock-commands.sh's
# setup_mock_path/hide_command: that helper's `export PATH=` runs inside the
# `$(...)` command substitution that captures its echoed mock-bin path, i.e.
# inside a subshell, so the PATH mutation never reaches the caller (verified:
# `M=$(setup_mock_path "$T"); hide_command "$M" python3` leaves a REAL python3
# resolvable afterward on any box that has one installed). See task report.
jq() { return 127; }
python3() { return 127; }
export -f jq python3

# Verify the masking actually took (invoking jq/python3 must fail) — a false
# pass here would mean the tests below aren't exercising tier 3 at all.
jq_masked=no; jq >/dev/null 2>&1 || jq_masked=yes
py_masked=no; python3 >/dev/null 2>&1 || py_masked=yes
assert_eq "tier3_test_jq_masked" "yes" "$jq_masked"
assert_eq "tier3_test_python3_masked" "yes" "$py_masked"

TDIR5=$(mktemp -d)
f5=$(create_event_log "$TDIR5/.claude" "sid-tier3")
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR5"
resolve_event_log "$(printf '{\n  "session_id": "sid-tier3",\n  "tool_name": "Bash"\n}')"
assert_eq "resolve_pretty_json_tier3_only" "$f5" "$EVENT_LOG"
unset CORTEX_PROJECT_DIR_OVERRIDE

# --- resolve_event_log: tier-3 fallback takes the FIRST occurrence when a key
# is duplicated (compact JSON) — real parsers keep the LAST duplicate key by
# convention, which would mask a tier-3 regression here. jq/python3 remain
# masked from the block above.
TDIR6=$(mktemp -d)
f6=$(create_event_log "$TDIR6/.claude" "dup-first")
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR6"
resolve_event_log '{"session_id":"dup-first","other":"x","session_id":"dup-second"}'
assert_eq "resolve_duplicate_key_first_wins" "$f6" "$EVENT_LOG"
unset CORTEX_PROJECT_DIR_OVERRIDE

unset -f jq python3

# --- eio_project_dir / eio_get_profile / eio_item_hash (wave 2) ---
TDIR4=$(mktemp -d)
CORTEX_PROJECT_DIR_OVERRIDE="$TDIR4"
assert_eq "eio_project_dir_override" "$TDIR4" "$(eio_project_dir)"

mkdir -p "$TDIR4/.claude/cortex"
assert_eq "profile_default_standard" "standard" "$(eio_get_profile)"
printf 'strict\n' > "$TDIR4/.claude/cortex/profile.local"
assert_eq "profile_from_file" "strict" "$(eio_get_profile)"
printf 'bogus\n' > "$TDIR4/.claude/cortex/profile.local"
assert_eq "profile_invalid_falls_back" "standard" "$(eio_get_profile)"
CORTEX_PROFILE="minimal"
assert_eq "profile_env_wins" "minimal" "$(eio_get_profile)"
unset CORTEX_PROFILE
unset CORTEX_PROJECT_DIR_OVERRIDE

h1=$(eio_item_hash "  fix the thing  ")
h2=$(eio_item_hash "fix the thing")
assert_eq "item_hash_trims_whitespace" "$h1" "$h2"
is_num=no; case "$h1" in ''|*[!0-9]*) : ;; *) is_num=yes ;; esac
assert_eq "item_hash_numeric" "yes" "$is_num"

# --- normalize_path (copied verbatim from state-io.sh, wave 2 task 2) ---
assert_eq "normalize_backslash_drive" "C:/Users/x" "$(normalize_path 'c:\Users\x')"

# --- eio_unresolved_items: epoch-ordered carry-over reconciliation (spec §3.5) ---
# Semantics: an item is UNRESOLVED iff the epoch of its latest carry_over event is
# STRICTLY GREATER than the epoch of the latest carry_addressed event for its hash.
# No addressed event => unresolved. Equal epochs => resolved (addressed wins ties).
TDIRU=$(mktemp -d)

# (a) carried then addressed later => resolved (absent)
uw="Fix the widget"
la=$(create_event_log "$TDIRU/.claude" "u-a" \
  "1700000100|carry_over|$uw" \
  "1700000200|carry_addressed|$(eio_item_hash "$uw")")
assert_eq "unresolved_carried_then_addressed_absent" "" "$(eio_unresolved_items "$la")"

# (b) addressed then RE-RAISED later => unresolved (present)
lb=$(create_event_log "$TDIRU/.claude" "u-b" \
  "1700000100|carry_over|$uw" \
  "1700000200|carry_addressed|$(eio_item_hash "$uw")" \
  "1700000300|carry_over|$uw")
assert_eq "unresolved_reraised_present" "$uw" "$(eio_unresolved_items "$lb")"

# (c) equal epochs => resolved (addressed wins ties, absent)
lc=$(create_event_log "$TDIRU/.claude" "u-c" \
  "1700000100|carry_over|$uw" \
  "1700000100|carry_addressed|$(eio_item_hash "$uw")")
assert_eq "unresolved_equal_epoch_absent" "" "$(eio_unresolved_items "$lc")"

# (d) cross-file: carried log1, addressed later log2 => absent;
#     re-raised even later log3 => present. Epochs compare GLOBALLY.
xw="Cross file item"
ld1=$(create_event_log "$TDIRU/.claude" "u-d1" "1700000100|carry_over|$xw")
ld2=$(create_event_log "$TDIRU/.claude" "u-d2" "1700000200|carry_addressed|$(eio_item_hash "$xw")")
assert_eq "unresolved_crossfile_addressed_absent" "" "$(eio_unresolved_items "$ld1" "$ld2")"
ld3=$(create_event_log "$TDIRU/.claude" "u-d3" "1700000300|carry_over|$xw")
assert_eq "unresolved_crossfile_reraised_present" "$xw" "$(eio_unresolved_items "$ld1" "$ld2" "$ld3")"

# (e) never addressed => unresolved (present)
le=$(create_event_log "$TDIRU/.claude" "u-e" "1700000100|carry_over|Never addressed item")
assert_eq "unresolved_never_addressed_present" "Never addressed item" "$(eio_unresolved_items "$le")"

# (f) dedup: same text carried in two logs => one output line
lf1=$(create_event_log "$TDIRU/.claude" "u-f1" "1700000100|carry_over|Dup item")
lf2=$(create_event_log "$TDIRU/.claude" "u-f2" "1700000200|carry_over|Dup item")
assert_eq "unresolved_dedup_single_line" "Dup item" "$(eio_unresolved_items "$lf1" "$lf2")"

# --- eio_config_get (wave 4: per-project config.local, spec §7.1) ---
TDIRC=$(mktemp -d)
CORTEX_PROJECT_DIR_OVERRIDE="$TDIRC"

# missing file entirely => default (or empty when no default given)
assert_eq "config_missing_file_default" "fallback" "$(eio_config_get some_key "fallback")"
assert_eq "config_missing_file_no_default_empty" "" "$(eio_config_get some_key)"

mkdir -p "$TDIRC/.claude/cortex"
CFG="$TDIRC/.claude/cortex/config.local"

# file exists but key absent => default
printf 'other_key=x\n' > "$CFG"
assert_eq "config_missing_key_default" "fallback" "$(eio_config_get some_key "fallback")"

# basic key=value
printf 'docs_file=readme.md\n' > "$CFG"
assert_eq "config_basic_value" "readme.md" "$(eio_config_get docs_file)"

# first match wins (repeated key — later duplicate ignored)
printf 'architectural_patterns=foo|bar\narchitectural_patterns=SHOULD_NOT_WIN\n' > "$CFG"
assert_eq "config_first_match_wins" "foo|bar" "$(eio_config_get architectural_patterns)"

# comment lines skipped, including indented comments
printf '# comment line\n  # indented comment\nlessons_file=notes/lessons.md\n' > "$CFG"
assert_eq "config_comments_skipped" "notes/lessons.md" "$(eio_config_get lessons_file)"

# a commented-out key is NOT picked up as a match
printf '# docs_file=should-be-ignored.md\ndocs_file=real.md\n' > "$CFG"
assert_eq "config_commented_key_ignored" "real.md" "$(eio_config_get docs_file)"

# trailing CRLF stripped from value
printf 'docs_file=windows.md\r\n' > "$CFG"
assert_eq "config_crlf_stripped" "windows.md" "$(eio_config_get docs_file)"

# value containing '=' and '|' preserved verbatim (split on FIRST '=' only)
printf 'architectural_patterns=a=b|c=d\n' > "$CFG"
assert_eq "config_value_with_equals_and_pipe" "a=b|c=d" "$(eio_config_get architectural_patterns)"

# empty value (key with nothing after '=') => empty string, NOT the default
printf 'commit_nudge_threshold=\n' > "$CFG"
assert_eq "config_empty_value_not_default" "" "$(eio_config_get commit_nudge_threshold "99")"

unset CORTEX_PROJECT_DIR_OVERRIDE
rm -rf "$TDIRC"

# --- eio_config_get: errexit-safe even when the cortex dir doesn't exist at all ---
rc=0
out=$(bash -c '
  set -euo pipefail
  source "$1"
  export CORTEX_PROJECT_DIR_OVERRIDE="$2"
  eio_config_get some_key "safe-default"
' _ "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh" "$(mktemp -d)") || rc=$?
assert_eq "config_get_errexit_safe_rc" "0" "$rc"
assert_eq "config_get_errexit_safe_value" "safe-default" "$out"

# --- resolve_event_log: malformed JSON must not crash under errexit ---
# jq/python3 reject the input; the extraction substitutions must swallow the
# parser failure (hooks contract: always exit 0). Run in a fresh errexit shell
# so the failure propagates exactly as it would in a real hook script.
rc=0; out=$(bash -c 'set -euo pipefail; source "$1"; resolve_event_log "not valid json {{{"; printf "%s" "$EVENT_LOG"' _ "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh") || rc=$?
assert_eq "resolve_malformed_json_no_crash" "0" "$rc"
assert_eq "resolve_malformed_json_empty_log" "" "$out"

# --- eio_intervention_report (wave 4, spec 6.3): follow-through scoring ---
# Fixture logs live in their own sessions tree; the helper takes explicit dirs.
IRD=$(mktemp -d)
mkdir -p "$IRD/.claude/cortex/sessions/2026-W99"
IRLOG1="$IRD/.claude/cortex/sessions/2026-W99/ir1.events.log"
# commit_nudge followed: commit lands after 3 r-edits (window = 5)
cat > "$IRLOG1" <<'IREOF'
1700000001|session_start|2026-07-09T00:00:00Z m
1700000002|intervention|commit_nudge
1700000003|file_edit|r C:/p/a.ts
1700000004|file_edit|r C:/p/b.ts
1700000005|file_edit|r C:/p/c.ts
1700000006|commit|abc1 fix: x
IREOF
IRLOG2="$IRD/.claude/cortex/sessions/2026-W99/ir2.events.log"
# commit_nudge NOT followed: 5 r-edits exhaust the window before the commit
# journal_checkpoint followed (journal_edit within 10 tool_calls)
# re_edit_warning: one warned path re-edited twice (not followed), one once (followed)
# codex_reminder with no codex_review (not followed)
cat > "$IRLOG2" <<'IREOF'
1700000001|session_start|2026-07-09T01:00:00Z m
1700000002|intervention|commit_nudge
1700000003|file_edit|r C:/p/a.ts
1700000004|file_edit|r C:/p/b.ts
1700000005|file_edit|r C:/p/c.ts
1700000006|file_edit|r C:/p/d.ts
1700000007|file_edit|r C:/p/e.ts
1700000008|commit|abc2 feat: late
1700000009|intervention|journal_checkpoint
1700000010|tool_call|Bash
1700000011|tool_call|Edit
1700000012|journal_edit|memory/2026-07-09.md
1700000013|intervention|re_edit_warning C:/p/hot.ts
1700000014|file_edit|r C:/p/hot.ts
1700000015|file_edit|r C:/p/hot.ts
1700000016|intervention|re_edit_warning C:/p/warm.ts
1700000017|file_edit|r C:/p/warm.ts
1700000018|intervention|codex_reminder
IREOF
report=$(eio_intervention_report_dirs "$IRD/.claude/cortex/sessions")
assert_contains "ir_commit_nudge_counts" "$report" "commit_nudge|2|1"
assert_contains "ir_checkpoint_counts" "$report" "journal_checkpoint|1|1"
assert_contains "ir_re_edit_counts" "$report" "re_edit_warning|2|1"
assert_contains "ir_codex_counts" "$report" "codex_reminder|1|0"

# cautious_mode: followed iff the session never went high-churn (no path 3+)
IRLOG3="$IRD/.claude/cortex/sessions/2026-W99/ir3.events.log"
cat > "$IRLOG3" <<'IREOF'
1700000001|session_start|2026-07-09T02:00:00Z m
1700000002|intervention|cautious_mode
1700000003|file_edit|r C:/p/x.ts
1700000004|file_edit|r C:/p/x.ts
IREOF
report=$(eio_intervention_report_dirs "$IRD/.claude/cortex/sessions")
assert_contains "ir_cautious_followed" "$report" "cautious_mode|1|1"
printf '1700000005|file_edit|r C:/p/x.ts
' >> "$IRLOG3"
report=$(eio_intervention_report_dirs "$IRD/.claude/cortex/sessions")
assert_contains "ir_cautious_broken_by_churn" "$report" "cautious_mode|1|0"

# --- append_event sandbox tolerance: a log that EXISTS but is not writable
# (read-only sandbox — cortex hooks fire inside Codex sessions too) must
# degrade to a silent no-op, not crash the caller under set -e (hook
# contract: always exit 0 with JSON). If chmod is ineffective in some
# environment the write just succeeds — the rc assertion is the contract.
ROT=$(mktemp -d)
ROLOG="$ROT/ro.events.log"
printf '1700000001|session_start|2026-07-10T00:00:00Z m\n' > "$ROLOG"
chmod 444 "$ROLOG" 2>/dev/null || true
rc=0
bash -c '
  set -euo pipefail
  source "$1"
  EVENT_LOG="$2"
  append_event tool_call Bash
  echo survived
' _ "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh" "$ROLOG" > /dev/null 2>&1 || rc=$?
assert_eq "append_event_readonly_log_no_crash" "0" "$rc"
chmod 644 "$ROLOG" 2>/dev/null || true

# --- eio_hot_files (wave 5, spec §3.5 / locked D6): cross-session hot files
# derived at read from week-bucket logs — the mutable cross-session.local.md
# tracker is retired. Counting is DISTINCT sessions (per-log dedup), r-flag
# only, plugin-infrastructure paths excluded. ---
HFD=$(mktemp -d)
mkdir -p "$HFD/s/2026-W98" "$HFD/s/2026-W99"
hf_log() {
  local f="$HFD/s/$1.events.log"; shift
  printf '1700000001|session_start|2026-07-10T00:00:00Z m\n' > "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
hf_log "2026-W98/h1" \
  "1700000002|file_edit|r C:/p/src/hot.ts" \
  "1700000003|file_edit|r C:/p/src/warm.ts" \
  "1700000004|file_edit|x C:/ext/xfile.ts" \
  "1700000005|file_edit|r C:/p/.claude/exemplars/e.ts"
hf_log "2026-W98/h2" \
  "1700000002|file_edit|r C:/p/src/hot.ts" \
  "1700000003|file_edit|r C:/p/src/warm.ts" \
  "1700000004|file_edit|x C:/ext/xfile.ts" \
  "1700000005|file_edit|r C:/p/.claude/exemplars/e.ts"
hf_log "2026-W99/h3" \
  "1700000002|file_edit|r C:/p/src/hot.ts" \
  "1700000003|file_edit|r C:/p/src/warm.ts" \
  "1700000004|file_edit|x C:/ext/xfile.ts" \
  "1700000005|file_edit|r C:/p/.claude/exemplars/e.ts"
# h4: hot.ts edited THREE times in one log — still ONE distinct session
hf_log "2026-W99/h4" \
  "1700000002|file_edit|r C:/p/src/hot.ts" \
  "1700000003|file_edit|r C:/p/src/hot.ts" \
  "1700000004|file_edit|r C:/p/src/hot.ts" \
  "1700000005|file_edit|x C:/ext/xfile.ts" \
  "1700000006|file_edit|r C:/p/.claude/exemplars/e.ts"
report=$(eio_hot_files 30 4 "$HFD/s")
assert_contains "hot_files_4_distinct_sessions_listed" "$report" "C:/p/src/hot.ts|4"
assert_not_contains "hot_files_3_sessions_omitted" "$report" "warm.ts"
assert_not_contains "hot_files_x_flag_omitted" "$report" "xfile.ts"
assert_not_contains "hot_files_plugin_paths_omitted" "$report" ".claude/exemplars"
report=$(eio_hot_files 30 3 "$HFD/s")
assert_contains "hot_files_min_sessions_override" "$report" "C:/p/src/warm.ts|3"

# journal_checkpoint 10th-tool boundary (Codex W4 review I-4): the journal
# Write's OWN tool_call is logged before its journal_edit, so a journal edit
# landing on exactly the 10th tool call IS "within the next 10 tool events"
# and must score as followed; the 11th is out.
IRB=$(mktemp -d)
mkdir -p "$IRB/.claude/cortex/sessions/2026-W99"
jc_log() {
  local name="$1" tools="$2"
  local f="$IRB/.claude/cortex/sessions/2026-W99/${name}.events.log"
  printf '1700000001|session_start|2026-07-10T00:00:00Z m\n' > "$f"
  printf '1700000002|intervention|journal_checkpoint\n' >> "$f"
  local i
  for i in $(seq 1 "$tools"); do
    printf '%s|tool_call|Edit\n' "$((1700000002 + i))" >> "$f"
  done
  printf '1700000099|journal_edit|memory/2026-07-10.md\n' >> "$f"
}
jc_log "jc-tenth" 10
report=$(eio_intervention_report_dirs "$IRB/.claude/cortex/sessions")
assert_contains "ir_checkpoint_followed_on_exact_tenth_tool" "$report" "journal_checkpoint|1|1"
rm "$IRB/.claude/cortex/sessions/2026-W99/jc-tenth.events.log"
jc_log "jc-eleventh" 11
report=$(eio_intervention_report_dirs "$IRB/.claude/cortex/sessions")
assert_contains "ir_checkpoint_not_followed_on_eleventh_tool" "$report" "journal_checkpoint|1|0"

# codex_reminder follow-through requires a codex_review LATER than the
# reminder (spec §6.3 "later in the same session"; Codex W4 review M-2) — a
# review that happened BEFORE the reminder fired must not count.
IRC=$(mktemp -d)
mkdir -p "$IRC/.claude/cortex/sessions/2026-W99"
cat > "$IRC/.claude/cortex/sessions/2026-W99/cr-before.events.log" <<'IREOF'
1700000001|session_start|2026-07-10T00:00:00Z m
1700000002|codex_review|cli
1700000003|intervention|codex_reminder
IREOF
report=$(eio_intervention_report_dirs "$IRC/.claude/cortex/sessions")
assert_contains "ir_codex_review_before_reminder_not_followed" "$report" "codex_reminder|1|0"
cat > "$IRC/.claude/cortex/sessions/2026-W99/cr-before.events.log" <<'IREOF'
1700000001|session_start|2026-07-10T00:00:00Z m
1700000002|intervention|codex_reminder
1700000003|codex_review|cli
IREOF
report=$(eio_intervention_report_dirs "$IRC/.claude/cortex/sessions")
assert_contains "ir_codex_review_after_reminder_followed" "$report" "codex_reminder|1|1"

# Kinds never fired are OMITTED — a log with zero intervention events yields an
# EMPTY report, not spurious "cautious_mode|0|0"/"codex_reminder|0|0" rows.
# (Regression: awk instantiates array keys on mere reference — fired["x"] in a
# condition created the key, leaking 0/0 rows into every report and forcing a
# phantom third statusline line on projects with no interventions at all.)
IRD2=$(mktemp -d)
mkdir -p "$IRD2/.claude/cortex/sessions/2026-W99"
cat > "$IRD2/.claude/cortex/sessions/2026-W99/quiet.events.log" <<'IREOF'
1700000001|session_start|2026-07-10T00:00:00Z m
1700000002|file_edit|r C:/p/a.ts
1700000003|commit|abc1 feat: quiet
IREOF
report=$(eio_intervention_report_dirs "$IRD2/.claude/cortex/sessions")
assert_eq "ir_no_interventions_empty_report" "" "$report"

end_suite
