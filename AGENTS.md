# AGENTS.md - Cortex Plugin
<!-- Audited: 2026-07-10 (v4 rewrite). Review quarterly. -->
<!-- SCOPE: This is the PROJECT-LEVEL instruction file for the Cortex plugin,
     mirrored for Codex. Content is kept in sync with CLAUDE.md IN THE SAME
     COMMIT (R7 coupling rule). Put ONLY plugin-specific rules here. -->

## Project
Claude Code plugin — session management, health tracking, context injection, adaptive learning. 13 biological systems that compound intelligence across coding sessions. v4: append-only event-log state, native hook registration, opt-in activation, git-derived health.

## Stack
- Bash scripts (POSIX-ish, Git Bash on Windows)
- POSIX awk only in the hook path (mawk-safe — ubuntu CI runs mawk; no gawk-isms like `\y`)
- No jq/python3/flock dependencies in hooks (jq/python3 are optional accelerators); no npm, no build step

### Plugin References
- docs/hook-architecture.md
- docs/state-files.md
- docs/context-flow.md
- docs/skill-authoring.md

## Architecture

### Directory Layout
- `hooks/hooks.json` — ALL 7 events registered natively (SessionStart, PreToolUse, PostToolUse, Stop, SessionEnd, UserPromptSubmit, PreCompact)
- `hooks/session-start` — Session init: sole creator of the event log; healing, carry-over, sensory, feedback, statusline
- `hooks/scripts/` — Dispatch and handler scripts
- `hooks/scripts/lib/` — Shared libraries (event-io = the state layer, health-trend, escape-json, json-extract, validate-organism, state-io = legacy read-only)
- `skills/` — SKILL.md files with YAML frontmatter (16 skills)
- `agents/` — Agent .md files with system prompts (4 agents)
- `commands/` — Slash command .md files (10 commands)
- `context/` — Auto-discovered context files with `keywords:` frontmatter (8 keyword-injected of 12 total)
- `tests/` — Bash test suite (41 scripts; ubuntu + windows CI)

### Hooks & Activation
- All 7 events fire natively from `hooks.json`; non-SessionStart scripts take a `--native` flag and suppress stale settings.json bootstrap entries via the `native-hooks.ok` marker (see docs/hook-architecture.md)
- Opt-in sentinel: `.claude/cortex/enabled` FILE gates every entry point — un-opted repos get `{}` and zero writes
- `bootstrap-hooks.sh` is cleanup-only; it and the v3.7 migration chain + legacy carry-over reader are **deleted in v4.2**

### State (v4: append-only event log)
- Per-session log: `{project}/.claude/cortex/sessions/YYYY-WNN/{session_id}.events.log`, lines `epoch|event_type|value` — value is EVERYTHING after the 2nd pipe (may contain pipes); NEVER parse by hand, use event-io helpers
- `append_event` is the ONLY write primitive; `resolve_event_log` (from hook stdin `session_id`) gates every write; session-start is the only log creator
- Everything is derived at read time: `count_events` (with anchor ERE), `last_event`, `list_events`, `eio_last_line_of`, `eio_hot_files`, `eio_intervention_report`, `eio_unresolved_items`, `eio_config_get`
- Documents (health/proposals/decisions) stay markdown; the only sanctioned rewrites are the single-writer document maintenance sites allowlisted in `tests/unit/test-lint-antipatterns.sh`
- Per-project vocabulary lives in `.claude/cortex/config.local` (`architectural_patterns`, `docs_file`, `lessons_file`, `test_command`, `commit_nudge_threshold`) — never hardcode project-specific patterns into hooks

## Key Patterns
- All scripts: `set -euo pipefail`; hooks ALWAYS exit 0 with valid JSON on stdout
- Buffer stdin once: `INPUT=$(cat)` at script top
- JSON field extraction: `extract_json_field` from `lib/json-extract.sh`
- Project dir: derived from `git rev-parse --show-toplevel` (tests override via `CORTEX_PROJECT_DIR_OVERRIDE`/`CORTEX_PROJECT_DIR`), NOT `CLAUDE_PROJECT_DIR` (broken)
- Pipe safety: `ls glob | head -1 || true` (pipefail kills on glob miss)
- Grep in conditionals: `if grep -q pattern file; then` (not bare grep under errexit)
- Windows paths in awk: pass via `ENVIRON`, never `awk -v` (backslash mangling)
- Reminders never emit `decision:block`; blocking gates keep the block JSON shape
- Event vocabulary is CLOSED (docs/state-files.md) — new types require a spec update
- TDD: RED first, targeted suites per task, full suite at wave boundaries

## Testing
- `bash tests/run-all.sh` — all suites (~8 min); targeted suite per task during work
- Framework: `tests/lib/test-framework.sh` (assert_eq, assert_contains, assert_file_exists, …)
- Fixtures: `tests/lib/fixtures.sh` (`create_event_log`, `seed_file_edit`, `set_config`, `create_health_file`, `mock_json`)
- Categories: unit/, integration/, edge/, regression/; lint scans in `tests/unit/test-lint-antipatterns.sh` keep deleted APIs and mutation idioms dead

## Plugin Publishing
- Bump version in `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` in the SAME commit as the behavior change (separate commits = stale cache)
- Push to master; cache updates via `claude plugins update cortex@undercurrent-studio` + restart

## Windows Gotchas
- Shell: Git Bash, not cmd/PowerShell
- Paths: Forward slashes in scripts, ENVIRON not `awk -v` for backslash paths
- pipefail: `ls glob | head` needs `|| true`
- `cut -d:` splits on drive letter C: — use `sed` to strip prefix first
- Line endings: `.gitattributes` handles CRLF conversion; readers strip trailing `\r`
