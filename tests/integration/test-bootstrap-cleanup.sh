#!/usr/bin/env bash
set -euo pipefail
# Validates bootstrap-hooks.sh's cleanup-only contract (Task 6, wave 3).
#
# Background: bootstrap-hooks.sh was created to work around bug #34573 (fixed
# upstream ~2.1.69) by INJECTING PreToolUse/PostToolUse/PreCompact/Stop/
# SessionEnd/UserPromptSubmit command hooks into ~/.claude/settings.json,
# since hooks.json alone was unreliable for those events. As of Task 5, all 7
# events are natively registered in hooks/hooks.json with a --native marker
# protocol that makes any leftover settings.json entries structurally inert.
# bootstrap-hooks.sh's only remaining job is removing those leftovers —
# NEVER injecting anything, ever.
#
# All assertions here run through python3 (explicitly allowed in tests per
# docs/skill-authoring.md) because settings.json is a structured document —
# hand-rolled bash JSON parsing would be far more fragile than the
# report()-per-check pattern used in tests/unit/test-hooks-json.sh, which
# this file mirrors.
#
# HOME sandboxing: the script resolves settings via literal `${HOME}/.claude/
# settings.json` (verified by reading hooks/scripts/bootstrap-hooks.sh), so
# each test passes HOME as a per-invocation prefix var to bash, never
# mutating the outer test shell's real HOME. CORTEX_PROJECT_DIR is set the
# same way for every invocation — state-io.sh's PROJECT_DIR resolution falls
# back to `git rev-parse --show-toplevel` when CORTEX_PROJECT_DIR is unset,
# which inside this repo would resolve to the REAL plugin checkout; leaving
# it unset even once could touch this repo's own .claude/settings.local.json.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BOOTSTRAP="$PLUGIN_ROOT/hooks/scripts/bootstrap-hooks.sh"

begin_suite "bootstrap-cleanup"

if ! command -v python3 >/dev/null 2>&1; then
  skip_test "bootstrap_cleanup_validation" "python3 not available"
  end_suite
  exit 0
fi

# run_bootstrap <home_dir> <project_dir> -- invokes bootstrap-hooks.sh with an
# isolated HOME + CORTEX_PROJECT_DIR, capturing stderr to a scratch file and
# echoing the exit code (captured via `ec=$(run_bootstrap ...)` — never left
# ungated, since this suite runs under set -e itself).
run_bootstrap() {
  local home_dir="$1" project_dir="$2"
  local ec=0
  HOME="$home_dir" CORTEX_PROJECT_DIR="$project_dir" bash "$BOOTSTRAP" \
    2>"$_TEST_TMPDIR/last-stderr.log" || ec=$?
  echo "$ec"
}

# ============================================================================
# Test 1: full fixture — 2 _cortex_bootstrap-tagged entries (PreToolUse +
# PostToolUse, different events), 1 unmarked orphan naming stop-gate.sh
# (Stop, alone in its group), 1 unrelated user hook sharing PreToolUse's
# group with a tagged entry, 1 unrelated event (UserPromptSubmit) with only
# user hooks. After cleanup: cortex entries gone, user hooks byte-identical
# (parsed-JSON comparison), empty events (PostToolUse, Stop) removed, other
# top-level settings keys preserved, file still valid JSON.
# ============================================================================
setup_test
HOME1="$_TEST_TMPDIR/home1"
PROJ1="$_TEST_TMPDIR/proj1"
mkdir -p "$HOME1/.claude" "$PROJ1"
SETTINGS1="$HOME1/.claude/settings.json"
cat > "$SETTINGS1" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "_cortex_bootstrap": true,
            "type": "command",
            "command": "bash \"/plugin/hooks/scripts/pre-dispatch.sh\"",
            "timeout": 30,
            "async": false
          },
          {
            "type": "command",
            "command": "bash /home/user/my-hook.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "_cortex_bootstrap": true,
            "type": "command",
            "command": "bash \"/plugin/hooks/scripts/post-dispatch.sh\"",
            "timeout": 30,
            "async": true
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "bash /some/other/path/stop-gate.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "bash /home/user/other-hook.sh",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "otherTopLevelKey": "preserve-me"
}
JSON

ec=$(run_bootstrap "$HOME1" "$PROJ1")
assert_eq "main_cleanup_exit_code" "0" "$ec"

