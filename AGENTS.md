# AGENTS.md - Cortex Plugin
<!-- Audited: 2026-07-12 (calibration wave). Review quarterly. -->
<!-- SCOPE: This is the PROJECT-LEVEL instruction file for the Cortex plugin,
     mirrored for Codex. Content is kept in sync with CLAUDE.md IN THE SAME
     COMMIT (R7 coupling rule). Put ONLY plugin-specific rules here. -->

## Project
Claude Code plugin — session recording, carry-over, protection gates, and a condition-gated adaptive tier. Charter: solo RESEARCH INSTRUMENT mapping session-plugin capabilities/limitations (not a product). v4.2 (calibration wave): ground-truth sensors, healer + singletons + legacy chain deleted, real Core/Lab experimental conditions. **FROZEN during the experiment** — no Cortex changes unless a pre-registered stop condition fires (docs/research/2026-07-12-experiment-protocol.md).

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
- `hooks/hooks.json` — ALL 7 events registered natively (SessionStart, PreToolUse, PostToolUse, Stop, SessionEnd, UserPromptSubmit, PreCompact); no flags, no markers
- `hooks/session-start` — Session init: sole creator of the event log; provenance stamp, housekeeping, carry-over, condition-gated adaptive tier (sensory/feedback/synthesis), statusline
- `hooks/scripts/` — Dispatch and handler scripts
- `hooks/scripts/lib/` — Shared libraries (event-io = the state layer + condition resolution, health-trend, housekeeping, escape-json, json-extract)
- `skills/` — SKILL.md files with YAML frontmatter (16 skills)
- `agents/` — Agent .md files with system prompts (4 agents)
- `commands/` — Slash command .md files (10 commands)
- `context/` — Auto-discovered context files with `keywords:` frontmatter (8 keyword-injected of 12 total)
- `tests/` — Bash test suite (38 test scripts: 8 unit / 24 integration / 1 edge / 5 regression; ubuntu + windows CI)

### Hooks, Activation, Conditions
- All 7 events fire natively from `hooks.json`. The bootstrap era is fully deleted (calibration T4/T5): no `--native` flag, no `native-hooks.ok` marker, no `bootstrap-hooks.sh` — deletion happened after verifying zero bootstrap-era settings.json entries remained
- Opt-in sentinel: `.claude/cortex/enabled` FILE gates every entry point — un-opted repos get `{}` and zero writes; `/cortex:setup` is the ONLY opt-in path (grandfathering deleted)
- Conditions (`eio_get_profile` → `core`|`lab`; legacy minimal/standard/strict alias): **core** = recording + carry-over + blocking gates ONLY (zero advisory output, test-enforced); **lab** = core + the frozen adaptive tier. Census rule: blocking/deny + recording run in both; advisory is lab-only
- NO shared mutable identity files: the session id travels explicitly — boot context injection (`Session id: <sid>` line), pre-compact re-injection, skill/command arguments. No sid ⇒ skip the write / render "unavailable"; NEVER guess a sid

### State (v4: append-only event log)
- Per-session log: `{project}/.claude/cortex/sessions/YYYY-WNN/{session_id}.events.log`, lines `epoch|event_type|value` — value is EVERYTHING after the 2nd pipe (may contain pipes); NEVER parse by hand, use event-io helpers
- `append_event` is the ONLY write primitive; `resolve_event_log` (from hook stdin `session_id`) gates every write; session-start is the only log creator; `provenance` stamped once at log creation (condition/plugin/repo/host)
- Everything is derived at read time: `count_events` (with anchor ERE), `last_event`, `list_events`, `eio_last_line_of`, `eio_edits_since_last_commit` (race-safe first-observation commit anchor — use THIS for edits-since-commit, never the naive anchor), `eio_hot_files`, `eio_intervention_report`, `eio_unresolved_items`, `eio_config_get`
- Sensors read GROUND TRUTH: commits enumerate `git log --since=<session anchor>` (command text plays no part; repo-window semantics); test detection is command-position bound; health `commits`/`fix_ratio` are same-provenance git counts
- `health.local.md` is create-once + append-only (healer + session-end strip DELETED; lint-enforced — a HEALTH_FILE rewrite violates in every file). Idle sessions (zero r-edits AND zero window commits) write no row
- Documents (proposals/decisions) stay markdown; the only sanctioned rewrites are the single-writer sites allowlisted in `tests/unit/test-lint-antipatterns.sh`
- Per-project vocabulary lives in `.claude/cortex/config.local` (`architectural_patterns`, `docs_file`, `lessons_file`, `test_command`, `commit_nudge_threshold`) — never hardcode project-specific patterns into hooks

## Key Patterns
- All scripts: `set -euo pipefail`; hooks ALWAYS exit 0 with valid JSON on stdout
- Buffer stdin once: `INPUT=$(cat)` at script top
- JSON field extraction: `extract_json_field` from `lib/json-extract.sh`
- Project dir: derived from `git rev-parse --show-toplevel` (tests override via `CORTEX_PROJECT_DIR_OVERRIDE`/`CORTEX_PROJECT_DIR`), NOT `CLAUDE_PROJECT_DIR` (broken)
- Pipe safety: `ls glob | head -1 || true` (pipefail kills on glob miss)
- Grep in conditionals: `if grep -q pattern file; then` (not bare grep under errexit)
- Windows paths in awk: pass via `ENVIRON`, never `awk -v` (backslash mangling)
- Reminders never emit `decision:block`; blocking gates keep the block JSON shape; reminders are LAB-only
- Event vocabulary is CLOSED (docs/state-files.md) — new types require a spec update
- TDD: RED first, targeted suites per task, full suite pre-push only

## Testing
- `bash tests/run-all.sh` — all suites (~8 min); targeted suite per task during work
- Framework: `tests/lib/test-framework.sh` (assert_eq, assert_contains, assert_file_exists, …)
- Fixtures: `tests/lib/fixtures.sh` (`create_event_log`, `seed_file_edit`, `set_config`, `create_health_file`, `mock_json`); mock git's "clean" behavior enumerates NO commits (a canned log line would forge phantom commit events under the git-derived sensor)
- Categories: unit/, integration/, edge/, regression/; lint scans in `tests/unit/test-lint-antipatterns.sh` keep deleted APIs, retired rewrite idioms, and dead instruction references from coming back; `test-conditions.sh` enforces the zero-advisory core condition

## Plugin Publishing
- Bump version in `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` in the SAME commit as the behavior change (separate commits = stale cache)
- Push to master; cache updates via `claude plugins update cortex@undercurrent-studio` + restart

## Windows Gotchas
- Shell: Git Bash, not cmd/PowerShell
- Paths: Forward slashes in scripts, ENVIRON not `awk -v` for backslash paths
- pipefail: `ls glob | head` needs `|| true`
- `cut -d:` splits on drive letter C: — use `sed` to strip prefix first
- Line endings: `.gitattributes` handles CRLF conversion; readers strip trailing `\r`
