# AGENTS.md - Cortex Plugin
<!-- Audited: 2026-04-02. Review quarterly. -->
<!-- SCOPE: This is the PROJECT-LEVEL instruction file for the Cortex plugin.
     Put ONLY plugin-specific rules here — bash/shell patterns, hook architecture,
     state file layout, testing framework, Windows gotchas.
     Cross-project behavioral rules are in ~/.Codex/AGENTS.md.
     Universal preferences (communication, git, principles) are in ~/.Codex/rules/. -->

## Project
Codex plugin — session management, health tracking, context injection, adaptive learning. 13 biological systems that compound intelligence across coding sessions.

## Stack
- Bash scripts (POSIX-ish, Git Bash on Windows)
- Python3 (JSON manipulation in bootstrap-hooks.sh only)
- No npm dependencies, no build step

### Plugin References
@docs/hook-architecture.md
@docs/state-files.md
@docs/context-flow.md
@docs/skill-authoring.md

## Architecture

### Directory Layout
- `hooks/hooks.json` — Hook event registry (SessionStart, PreToolUse, PostToolUse, Stop, SessionEnd, UserPromptSubmit, PreCompact)
- `hooks/session-start` — Main session init script (longest script, ~350 lines)
- `hooks/scripts/` — All hook dispatch and handler scripts
- `hooks/scripts/lib/` — Shared libraries (state-io, escape-json, json-extract, validate-organism)
- `skills/` — SKILL.md files with YAML frontmatter (16 skills)
- `agents/` — Agent .md files with system prompts (3 agents)
- `commands/` — Slash command .md files (9 commands)
- `context/` — Auto-discovered context files with `keywords:` frontmatter (7 files)
- `tests/` — Bash test suite

### Hook Dispatch
- Single dispatcher per event: `pre-dispatch.sh` (PreToolUse), `post-dispatch.sh` (PostToolUse)
- Dispatchers route by `tool_name` from stdin JSON to sub-handlers
- Only SessionStart is in `hooks.json` (proven reliable). All 6 other events bootstrapped into global `~/.Codex/settings.json` at SessionStart (bug #34573 workaround)
- When bug #34573 is fixed, remove `bootstrap-hooks.sh` and clean up `_cortex_bootstrap` entries from `settings.json`

### State Files
- Sessions: `{project}/.Codex/cortex/sessions/YYYY-WNN/{session_id}.local.md`
- Singletons: `{project}/.Codex/cortex/{type}.local.md` (health, proposals, decisions, cross-session, profile)
- Format: key=value pairs + INI-style sections (`[files_modified]`, `[carry_over]`, `[activity_log]`)
- Read/write via `state-io.sh`: `read_field`, `write_field`, `read_section`, `append_to_section`

### Context Injection
- Context files have `keywords:` as their first line (comma-separated)
- `context-flow.sh` scans all `.md` files in the context directory
- Supports `CORTEX_EXTRA_CONTEXT_DIRS` for domain pack extensibility
- First keyword match wins, breaks out of scan

## Key Patterns
- All scripts: `set -euo pipefail`
- Buffer stdin once: `INPUT=$(cat)` at script top
- JSON field extraction: `extract_json_field` from `lib/json-extract.sh`
- State directory: derived from `git rev-parse --show-toplevel`, NOT `CLAUDE_PROJECT_DIR` (broken)
- Pipe safety: `ls glob | head -1 || true` (pipefail kills on glob miss)
- Grep in conditionals: `if grep -q pattern file; then` (not bare grep under errexit)

## Testing
- `bash tests/run-all.sh` — runs all test suites
- Framework: `tests/lib/test-framework.sh` (assert_equals, assert_contains, assert_file_exists)
- Fixtures: `tests/lib/fixtures.sh` (creates temp dirs, state files, health files)
- Categories: unit/, integration/, edge/, regression/

## Plugin Publishing
<!-- Git workflow (conventional commits, atomic commits) now in ~/.Codex/rules/git-workflow.md -->
- Push to master
- Plugin cache updates on `Codex plugins install cortex@undercurrent-studio`

## Windows Gotchas
- Shell: Git Bash, not cmd/PowerShell
- Paths: Forward slashes in scripts, ENVIRON not `awk -v` for backslash paths
- pipefail: `ls glob | head` needs `|| true`
- `cut -d:` splits on drive letter C: — use `sed` to strip prefix first
- Line endings: `.gitattributes` handles CRLF conversion
