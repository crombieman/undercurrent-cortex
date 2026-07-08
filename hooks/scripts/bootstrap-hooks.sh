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

# PROJECT_DIR is needed ONLY to locate the legacy project-level
# settings.local.json for cleanup. Derive it side-effect-free — do NOT source
# state-io.sh, whose source-time migrate_state_files() would mkdir sessions/
# and write .migrated-v3.7 as a side effect of what is now a cleanup-only
# script (Codex I-3). Mirrors state-io.sh's own resolution order.
PROJECT_DIR="${CORTEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"

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
import tempfile

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
    # Anchor to the cortex-distinctive "/hooks/scripts/<name>" path segment,
    # not the bare script basename. A bare-name substring match (the old
    # behavior) also matches a user's OWN hook that merely happens to share
    # a name with a cortex script, e.g. `bash ~/my-tools/stop-gate.sh` —
    # that command contains the substring "stop-gate.sh" but was never
    # ours, and cleanup-only hygiene must never delete a user's hook.
    return any(f"/hooks/scripts/{name}" in cmd for name in CORTEX_SCRIPT_NAMES)


def remove_cortex_bootstrap(hook_list):
    """Remove all cortex hook entries from an event's hook-group list.
    Matches entries with _cortex_bootstrap marker OR entries whose command
    contains a known cortex hook script name (catches unmarked orphans).

    Type-guarded end to end (I-4): a group that isn't a dict, or whose "hooks"
    key isn't a list, is passed through UNTOUCHED rather than AttributeError-ing
    on a malformed settings.json — one bad group must not abort cleanup of the
    rest of the file (or the other settings file)."""
    cleaned = []
    for group in hook_list:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            # Not the shape we manage — leave it exactly as-is.
            cleaned.append(group)
            continue
        group["hooks"] = [
            h for h in group["hooks"]
            if not (isinstance(h, dict) and is_cortex_hook(h))
        ]
        cleaned.append(group)
    # Drop only the groups WE emptied (dict + list "hooks" that is now []).
    # Non-dict / non-list-hooks groups are always preserved.
    return [
        g for g in cleaned
        if not (isinstance(g, dict) and isinstance(g.get("hooks"), list) and not g["hooks"])
    ]


def clean_settings(path, label):
    """Remove cortex entries from a settings file. Returns the count of
    individual hook entries removed. Never touches a file it can't parse or
    that doesn't exist — cleanup-only means no fresh-{} recreation (that was
    injection-era behavior) and no directory/file creation.

    The read, the in-memory edit, AND the write all live inside one
    try/except. A prior version only wrapped the read+parse — a write
    failure (e.g. PermissionError from a read-only settings.local.json) then
    propagated UNCAUGHT out of this function, crashing the whole embedded
    python3 script. When that happened on the SECOND clean_settings() call
    (the legacy file) after the FIRST (the global file) had already
    committed its write successfully, the caller's `python3 ... || echo
    "nothing cleaned"` fallback printed a message that lied — something WAS
    cleaned. Catching the write failure here lets this call return 0
    (its own file genuinely left untouched) while the earlier successful
    call's result is unaffected."""
    if not os.path.isfile(path):
        return 0
    try:
        with open(path, 'r', encoding='utf-8') as f:
            settings = json.load(f)

        # Type-guard every level (I-4): a settings doc that isn't an object, or
        # whose "hooks" isn't a dict (e.g. `"hooks": []`, a string, null), has
        # nothing we manage — skip this file, never AttributeError-abort.
        if not isinstance(settings, dict):
            return 0
        hooks = settings.get("hooks")
        if not isinstance(hooks, dict):
            return 0

        def _count_entries(groups):
            # Only dict groups with a list "hooks" contribute counted entries;
            # everything else is opaque to us and counts as zero.
            return sum(
                len(g["hooks"]) for g in groups
                if isinstance(g, dict) and isinstance(g.get("hooks"), list)
            )

        removed = 0
        for event in list(hooks.keys()):
            groups = hooks[event]
            # An event value that isn't a group LIST (string, dict, null) is not
            # the shape we manage — skip it untouched.
            if not isinstance(groups, list):
                continue
            before_entries = _count_entries(groups)
            cleaned = remove_cortex_bootstrap(groups)
            after_entries = _count_entries(cleaned)
            removed += before_entries - after_entries
            if cleaned:
                hooks[event] = cleaned
            else:
                del hooks[event]

        if removed == 0:
            return 0

        if not hooks:
            del settings["hooks"]

        # A user who made their settings file read-only has opted out of edits.
        # Skip (return 0, file untouched) rather than replace it — os.replace()
        # renames over a read-only target if the DIR is writable, so a plain
        # atomic write would otherwise silently overwrite it. Global cleanup on
        # a different, writable file is unaffected and still counted.
        if not os.access(path, os.W_OK):
            return 0

        # Atomic write (I-5): serialize to a temp file in the SAME directory
        # (so os.replace is an atomic same-filesystem rename), fsync it durable,
        # then replace. A crash mid-write leaves the ORIGINAL intact instead of
        # a truncated settings.json.
        dir_name = os.path.dirname(path) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".bootstrap-hooks.", suffix=".tmp", dir=dir_name)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump(settings, f, indent=2, ensure_ascii=False)
                f.write('\n')
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, path)
        except OSError:
            # Write/replace failed — clean up the temp file and report nothing
            # cleaned for THIS file (its original is untouched). An earlier
            # successful clean_settings() call's result is unaffected.
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            return 0
        return removed
    except (json.JSONDecodeError, OSError):
        return 0


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
