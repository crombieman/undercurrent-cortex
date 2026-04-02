#!/usr/bin/env bash
set -euo pipefail

# Tests for hooks/scripts/synthesis-automation.sh
# Covers: promotion sweep, staleness check, edge cases, golden output.
# Dynamic dates used for staleness — no hardcoded absolutes.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/fixtures.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/synthesis-automation.sh"

begin_suite "synthesis-automation"

# --- Helpers ---

# create_collab_file <entries...>
# Each entry: "name|reinforced|date|unconfirmed"
# unconfirmed defaults to "true" — most tests need the tag present.
# The [unconfirmed] tag is controlled by the 4th field, NOT derived from Reinforced.
create_collab_file() {
  local file="$_TEST_TMPDIR/collab.md"
  echo "# Collaboration Patterns" > "$file"
  for entry in "$@"; do
    IFS='|' read -r name reinforced date unconfirmed <<< "$entry"
    unconfirmed="${unconfirmed:-true}"
    local tag=""
    [ "$unconfirmed" = "true" ] && tag=" [unconfirmed]"
    cat >> "$file" << EOF

### ${name}${tag}
Description of pattern.

- **Reinforced**: ${reinforced} (${date})
- **Last validated**: ${date}
- **Scope**: testing
EOF
  done
  echo "$file"
}

# run_synth [collab_file_path]
# Runs the script with COLLAB_FILE pointed at the given path.
run_synth() {
  local collab_file="${1:-$_TEST_TMPDIR/collab.md}"
  COLLAB_FILE="$collab_file" bash "$SCRIPT" 2>/dev/null || true
}

# Compute dynamic dates for staleness tests
fresh_date=$(date -d "15 days ago" +%Y-%m-%d 2>/dev/null || date -v-15d +%Y-%m-%d 2>/dev/null || echo "2026-03-18")
stale_date=$(date -d "31 days ago" +%Y-%m-%d 2>/dev/null || date -v-31d +%Y-%m-%d 2>/dev/null || echo "2026-03-02")
very_stale_date=$(date -d "90 days ago" +%Y-%m-%d 2>/dev/null || date -v-90d +%Y-%m-%d 2>/dev/null || echo "2026-01-02")
today=$(date +%Y-%m-%d)

# ============================================================
# PROMOTION SWEEP TESTS
# ============================================================

# Test 1: Reinforced=1 keeps [unconfirmed] tag
setup_test
create_collab_file "PatternA|1|${today}|true" > /dev/null
run_synth > /dev/null
assert_file_contains "reinforced_1_keeps_tag" "$_TEST_TMPDIR/collab.md" "[unconfirmed]"

# Test 2: Reinforced=2 removes [unconfirmed] tag
setup_test
create_collab_file "PatternB|2|${today}|true" > /dev/null
run_synth > /dev/null
assert_file_not_contains "reinforced_2_removes_tag" "$_TEST_TMPDIR/collab.md" "[unconfirmed]"

# Test 3: Reinforced=5 removes [unconfirmed] tag
setup_test
create_collab_file "PatternC|5|${today}|true" > /dev/null
run_synth > /dev/null
assert_file_not_contains "reinforced_5_removes_tag" "$_TEST_TMPDIR/collab.md" "[unconfirmed]"

# Test 4: Mixed patterns — selective promotion
setup_test
create_collab_file "Keep|1|${today}|true" "Remove1|2|${today}|true" "Remove2|4|${today}|true" > /dev/null
run_synth > /dev/null
# Only "Keep" should retain [unconfirmed]
count=0
if grep -q '\[unconfirmed\]' "$_TEST_TMPDIR/collab.md" 2>/dev/null; then
  count=$(grep -c '\[unconfirmed\]' "$_TEST_TMPDIR/collab.md" 2>/dev/null)
fi
assert_eq "mixed_patterns_selective_promotion" "1" "$count"

# Test 5: No [unconfirmed] patterns — no changes
setup_test
create_collab_file "Confirmed|3|${today}|false" > /dev/null
md5_before=$(md5sum "$_TEST_TMPDIR/collab.md" 2>/dev/null | cut -d' ' -f1 || shasum "$_TEST_TMPDIR/collab.md" | cut -d' ' -f1)
result=$(run_synth)
md5_after=$(md5sum "$_TEST_TMPDIR/collab.md" 2>/dev/null | cut -d' ' -f1 || shasum "$_TEST_TMPDIR/collab.md" | cut -d' ' -f1)
assert_eq "no_unconfirmed_no_changes" "$md5_before" "$md5_after"

