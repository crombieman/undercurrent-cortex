---
name: setup
description: Initialize a project workspace with Cortex skeleton files and verify plugin installation status
---

# Setup

Initialize a project workspace for Cortex. Idempotent — safe to run multiple times. Never overwrites existing files.

**Setup is the opt-in act**: Cortex hooks are inert in every project until this command creates the activation sentinel (step 0). Un-opted repos get zero state files and zero hook behavior.

## Steps

### 0. Activate Cortex for this project (the opt-in sentinel)

Check for `.claude/cortex/enabled`:
- If present: report "Cortex already ACTIVATED for this project (since <first line's timestamp>)."
- If missing: run
  `mkdir -p .claude/cortex && printf 'enabled %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .claude/cortex/enabled`
  then report: "Cortex ACTIVATED for this project. **Start a new session** — hooks begin tracking at the next SessionStart (mid-session activation is inert by design)."

### 1. Detect environment

Run these checks and print findings:
- `uname -a` — OS and architecture
- `bash --version | head -1` — bash version
- `git --version` — git version
- `python3 --version 2>/dev/null || echo "python3 not found (optional)"` — python3 (optional — accelerates JSON parsing; pure-bash fallback covers everything)
- `jq --version 2>/dev/null || echo "jq not found (optional)"` — jq (optional, used for JSON parsing)

### 2. Verify CLAUDE.md

Check if `CLAUDE.md` exists in the project root.
- If present: "CLAUDE.md found."
- If missing: Warn — "No CLAUDE.md found. Create one with project-specific instructions for Claude Code."

### 3. Create skeleton files

For each file, check existence first. Only create if missing — **never overwrite**.

| File | Content if created |
|------|-------------------|
| `MEMORY.md` | `# Project Memory` with sections: `## About [User]`, `## Goals`, `## Preferences`, `## Active Projects`, `## Lessons Learned`, `## Key Decisions` |
| `tasks/todo.md` | `# Tasks` with empty checklist placeholder |
| `tasks/lessons.md` | `# Lessons Learned` with template comment |
| `memory/` directory | Create empty directory |
| `documentation.md` | `# Documentation` with sections: `## Architecture`, `## Schema`, `## API Routes`, `## Patterns`, `## Environment Variables` |

For each item, report: "Created [file]" or "Already exists: [file]".

### 4. Verify Cortex installation

Run: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/statusline.sh"`
- If it produces output: display the statusline
- If it produces nothing and step 0 just created the sentinel: expected — the statusline has no session data until the next session starts. Report that.
- If it fails outright: warn — "Statusline unavailable. Verify the plugin is installed (`claude plugins list`) and start a new session."

### 5. Display condition

Check the current Cortex condition and explain:
- Read `CORTEX_PROFILE` env var or `.claude/cortex/profile.local`
- Display current condition (default: `lab`)
- Explain the two conditions (calibration wave — these back the Core/Lab experiment):
  - **core** — Control: event recording, carry-over, and blocking protection gates ONLY. Zero adaptive output — no nudges, warnings, context injection, health display, or synthesis instructions.
  - **lab** — Core plus the frozen adaptive tier: synthesis tasks, health pulse, interventions (commit nudge, re-edit warning, journal checkpoint, codex reminder), keyword context injection, sensory scan.
  - Legacy names alias: `minimal`→core, `standard`/`strict`→lab (strict's TDD deny is retired).
- To change: `export CORTEX_PROFILE=core` or write the condition name to `.claude/cortex/profile.local`

### 6. Print summary

List:
- Files created (count)
- Files already existing (count)
- Any warnings (missing CLAUDE.md, missing python3, etc.)
- Next steps: "Start working. Cortex will track your session, enforce quality gates, and learn from corrections."
