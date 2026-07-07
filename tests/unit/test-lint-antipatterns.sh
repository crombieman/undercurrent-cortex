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

end_suite