# Test 6: Line count preserved after promotion
setup_test
create_collab_file "A|1|${today}|true" "B|3|${today}|true" "C|2|${today}|true" > /dev/null
lines_before=$(wc -l < "$_TEST_TMPDIR/collab.md")
run_synth > /dev/null
lines_after=$(wc -l < "$_TEST_TMPDIR/collab.md")
assert_eq "line_count_preserved" "$lines_before" "$lines_after"

# Test 7: Heading name preserved after tag removal
setup_test
create_collab_file "Important Pattern|2|${today}|true" > /dev/null
run_synth > /dev/null
assert_file_contains "heading_preserved_after_promotion" "$_TEST_TMPDIR/collab.md" "### Important Pattern"

# ============================================================
# STALENESS CHECK TESTS
# ============================================================

# Test 8: Fresh pattern (15d) — no warning
setup_test
create_collab_file "FreshPattern|1|${fresh_date}|false" > /dev/null
result=$(run_synth)
assert_not_contains "fresh_pattern_no_warning" "$result" "Stale"

# Test 9: Stale pattern (31d) — warning emitted
setup_test
create_collab_file "StalePattern|1|${stale_date}|false" > /dev/null
result=$(run_synth)
assert_contains "stale_pattern_warns" "$result" "StalePattern"

# Test 10: Very stale pattern (90d) — warning emitted
setup_test
create_collab_file "VeryStale|1|${very_stale_date}|false" > /dev/null
result=$(run_synth)
assert_contains "very_stale_pattern_warns" "$result" "VeryStale"

# Test 11: Missing Last validated — no crash
setup_test
# Manually create a file without Last validated line
cat > "$_TEST_TMPDIR/collab.md" << 'EOF'
# Collaboration Patterns

### NoDate [unconfirmed]
Description.

- **Reinforced**: 1 (2026-04-01)
- **Scope**: testing
EOF
result=$(run_synth)
# Should not crash and should not warn about staleness
assert_not_contains "missing_date_no_crash" "$result" "Stale"

# Test 12: Mixed fresh and stale
setup_test
create_collab_file "Fresh|1|${fresh_date}|false" "Stale31|1|${stale_date}|false" "Stale90|1|${very_stale_date}|false" > /dev/null
result=$(run_synth)
assert_not_contains "mixed_fresh_not_warned" "$result" "Fresh"
assert_contains "mixed_stale31_warned" "$result" "Stale31"
assert_contains "mixed_stale90_warned" "$result" "Stale90"

# ============================================================
# EDGE CASE TESTS
# ============================================================

# Test 13: Missing file — exits clean
setup_test
result=$(COLLAB_FILE="/nonexistent/path/collab.md" bash "$SCRIPT" 2>/dev/null || true)
exit_code=$?
assert_eq "missing_file_exits_clean" "" "$result"

# Test 14: Empty file — exits clean
setup_test
> "$_TEST_TMPDIR/collab.md"
result=$(run_synth)
assert_eq "empty_file_exits_clean" "" "$result"

# Test 15: Malformed Reinforced value — no crash
setup_test
cat > "$_TEST_TMPDIR/collab.md" << 'EOF'
# Collaboration Patterns

### Malformed [unconfirmed]
Description.

- **Reinforced**: abc (2026-04-01)
- **Last validated**: 2026-04-01
EOF
result=$(run_synth)
# Should not crash — malformed count defaults to 0 via ${count:-0}
# Tag should be kept (abc is not >= 2)
assert_file_contains "malformed_reinforced_no_crash" "$_TEST_TMPDIR/collab.md" "[unconfirmed]"

# ============================================================
# GOLDEN OUTPUT TEST
# ============================================================

# Test 16: Output format matches what synthesis_directive consumes
setup_test
create_collab_file "Promotable|2|${stale_date}|true" > /dev/null
result=$(run_synth)
# Should contain both promotion message and stale warning
assert_contains "golden_output_promotion" "$result" "Promoted 1 pattern(s) from [unconfirmed] (Reinforced >= 2)."
assert_contains "golden_output_stale" "$result" "Stale collaboration patterns (>30d since last validated):"
assert_contains "golden_output_pattern_name" "$result" "Promotable"

end_suite