results=$(SETTINGS_JSON_PATH="$SETTINGS1" python3 <<'PYEOF'
import json
import os
import sys

path = os.environ["SETTINGS_JSON_PATH"]
lines = []


def report(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    lines.append(f"{name}\t{status}\t{detail}")


try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    report("valid_json", True)
except Exception as e:  # noqa: BLE001 - any parse failure is a test failure
    report("valid_json", False, str(e))
    for l in lines:
        print(l)
    sys.exit(0)

hooks = data.get("hooks", {})

EXPECTED_USER_HOOK_IN_PRETOOLUSE = {
    "type": "command",
    "command": "bash /home/user/my-hook.sh",
    "timeout": 10,
}
EXPECTED_USER_PROMPT_SUBMIT = [
    {
        "matcher": ".*",
        "hooks": [
            {"type": "command", "command": "bash /home/user/other-hook.sh", "timeout": 5}
        ],
    }
]

pretool_groups = hooks.get("PreToolUse", [])
report("pretooluse_single_group", len(pretool_groups) == 1, f"got {len(pretool_groups)} groups")
if pretool_groups:
    pretool_hooks = pretool_groups[0].get("hooks", [])
    report("pretooluse_single_hook_survives", len(pretool_hooks) == 1, f"got {len(pretool_hooks)} hooks")
    if pretool_hooks:
        report(
            "pretooluse_user_hook_byte_identical",
            pretool_hooks[0] == EXPECTED_USER_HOOK_IN_PRETOOLUSE,
            json.dumps(pretool_hooks[0]),
        )

report("posttooluse_event_removed", "PostToolUse" not in hooks, str(hooks.get("PostToolUse")))
report("stop_event_removed", "Stop" not in hooks, str(hooks.get("Stop")))
report(
    "userpromptsubmit_unchanged",
    hooks.get("UserPromptSubmit") == EXPECTED_USER_PROMPT_SUBMIT,
    json.dumps(hooks.get("UserPromptSubmit")),
)
report("other_top_level_key_preserved", data.get("otherTopLevelKey") == "preserve-me", str(data.get("otherTopLevelKey")))

CORTEX_SCRIPT_NAMES = [
    "pre-dispatch.sh", "post-dispatch.sh", "stop-gate.sh",
    "pre-compact.sh", "session-end-dispatch.sh", "context-flow.sh",
]


def has_cortex_leftover(hooks_dict):
    for groups in hooks_dict.values():
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("_cortex_bootstrap"):
                    return True
                cmd = h.get("command", "")
                if any(n in cmd for n in CORTEX_SCRIPT_NAMES):
                    return True
    return False


report("no_cortex_leftovers_anywhere", not has_cortex_leftover(hooks), "found leftover cortex hook")

for l in lines:
    print(l)
PYEOF
)

while IFS=$'\t' read -r name status detail; do
  [ -z "$name" ] && continue
  actual="$status"
  [ "$status" != "PASS" ] && [ -n "$detail" ] && actual="${status}: ${detail}"
  assert_eq "$name" "PASS" "$actual"
done <<< "$results"

# ============================================================================
# Test 2: missing settings.json -- exit 0, no file created.
# ============================================================================
setup_test
HOME2="$_TEST_TMPDIR/home2"
PROJ2="$_TEST_TMPDIR/proj2"
mkdir -p "$HOME2" "$PROJ2"
SETTINGS2="$HOME2/.claude/settings.json"

ec=$(run_bootstrap "$HOME2" "$PROJ2")
assert_eq "missing_settings_exit_code" "0" "$ec"
missing_result="absent"
[ -f "$SETTINGS2" ] && missing_result="exists"
assert_eq "missing_settings_no_file_created" "absent" "$missing_result"

# ============================================================================
# Test 3: corrupt settings.json (invalid JSON) -- exit 0, file left
# untouched byte-for-byte. Injection-era behavior recreated a fresh {}; a
# cleanup-only script has no correctness reason to touch a file it can't
# parse (stale entries are inert regardless), so NOT touching it is correct.
# ============================================================================
setup_test
HOME3="$_TEST_TMPDIR/home3"
PROJ3="$_TEST_TMPDIR/proj3"
mkdir -p "$HOME3/.claude" "$PROJ3"
SETTINGS3="$HOME3/.claude/settings.json"
printf '{ this is not valid json,,, [[[' > "$SETTINGS3"
cp "$SETTINGS3" "$SETTINGS3.orig"

ec=$(run_bootstrap "$HOME3" "$PROJ3")
assert_eq "corrupt_settings_exit_code" "0" "$ec"
corrupt_result="changed"
cmp -s "$SETTINGS3" "$SETTINGS3.orig" && corrupt_result="identical"
assert_eq "corrupt_settings_untouched" "identical" "$corrupt_result"

# ============================================================================
# Test 4: python3 masked (exported function returning 127, propagates to the
# child `bash bootstrap-hooks.sh` process via BASH_FUNC_python3%%) -- exit 0,
# file left untouched even though it DOES contain removable cortex entries
# (proves the guard fires on invocation failure, not just on "nothing to do").
# ============================================================================
setup_test
HOME4="$_TEST_TMPDIR/home4"
PROJ4="$_TEST_TMPDIR/proj4"
mkdir -p "$HOME4/.claude" "$PROJ4"
SETTINGS4="$HOME4/.claude/settings.json"
cat > "$SETTINGS4" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "_cortex_bootstrap": true,
            "type": "command",
            "command": "bash \"/plugin/hooks/scripts/stop-gate.sh\"",
            "async": false
          }
        ]
      }
    ]
  }
}
JSON
cp "$SETTINGS4" "$SETTINGS4.orig"

