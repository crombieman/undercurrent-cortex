#!/usr/bin/env bash
# bootstrap-hooks.sh - CLEANUP ONLY.
#
# Originally created to work around bug #34573 (Claude Code hooks.json
# command hooks unreliable for non-SessionStart events) by INJECTING
# PreToolUse/PostToolUse/PreCompact/Stop/SessionEnd/UserPromptSubmit hooks
# into the global ~/.claude/settings.json. That bug was fixed upstream
# ~2.1.69. As of Task 5, all 7 events are natively registered in
# hooks/hooks.json with a --native marker protocol (see hooks/session-start,
# .claude/cortex/native-hooks.ok) that makes any leftover settings.json
# entries from this script's old injection behavior structurally inert —
# dispatchers detect the marker and no-op instead of double-firing.
#
# THIS FILE'S ONLY JOB NOW: remove leftover _cortex_bootstrap-tagged entries
# (and unmarked orphans matching known cortex script names) from
# ~/.claude/settings.json and the legacy project-level settings.local.json.
# It injects nothing, ever. Best-effort hygiene, not correctness — native
# registration owns every event regardless of what this script does or
# doesn't clean up.
#
# See: https://github.com/anthropics/claude-code/issues/34573
# DELETE THIS FILE in v4.2 per spec §4.4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source state-io for PROJECT_DIR (needed for legacy settings.local.json
# cleanup only — no longer needed for command generation).
source "$SCRIPT_DIR/lib/state-io.sh" 2>/dev/null || true

# Fallback: derive PROJECT_DIR from git root
if [ -z "${PROJECT_DIR:-}" ]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
fi

# Global settings — where the old injection used to land.
SETTINGS_FILE="${HOME}/.claude/settings.json"

# Legacy project-level location (pre-dates the global-settings switch).
OLD_SETTINGS="${PROJECT_DIR:+${PROJECT_DIR}/.claude/settings.local.json}"

# Stale entries are inert via the native marker protocol — cleanup is
# best-effort hygiene, not correctness. No python3, no work, no noise.
command -v python3 >/dev/null 2>&1 || exit 0

export OLD_SETTINGS="${OLD_SETTINGS:-}"

# Guarded (not a bare simple command): a python3 that resolves via `command
# -v` above (e.g. a masked/broken shim) but fails when actually invoked must
# still leave this script exiting 0 with the settings files untouched, per
# the same "hygiene, not correctness" contract as the missing-python3 case.
if ! python3 - "$SETTINGS_FILE" <<'PYEOF'
import json
import sys
import os

settings_path = sys.argv[1]
old_settings_path = os.environ.get("OLD_SETTINGS", "")

CORTEX_SCRIPT_NAMES = [
    "pre-dispatch.sh", "post-dispatch.sh", "stop-gate.sh",
    "pre-compact.sh", "session-end-dispatch.sh", "context-flow.sh",
]


def is_cortex_hook(h):
    if h.get("_cortex_bootstrap"):
        return True
    cmd = h.get("command", "")
    return any(name in cmd for name in CORTEX_SCRIPT_NAMES)


def remove_cortex_bootstrap(hook_list):
    """Remove all cortex hook entries from an event's hook list.
    Matches entries with _cortex_bootstrap marker OR entries whose command
    contains a known cortex hook script name (catches unmarked orphans)."""
    for group in hook_list:
        group["hooks"] = [h for h in group.get("hooks", []) if not is_cortex_hook(h)]
    # Remove empty groups
    return [g for g in hook_list if g.get("hooks")]


def clean_settings(path, label):
    """Remove cortex entries from a settings file. Returns the count of
    individual hook entries removed. Never touches a file it can't parse or
    that doesn't exist — cleanup-only means no fresh-{} recreation (that was
    injection-era behavior) and no directory/file creation."""
    if not os.path.isfile(path):
        return 0
    try:
        with open(path, 'r', encoding='utf-8') as f:
            settings = json.load(f)
    except (json.JSONDecodeError, IOError):
        return 0

    hooks = settings.get("hooks")
    if not hooks:
        return 0

    removed = 0
    for event in list(hooks.keys()):
        before_entries = sum(len(g.get("hooks", [])) for g in hooks[event])
        cleaned = remove_cortex_bootstrap(hooks[event])
        after_entries = sum(len(g.get("hooks", [])) for g in cleaned)
        removed += before_entries - after_entries
        if cleaned:
            hooks[event] = cleaned
        else:
            del hooks[event]

    if removed == 0:
        return 0

    if not hooks:
        del settings["hooks"]

    with open(path, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write('\n')
    return removed


removed_global = clean_settings(settings_path, "~/.claude/settings.json")
removed_legacy = 0
if old_settings_path:
    removed_legacy = clean_settings(old_settings_path, "project settings.local.json")

total = removed_global + removed_legacy
if total == 0:
    print("bootstrap-hooks: nothing to clean", file=sys.stderr)
else:
    parts = []
    if removed_global:
        parts.append(f"{removed_global} from ~/.claude/settings.json")
    if removed_legacy:
        parts.append(f"{removed_legacy} from project settings.local.json")
    noun = "entry" if total == 1 else "entries"
    print(f"bootstrap-hooks: removed {total} cortex hook {noun} ({', '.join(parts)})", file=sys.stderr)
PYEOF
then
  echo "bootstrap-hooks: python3 invocation failed, nothing cleaned" >&2
fi

exit 0
