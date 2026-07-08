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

# --- deleted state-io write surface must never reappear (comment-line-tolerant) ---
# write_field/increment_field/append_to_section/resolve_state_file/
# init_state_file/validate_state_file were deleted from state-io.sh in the
# storage-conversion wave (Task 10) — hooks write exclusively through the
# append-only event log now. Their DEFINITIONS may only remain in state-io.sh
# itself (which the deletion left with read_field/read_section/get_profile/
# cleanup_stale_state_files/migrate_state_files/normalize_path).
# Word boundaries are hand-rolled as (^|[^A-Za-z0-9_])...([^A-Za-z0-9_]|$)
# because \y is gawk-only — ubuntu CI runs mawk, where \y silently matches
# nothing and the scanner goes blind. The explicit form is POSIX ERE and keeps
# e.g. my_write_field_wrapper from false-positiving while catching bare calls.
scan_for_deleted_state_io_calls() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    /(^|[^A-Za-z0-9_])(write_field|increment_field|append_to_section|resolve_state_file|init_state_file|validate_state_file)([^A-Za-z0-9_]|$)/ {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
  ' "$@" 2>/dev/null
}

mapfile -t hook_files_all < <(find "$PLUGIN_ROOT/hooks" -type f \( -name '*.sh' -o -name 'session-start' \) ! -name 'state-io.sh')
hits=$(scan_for_deleted_state_io_calls "${hook_files_all[@]}")
assert_eq "no_deleted_state_io_write_calls_outside_state_io" "" "$hits"

# --- scanner catches a planted violation (fixture) ---
FIX2=$(mktemp -d)
printf 'write_field "commits_count" "1" "$STATE_FILE"\n' > "$FIX2/violation.sh"
printf '# write_field is mentioned only in a comment here\nok=1\n' > "$FIX2/clean-comment.sh"
printf 'result=$(read_field "session_id" "$STATE_FILE")\n' > "$FIX2/clean-read.sh"
printf 'my_write_field_wrapper x\n' > "$FIX2/clean-wrapper.sh"

hits2=$(scan_for_deleted_state_io_calls "$FIX2"/*.sh)
hit_count2=$(printf '%s' "$hits2" | awk 'NF { c++ } END { print c + 0 }')
assert_eq "scanner_catches_planted_violation" "1" "$hit_count2"
assert_contains "scanner_flags_violation_file" "$hits2" "violation.sh"
assert_not_contains "scanner_skips_comment_only_mention" "$hits2" "clean-comment.sh"
assert_not_contains "scanner_skips_unrelated_read_call" "$hits2" "clean-read.sh"
assert_not_contains "scanner_skips_wrapper_names" "$hits2" "clean-wrapper.sh"

end_suite