python3() { return 127; }
export -f python3
py_masked=no
python3 >/dev/null 2>&1 || py_masked=yes
assert_eq "python3_masking_took_effect" "yes" "$py_masked"

ec=$(run_bootstrap "$HOME4" "$PROJ4")
assert_eq "python3_masked_exit_code" "0" "$ec"
masked_result="changed"
cmp -s "$SETTINGS4" "$SETTINGS4.orig" && masked_result="identical"
assert_eq "python3_masked_settings_untouched" "identical" "$masked_result"

unset -f python3

# ============================================================================
# Test 5: INJECTS NOTHING -- a settings.json with zero cortex entries (only
# user hooks) must come out byte-IDENTICAL (no rewrite churn). Fixture is
# deliberately compact single-line JSON (not the script's indent=2 output
# style) so a careless "always rewrite" implementation would fail this even
# though the content is semantically unchanged.
# ============================================================================
setup_test
HOME5="$_TEST_TMPDIR/home5"
PROJ5="$_TEST_TMPDIR/proj5"
mkdir -p "$HOME5/.claude" "$PROJ5"
SETTINGS5="$HOME5/.claude/settings.json"
printf '{"hooks":{"UserPromptSubmit":[{"matcher":".*","hooks":[{"type":"command","command":"bash /home/user/other-hook.sh"}]}]}}' > "$SETTINGS5"
cp "$SETTINGS5" "$SETTINGS5.orig"

ec=$(run_bootstrap "$HOME5" "$PROJ5")
assert_eq "injects_nothing_exit_code" "0" "$ec"
nothing_result="changed"
cmp -s "$SETTINGS5" "$SETTINGS5.orig" && nothing_result="identical"
assert_eq "injects_nothing_byte_identical" "identical" "$nothing_result"

# ============================================================================
# Test 6: legacy project-level settings.local.json cleanup still works.
# HOME has no global settings.json at all (isolates this test to the
# project-level path). PROJ has a tagged cortex entry (Stop, alone in its
# group) plus an unrelated user hook (PreToolUse) that must survive.
# ============================================================================
setup_test
HOME6="$_TEST_TMPDIR/home6"
PROJ6="$_TEST_TMPDIR/proj6"
mkdir -p "$HOME6" "$PROJ6/.claude"
OLDSETTINGS6="$PROJ6/.claude/settings.local.json"
cat > "$OLDSETTINGS6" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "_cortex_bootstrap": true,
            "type": "command",
            "command": "bash \"/plugin/hooks/scripts/stop-gate.sh\"",
            "async": false
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "bash /home/user/legacy-hook.sh"
          }
        ]
      }
    ]
  }
}
JSON

ec=$(run_bootstrap "$HOME6" "$PROJ6")
assert_eq "legacy_cleanup_exit_code" "0" "$ec"

legacy_results=$(OLD_SETTINGS_JSON_PATH="$OLDSETTINGS6" python3 <<'PYEOF'
import json
import os
import sys

path = os.environ["OLD_SETTINGS_JSON_PATH"]
lines = []


def report(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    lines.append(f"{name}\t{status}\t{detail}")


try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    report("legacy_valid_json", True)
except Exception as e:  # noqa: BLE001
    report("legacy_valid_json", False, str(e))
    for l in lines:
        print(l)
    sys.exit(0)

hooks = data.get("hooks", {})
report("legacy_stop_event_removed", "Stop" not in hooks, str(hooks.get("Stop")))

EXPECTED_PRETOOLUSE = [
    {
        "matcher": ".*",
        "hooks": [{"type": "command", "command": "bash /home/user/legacy-hook.sh"}],
    }
]
report(
    "legacy_pretooluse_user_hook_survives",
    hooks.get("PreToolUse") == EXPECTED_PRETOOLUSE,
    json.dumps(hooks.get("PreToolUse")),
)

for l in lines:
    print(l)
PYEOF
)

while IFS=$'\t' read -r name status detail; do
  [ -z "$name" ] && continue
  actual="$status"
  [ "$status" != "PASS" ] && [ -n "$detail" ] && actual="${status}: ${detail}"
  assert_eq "$name" "PASS" "$actual"
done <<< "$legacy_results"

end_suite
