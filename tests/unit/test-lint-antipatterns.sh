#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

begin_suite "lint-antipatterns"

# grep with -c/--count prints "0" AND exits non-zero on no match; a `|| echo`/
# `|| printf` fallback double-outputs ("0\n0"). Shipped twice (fixed v3.9.3,
# regressed by v3.16). The scanner joins backslash continuations and skips
# comment lines so the pattern can't hide behind formatting.
scan_for_grep_count_fallback() {
  awk '
    { sub(/\r$/, "") }
    prev != "" { $0 = prev $0; prev = "" }
    /\\$/ { prev = substr($0, 1, length($0) - 1); next }
    /^[[:space:]]*#/ { next }
    /grep[^|]*(-[a-zA-Z]*c|--count)[^|]*\|\|[[:space:]]*(echo|printf)/ {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
  ' "$@"
}

# --- hooks/ must be clean ---
mapfile -t hook_files < <(find "$PLUGIN_ROOT/hooks" -type f \( -name '*.sh' -o -name 'session-start' \))
hits=$(scan_for_grep_count_fallback "${hook_files[@]}")
assert_eq "no_grep_count_fallback_in_hooks" "" "$hits"

# --- scanner catches known bypass variants (fixtures) ---
FIX=$(mktemp -d)
printf 'n=$(grep -F -c x f || echo 0)\n' > "$FIX/a.sh"
printf 'n=$(grep --count x f || echo 0)\n' > "$FIX/b.sh"
printf "n=\$(grep -c x f || printf '0')\n" > "$FIX/c.sh"
printf 'n=$(grep -c x f \\\n  || echo 0)\n' > "$FIX/d.sh"
printf '# comment mentioning grep -c || echo is fine\nok=1\n' > "$FIX/e.sh"
printf 'if grep -q x f; then n=$(grep -c x f); fi\n' > "$FIX/f.sh"

hits=$(scan_for_grep_count_fallback "$FIX"/*.sh)
hit_count=$(printf '%s' "$hits" | awk 'NF { c++ } END { print c + 0 }')
assert_eq "scanner_catches_bypass_variants" "4" "$hit_count"
assert_not_contains "scanner_skips_comments_and_clean" "$hits" "e.sh"
assert_not_contains "scanner_skips_guarded_form" "$hits" "f.sh"

# --- the deleted state-io API must never reappear (comment-line-tolerant) ---
# The write surface (write_field/increment_field/append_to_section/
# resolve_state_file/init_state_file/validate_state_file) died in the
# storage-conversion wave; the ENTIRE remaining file — read path
# (read_field/read_section), migration chain (migrate_state_files),
# get_profile, cleanup_stale_state_files — plus the healer
# (validate_organism) died in the calibration wave (T3/T4 = the v4.2
# deletion calendar). eio_get_profile is the only profile reader; the
# hand-rolled word boundary below keeps its `_get_profile` tail from
# false-positiving on the bare name.
# Word boundaries are hand-rolled as (^|[^A-Za-z0-9_])...([^A-Za-z0-9_]|$)
# because \y is gawk-only — ubuntu CI runs mawk, where \y silently matches
# nothing and the scanner goes blind. The explicit form is POSIX ERE and keeps
# e.g. my_write_field_wrapper from false-positiving while catching bare calls.
scan_for_deleted_state_io_calls() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    /(^|[^A-Za-z0-9_])(write_field|increment_field|append_to_section|resolve_state_file|init_state_file|validate_state_file|migrate_state_files|read_field|read_section|get_profile|cleanup_stale_state_files|validate_organism)([^A-Za-z0-9_]|$)/ {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
  ' "$@" 2>/dev/null
}

mapfile -t hook_files_all < <(find "$PLUGIN_ROOT/hooks" -type f \( -name '*.sh' -o -name 'session-start' \))
hits=$(scan_for_deleted_state_io_calls "${hook_files_all[@]}")
assert_eq "no_deleted_state_io_calls_in_hooks" "" "$hits"

# --- scanner catches a planted violation (fixture) ---
FIX2=$(mktemp -d)
printf 'write_field "commits_count" "1" "$STATE_FILE"\n' > "$FIX2/violation.sh"
printf '# write_field is mentioned only in a comment here\nok=1\n' > "$FIX2/clean-comment.sh"
# read_field joined the dead list in T4 (whole read path deleted) — the old
# "unrelated read call is clean" fixture is now itself a planted violation.
printf 'result=$(read_field "session_id" "$STATE_FILE")\n' > "$FIX2/read-violation.sh"
printf 'my_write_field_wrapper x\n' > "$FIX2/clean-wrapper.sh"
printf 'p=$(eio_get_profile)\n' > "$FIX2/clean-eio-profile.sh"

hits2=$(scan_for_deleted_state_io_calls "$FIX2"/*.sh)
hit_count2=$(printf '%s' "$hits2" | awk 'NF { c++ } END { print c + 0 }')
assert_eq "scanner_catches_planted_violations" "2" "$hit_count2"
assert_contains "scanner_flags_violation_file" "$hits2" "violation.sh"
assert_contains "scanner_flags_dead_read_call" "$hits2" "read-violation.sh"
assert_not_contains "scanner_skips_comment_only_mention" "$hits2" "clean-comment.sh"
assert_not_contains "scanner_skips_wrapper_names" "$hits2" "clean-wrapper.sh"
assert_not_contains "scanner_skips_eio_get_profile" "$hits2" "clean-eio-profile.sh"

# --- W7 (spec §12): temp-file-rewrite idioms are allowlist-only ---
# The event-log architecture bans mutation structurally; this scan keeps it
# banned statically. Any `> $TARGET.tmp.$$ && mv`-class rewrite or `sed -i`
# under hooks/ must be one of the known single-writer CONTENT-DOCUMENT
# rewrites (health / proposals / cross-session / collaboration maintenance).
# The allowlist is file+construct pairs, not construct-only — the same idiom
# in a new file, or pointed at a new target (an event log above all), fails.
scan_for_rewrite_idioms() {
  awk '
    { sub(/\r$/, "") }
    prev != "" { $0 = prev $0; prev = "" }
    /\\$/ { prev = substr($0, 1, length($0) - 1); next }
    /^[[:space:]]*#/ { next }
    /(^|[;&|[:space:]])sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-i|--in-place)/ {
      printf "%s:%d:%s\n", FILENAME, FNR, $0; next
    }
    /\.tmp\.\$\$/ {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
  ' "$@" 2>/dev/null
}

# filter_rewrite_allowlist — drops hits matching the sanctioned (file, target)
# pairs; whatever survives is a violation. Targets, all documents:
#   session-start           PROPOSALS_FILE surfaced_count bump (boot, single writer)
#   apply-proposal.sh       PROPOSALS_FILE status transitions (user command)
#   synthesis-automation.sh COLLAB_FILE promotion sweep (boot, single writer)
# REMOVED (calibration wave — the lint FAILS if any of these reappear):
#   validate-organism.sh    healer deleted outright (instrument-defect verdict)
#   session-end-dispatch.sh header-strip deleted (ends the two-writer race class)
#   state-io.sh             file deleted entirely (T4, v4.2 deletion calendar)
filter_rewrite_allowlist() {
  awk '
    {
      file = $0
      sub(/:.*$/, "", file)      # strip first ":" onward (POSIX-style paths)
      sub(/.*\//, "", file)      # basename
      allowed = 0
      if (file == "session-start" && $0 ~ /PROPOSALS_FILE\.tmp\.\$\$/) allowed = 1
      else if (file == "apply-proposal.sh" && $0 ~ /PROPOSALS_FILE\.tmp\.\$\$/) allowed = 1
      else if (file == "synthesis-automation.sh" && $0 ~ /COLLAB_FILE[}]?\.tmp\.\$\$/) allowed = 1
      if (!allowed) print
    }'
}

# hooks/ must be clean after allowlist filtering
mapfile -t hook_files_w7 < <(find "$PLUGIN_ROOT/hooks" -type f \( -name '*.sh' -o -name 'session-start' \))
hits=$(scan_for_rewrite_idioms "${hook_files_w7[@]}" | filter_rewrite_allowlist)
assert_eq "no_unallowlisted_rewrite_idioms_in_hooks" "" "$hits"

# --- fixture proofs ---
FIX3=$(mktemp -d)
# planted violation: the one mutation that must NEVER exist — an event-log rewrite
printf 'awk "..." "$EVENT_LOG" > "$EVENT_LOG.tmp.$$" && mv "$EVENT_LOG.tmp.$$" "$EVENT_LOG"\n' > "$FIX3/eventlog-rewrite.sh"
# planted violation: sed -i (any target)
printf 'sed -i "s/x/y/" "$SOME_FILE"\n' > "$FIX3/sed-inplace.sh"
# planted violation: sed -i behind other flags
printf 'sed -E -i "s/x/y/" "$SOME_FILE"\n' > "$FIX3/sed-inplace-flags.sh"
# planted violation: allowlisted CONSTRUCT in a non-allowlisted FILE
printf 'awk "..." "$HEALTH_FILE" > "$HEALTH_FILE.tmp.$$" && mv "$HEALTH_FILE.tmp.$$" "$HEALTH_FILE"\n' > "$FIX3/new-script.sh"
# clean: comment-only mention
printf '# the old > file.tmp.$$ && mv idiom is banned; sed -i too\nok=1\n' > "$FIX3/clean-comment.sh"
# clean: allowlisted construct in the allowlisted file name
printf 'awk "..." "$PROPOSALS_FILE" > "$PROPOSALS_FILE.tmp.$$" && mv "$PROPOSALS_FILE.tmp.$$" "$PROPOSALS_FILE"\n' > "$FIX3/apply-proposal.sh"
# planted violation: the RETIRED healer pattern must never come back — a
# HEALTH_FILE rewrite is a violation in EVERY file now, including the old
# allowlisted names (calibration wave, queue item 7)
printf 'awk "..." "$HEALTH_FILE" > "$HEALTH_FILE.tmp.$$" && mv "$HEALTH_FILE.tmp.$$" "$HEALTH_FILE"\n' > "$FIX3/validate-organism.sh"
# clean: sed WITHOUT -i (pattern arg, no in-place)
printf 'sed "s/x/y/" "$F" > "$OUT"\n' > "$FIX3/clean-sed.sh"

hits3=$(scan_for_rewrite_idioms "$FIX3"/*.sh | filter_rewrite_allowlist)
hit_count3=$(printf '%s' "$hits3" | awk 'NF { c++ } END { print c + 0 }')
assert_eq "w7_catches_planted_violations" "5" "$hit_count3"
assert_contains "w7_flags_eventlog_rewrite" "$hits3" "eventlog-rewrite.sh"
assert_contains "w7_flags_sed_inplace" "$hits3" "sed-inplace.sh"
assert_contains "w7_flags_sed_inplace_behind_flags" "$hits3" "sed-inplace-flags.sh"
assert_contains "w7_flags_allowlisted_construct_in_new_file" "$hits3" "new-script.sh"
assert_contains "w7_flags_retired_healer_rewrite" "$hits3" "validate-organism.sh"
assert_not_contains "w7_skips_comment_mention" "$hits3" "clean-comment.sh"
assert_not_contains "w7_skips_allowlisted_file_construct" "$hits3" "apply-proposal.sh"
assert_not_contains "w7_skips_sed_without_inplace" "$hits3" "clean-sed.sh"

end_suite
