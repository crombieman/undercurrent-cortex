#!/usr/bin/env bash
set -euo pipefail
# Validates hooks/hooks.json (Task 5: native hooks.json registration). All
# validation logic lives in python3 (explicitly allowed in tests per
# docs/skill-authoring.md / CLAUDE.md testing conventions) — hooks.json is a
# structured document, and hand-rolled bash JSON parsing would be far more
# fragile than the awk/grep string-matching used elsewhere in this repo for
# hook *payloads*. The python3 script prints one tab-separated
# "<test_name>\t<PASS|FAIL>\t<detail>" line per check; bash turns each into a
# framework assertion so failures show up with the usual PASS/FAIL formatting
# and roll into the suite's SUITE summary line.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/lib/test-framework.sh"

PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

begin_suite "hooks-json"

if ! command -v python3 >/dev/null 2>&1; then
  skip_test "hooks_json_validation" "python3 not available"
  end_suite
  exit 0
fi

results=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 <<'PYEOF'
import json
import os
import sys

path = os.environ["HOOKS_JSON_PATH"]
lines = []


def report(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    lines.append(f"{name}\t{status}\t{detail}")


# --- Parse ---
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    report("hooks_json_parses", True)
except Exception as e:  # noqa: BLE001 - want ANY parse failure surfaced as a test failure
    report("hooks_json_parses", False, str(e))
    for l in lines:
        print(l)
    sys.exit(0)

hooks = data.get("hooks", {})

# --- All 7 events present ---
EXPECTED_EVENTS = [
    "SessionStart", "PreToolUse", "PostToolUse", "UserPromptSubmit",
    "Stop", "SessionEnd", "PreCompact",
]
for ev in EXPECTED_EVENTS:
    report(f"event_present_{ev}", ev in hooks and len(hooks.get(ev, [])) > 0,
           "" if ev in hooks else "missing from hooks{}")

if any(ev not in hooks for ev in EXPECTED_EVENTS):
    for l in lines:
        print(l)
    sys.exit(0)

# --- Table of expected matcher/timeout/async per non-SessionStart event ---
# (spec §4.1 table — mirrors bootstrap-hooks.sh's HOOKS_TO_INJECT values,
# except PreToolUse/PostToolUse's matcher, which narrows from ".*" to the
# material tool list — the "tool_call material-only" semantic change.)
TABLE = {
    "PreToolUse":       {"matcher": "Write|Edit|Bash|ExitPlanMode", "timeout": 30,   "async": False},
    "PostToolUse":      {"matcher": "Write|Edit|Bash",              "timeout": 30,   "async": True},
    "UserPromptSubmit": {"matcher": ".*",                           "timeout": None, "async": False},
    "Stop":             {"matcher": ".*",                           "timeout": None, "async": False},
    "SessionEnd":       {"matcher": ".*",                           "timeout": None, "async": False},
    "PreCompact":       {"matcher": ".*",                           "timeout": None, "async": False},
}

SCRIPT_NAMES = {
    "PreToolUse": "pre-dispatch.sh",
    "PostToolUse": "post-dispatch.sh",
    "UserPromptSubmit": "context-flow.sh",
    "Stop": "stop-gate.sh",
    "SessionEnd": "session-end-dispatch.sh",
    "PreCompact": "pre-compact.sh",
}

for ev, expected in TABLE.items():
    groups = hooks[ev]
    report(f"single_group_{ev}", len(groups) == 1, f"got {len(groups)} groups")
    group = groups[0]
    matcher = group.get("matcher")
    report(f"matcher_{ev}", matcher == expected["matcher"],
           f"expected {expected['matcher']!r} got {matcher!r}")

    hook_entries = group.get("hooks", [])
    report(f"single_hook_{ev}", len(hook_entries) == 1, f"got {len(hook_entries)} hooks")
    entry = hook_entries[0] if hook_entries else {}

    cmd = entry.get("command", "")
    report(f"uses_plugin_root_{ev}", "${CLAUDE_PLUGIN_ROOT}" in cmd, cmd)
    report(f"ends_with_native_{ev}", cmd.rstrip().endswith("--native"), cmd)
    script_name = SCRIPT_NAMES[ev]
    report(f"correct_script_{ev}", script_name in cmd, cmd)

    got_timeout = entry.get("timeout")
    report(f"timeout_{ev}", got_timeout == expected["timeout"],
           f"expected {expected['timeout']!r} got {got_timeout!r}")

    got_async = entry.get("async")
    report(f"async_{ev}", got_async == expected["async"],
           f"expected {expected['async']!r} got {got_async!r}")

# --- SessionStart: unchanged, both entries, no --native (native by definition) ---
ss_groups = hooks["SessionStart"]
report("sessionstart_single_group", len(ss_groups) == 1, f"got {len(ss_groups)} groups")
ss_group = ss_groups[0]
report("sessionstart_matcher", ss_group.get("matcher") == ".*", str(ss_group.get("matcher")))
ss_hooks = ss_group.get("hooks", [])
report("sessionstart_two_hooks", len(ss_hooks) == 2, f"got {len(ss_hooks)} hooks")

if len(ss_hooks) == 2:
    session_start_entry, drift_entry = ss_hooks[0], ss_hooks[1]

    report("sessionstart_entry_script", "hooks/session-start" in session_start_entry.get("command", ""),
           session_start_entry.get("command", ""))
    report("sessionstart_entry_uses_plugin_root",
           "${CLAUDE_PLUGIN_ROOT}" in session_start_entry.get("command", ""),
           session_start_entry.get("command", ""))
    report("sessionstart_entry_no_native_flag",
           not session_start_entry.get("command", "").rstrip().endswith("--native"),
           session_start_entry.get("command", ""))
    report("sessionstart_entry_timeout_15", session_start_entry.get("timeout") == 15,
           str(session_start_entry.get("timeout")))
    report("sessionstart_entry_async_false", session_start_entry.get("async") is False,
           str(session_start_entry.get("async")))

    report("drift_detector_script", "drift-detector.sh" in drift_entry.get("command", ""),
           drift_entry.get("command", ""))
    report("drift_detector_uses_plugin_root",
           "${CLAUDE_PLUGIN_ROOT}" in drift_entry.get("command", ""),
           drift_entry.get("command", ""))
    report("drift_detector_no_native_flag",
           not drift_entry.get("command", "").rstrip().endswith("--native"),
           drift_entry.get("command", ""))
    report("drift_detector_async_true", drift_entry.get("async") is True,
           str(drift_entry.get("async")))
    report("drift_detector_no_timeout_key", "timeout" not in drift_entry,
           str(drift_entry.get("timeout")))

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

end_suite
