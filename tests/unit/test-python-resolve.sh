#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"
source "$TESTS_DIR/lib/mock-commands.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

begin_suite "python-resolve"

assert_file_exists "python_resolve_lib_exists" "$PLUGIN_ROOT/hooks/scripts/lib/python-resolve.sh"

# `|| true`: mirrors the graceful-degradation sourcing the production libs
# use — and lets this suite reach its per-scenario assertions (which fail
# honestly) instead of dying at source time when the lib is absent.
load_resolver() {
  source "$PLUGIN_ROOT/hooks/scripts/lib/python-resolve.sh" 2>/dev/null || true
}

# fake_interpreter <mock_bin_dir> <name> <token>
# A "working" interpreter: consumes stdin, prints <token>, exits 0. Enough to
# prove WHICH candidate the resolver executed — resolution order is the
# behavior under test, not Python semantics.
fake_interpreter() {
  local mock_bin="$1" name="$2" token="$3"
  cat > "$mock_bin/$name" << MOCKEOF
#!/usr/bin/env bash
echo "$name \$*" >> "$mock_bin/$name.calls"
cat >/dev/null
echo "$token"
MOCKEOF
  chmod +x "$mock_bin/$name"
}

# --- Store stub alone: probed, rejected, reported as no-interpreter ---
# The stub IS on PATH (command -v finds it), so rejection must come from
# actually executing it and seeing the non-zero exit.
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
create_store_stub "$mock_bin" "python3"
hide_command "$mock_bin" "python"
hide_command "$mock_bin" "py"
PATH="$mock_bin:$PATH"

load_resolver
status="usable"
out=$(echo '{}' | cortex_python3_run 'print("never")' 2>/dev/null) || status="none"
calls=$(get_mock_calls "$mock_bin" "python3")
assert_eq "stub_only_reports_no_interpreter" "none" "$status"
assert_eq "stub_only_produces_no_output" "" "$out"
assert_contains "stub_was_actually_executed" "$calls" "python3 -c"
restore_path

# --- Healthy python3 wins without consulting later candidates ---
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
fake_interpreter "$mock_bin" "python3" "P3"
fake_interpreter "$mock_bin" "python" "PLAIN"
PATH="$mock_bin:$PATH"

load_resolver
out=$(echo '{}' | cortex_python3_run 'print("x")' 2>/dev/null) || out=""
python_calls=$(get_mock_calls "$mock_bin" "python")
assert_eq "healthy_python3_preferred" "P3" "$out"
assert_eq "healthy_python3_skips_python" "" "$python_calls"
restore_path

# --- Store stub falls back to plain `python` ---
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
create_store_stub "$mock_bin" "python3"
fake_interpreter "$mock_bin" "python" "PLAIN"
PATH="$mock_bin:$PATH"

load_resolver
out=$(echo '{}' | cortex_python3_run 'print("x")' 2>/dev/null) || out=""
assert_eq "stub_falls_back_to_python" "PLAIN" "$out"
restore_path

# --- Store stub + no `python` falls back to the Windows launcher `py -3` ---
# (python.org installers register py even when "add to PATH" was unticked.)
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
create_store_stub "$mock_bin" "python3"
hide_command "$mock_bin" "python"
cat > "$mock_bin/py" << 'MOCKEOF'
#!/usr/bin/env bash
[ "$1" = "-3" ] || exit 2
shift
cat >/dev/null
echo "PYLAUNCHER"
MOCKEOF
chmod +x "$mock_bin/py"
PATH="$mock_bin:$PATH"

load_resolver
out=$(echo '{}' | cortex_python3_run 'print("x")' 2>/dev/null) || out=""
assert_eq "stub_falls_back_to_py_launcher" "PYLAUNCHER" "$out"
restore_path

# --- extract_json_field tier 2 survives the stub via the resolver ---
# RED baseline: `command -v python3` false-positives on the stub, tier 2
# silently dies, and awk tier 3 answers ("raw-awk-value"). GREEN: tier 2
# reaches the working fallback interpreter instead.
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"
create_store_stub "$mock_bin" "python3"
fake_interpreter "$mock_bin" "python" "WIRED"
PATH="$mock_bin:$PATH"

source "$PLUGIN_ROOT/hooks/scripts/lib/json-extract.sh"
result=$(echo '{"session_id":"raw-awk-value"}' | extract_json_field "session_id")
assert_eq "extract_tier2_survives_store_stub" "WIRED" "$result"
restore_path

# --- _eio_extract_sid tier 2 survives the stub via the resolver ---
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"
create_store_stub "$mock_bin" "python3"
fake_interpreter "$mock_bin" "python" "sid-via-fallback"
PATH="$mock_bin:$PATH"

source "$PLUGIN_ROOT/hooks/scripts/lib/event-io.sh"
sid=$(_eio_extract_sid '{"session_id":"awk-sid"}')
assert_eq "sid_tier2_survives_store_stub" "sid-via-fallback" "$sid"
restore_path

# --- Regression: nothing usable at all still extracts via awk tier 3 ---
# This is today's (pre-fix) Windows behavior and must never break: stub
# python3, no python, no py, no jq — extraction still answers.
ORIGINAL_PATH="$PATH"
mock_bin=$(setup_mock_path "$_TEST_TMPDIR")
hide_command "$mock_bin" "jq"
create_store_stub "$mock_bin" "python3"
hide_command "$mock_bin" "python"
hide_command "$mock_bin" "py"
PATH="$mock_bin:$PATH"

source "$PLUGIN_ROOT/hooks/scripts/lib/json-extract.sh"
result=$(echo '{"tool_input":{"file_path":"src/x.ts"}}' | extract_json_field "tool_input.file_path")
assert_eq "no_interpreter_tier3_still_extracts" "src/x.ts" "$result"
restore_path

end_suite
