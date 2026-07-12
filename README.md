# Cortex

A Claude Code plugin that works like a **living organism** — 13 biological systems that learn, adapt, protect, and evolve across your coding sessions.

---

## What Does It Actually Do?

Imagine a second brain sitting alongside Claude that:

- **Records** the session's tool calls, tool-driven file edits, and the repo's commits (enumerated from git itself — command text plays no part) in an append-only per-session event log
- **Blocks** dangerous operations before they happen (like using `now()` in a Postgres migration)
- **Injects context** when you mention a topic — keyword-matched context files flow to where they're needed (lab condition)
- **Nudges** you to commit when edits pile up, and validates commit message format (lab condition)
- **Guards** session end so you don't walk away with uncommitted or untested work
- **Watches** the outside world — did CI fail? Did someone push to remote? Any open PRs? (lab condition)
- **Keeps house** on boot — stale temp cleanup, old backups, ancient week-bucket pruning (the self-"healing" subsystem is gone: it only ever repaired damage it caused)
- **Adapts** its behavior based on git-derived health metrics from your recent sessions
- **Grades its own nudges** — every intervention is scored for follow-through, and chronic ignored nudges get flagged for retirement
- **Proposes** its own improvements and waits for your approval
- **Tracks patterns** across sessions — which files keep getting re-edited, what domains you focus on (derived from the logs, no extra tracker files)
- **Audits** your implementation plans before you start building (44 gates with Killer 7 universal core, risk-tiered depth, and domain-specific activation)

All of this happens through bash hooks that fire at specific moments in your Claude Code session. It only activates in projects you explicitly opt in (see Activation).

---

## Setup

### Requirements

- **Claude Code** (CLI or VS Code extension)
- **Git Bash** on your PATH (Windows: comes with [Git for Windows](https://git-scm.com/))
- **GitHub CLI** (`gh`) — optional, but needed for the Sensory system (CI/PR checks)

No Python, no jq, no flock — the hook path is bash + POSIX awk only. (`jq`/`python3` are used as optional accelerators when present.)

### Installation

```bash
claude plugins marketplace add Undercurrent-Studio/undercurrent-cortex
claude plugins install cortex@undercurrent-studio
```

Restart Claude Code. All 7 hook events register natively from the plugin's `hooks.json` — nothing is written into your `~/.claude/settings.json`.

### Activation (opt-in per project)

Cortex is **fully inert until you opt a project in**: in a project without the sentinel file `.claude/cortex/enabled`, every hook exits immediately with `{}` — zero files created, zero state written.

- **Opt in:** run `/cortex:setup` once in the project. It creates the sentinel and validates the workspace. A new session is required for activation.
- **Grandfathering:** a project with real prior Cortex use (an existing `health.local.md` with data rows) gets the sentinel auto-created on first boot.
- **Opt out:** delete `.claude/cortex/enabled` (or the whole `.claude/cortex/` directory).

### Hook Architecture

All 7 events live in the plugin's `hooks.json` and dispatch natively. The bootstrap era is fully deleted (calibration wave): the settings.json injection workaround for a since-fixed [platform bug](https://github.com/anthropics/claude-code/issues/34573), its cleanup script, and the per-session suppression marker are all gone — deletion happened only after verifying, at deletion time, that no settings file anywhere still carried a bootstrap-era hook entry.

### Conditions

Cortex runs in one of two experimental conditions (all hooks fire regardless; the condition gates behavior inside them — this backs the Core/Lab experiment the calibration wave was built for):

| Condition | Behavior |
|-----------|----------|
| `lab` (default) | Core plus the frozen adaptive tier: synthesis tasks, health pulse and trend, interventions (commit nudge, re-edit warning, journal checkpoint, codex reminder), keyword context injection, sensory scan, social patterns |
| `core` | The control: event recording, carry-over, and blocking protection gates ONLY. Zero adaptive output — a core session emits no nudges, warnings, injections, or health display (test-enforced) |

Legacy profile names alias: `minimal`→core, `standard`/`strict`→lab (strict's TDD deny is retired). Set via `CORTEX_PROFILE` env var or `.claude/cortex/profile.local` file in your project.

---

## The 13 Systems

Think of the plugin as a body. Each system has a specific job, and they work together.

### Systems 1-4: The Core Loop

These fire every session and handle the basics.

**1. Nervous System — State Tracking**
Every edit, commit, test run, and tool call is appended to a per-session **append-only event log** (`epoch|event_type|value` lines in weekly buckets). Nothing is ever rewritten; every count the other systems use is derived from the log at read time. This is the structural fix for a whole class of state-corruption bugs — concurrent hooks can only append, and appends are atomic.

*Where:* `post-dispatch.sh` (tool counter), `post-edit-dispatch.sh` (file edits), `post-bash-dispatch.sh` (commits/tests), all through `lib/event-io.sh`
*State:* `.claude/cortex/sessions/YYYY-WNN/{session-id}.events.log`

**2. Immune System — Dangerous Operation Blocking**
Before certain tools execute, the immune system checks if the operation is safe. If not, it blocks it with an explanation.

Examples of what gets blocked:
- `now()` or `CURRENT_DATE` in a migration file (PostgreSQL requires IMMUTABLE functions in partial indexes)
- Overwriting a plan file without reading it first (plan-file-guard prevents accidental destruction)
- Writing implementation code before tests exist (TDD guard, when test files are expected)

*Where:* `pre-dispatch.sh` routes to `migration-linter.sh` + `plan-file-guard.sh` + `tdd-guard.sh`

**3. Circulatory System — Context Injection**
When you mention a topic keyword in your prompt, the circulatory system injects the right context file. Context files use a `keywords:` frontmatter line for auto-discovery — no hardcoded routing needed.

It also detects **decision language** ("I decided", "let's go with", "[decision]") and prompts you to add metadata (rationale, alternatives, confidence) to build a decision journal.

*Where:* `context-flow.sh` reads your prompt, matches keywords, injects from `context/` files

**4. Skeletal System — Session Lifecycle**
The skeleton that everything hangs on. Creates the session's event log at start (the only place a log is ever created), loads health history, runs an async codebase spot-check (drift detector), and writes a v2 health row at session end.

*Where:* `session-start` (SessionStart hook), `drift-detector.sh` (async), `session-end-dispatch.sh` (SessionEnd hook)

---

### Systems 5-8: Intelligence Layer

These add learning, patterns, and guardrails.

**5. Digestive System — Pattern Templates**
When you create a new file, the plugin can inject a real example from the codebase as a convention reference. Instead of guessing the project's patterns, Claude gets a concrete exemplar from a configurable exemplars directory.

*Where:* `pattern-template.sh` (PostToolUse on Write)

**6. Endocrine System — Commit Enforcement**
Nudges you to commit when edits accumulate, and validates conventional commit format (`feat:`, `fix:`, `refactor:`, etc.) on `git commit`. Every nudge fire is recorded and scored for follow-through (System 12).

*Where:* `post-edit-dispatch.sh` (edit counting + nudge), `post-bash-dispatch.sh` (commit format validation)
*Default threshold:* 15 edits since the last commit (override per project via `config.local` `commit_nudge_threshold`)

**7. Memory System — Stop Gates**
When Claude tries to end the session (Stop event), the gates run. Gates are **honest about what they can verify**: only externally-verifiable obligations block; everything else is a non-blocking reminder riding the approve path.

| Gate | What it checks | Class |
|------|---------------|-------|
| 1 | Uncommitted changes to *tracked* files (event-derived count, cross-checked against real `git status`; brand-new untracked files don't count) | **Blocks** |
| 3 | No test run since the *last source edit* — fires only when 4+ distinct files were edited AND a test ecosystem is detectable (otherwise reminds) | **Blocks** |
| 4 | Carry-over items from prior session not addressed | **Blocks** |
| 5 | Stale carry-over unresolved for 3+ sessions | **Blocks** |
| 2 | Docs not updated after architectural changes (only if `architectural_patterns` is configured) | Reminds |
| 6 | Root cause not documented after `fix:` commits | Reminds |
| 7 | Decisions not captured after a plan-mode session | Reminds |
| 8 | Codex review not dispatched on a substantial session (plan mode used, or 4+ files) | Reminds |

Escape hatch: after 2 consecutive blocked stops, the 3rd force-approves — sometimes you genuinely need to stop.

*Where:* `stop-gate.sh` (Stop hook)

**8. Reproductive System — Evolution Proposals**
The `conversation-analyzer` agent watches for recurring patterns across sessions and proposes new rules. These become "proposals" — the raw material that the Growth system (System 11) manages.

*Where:* `agents/conversation-analyzer.md` generates proposals, stored in `.claude/cortex/proposals.local.md`

**8b. Research System — Deep-Dive Agent**
A research analyst agent that can exhaustively investigate any topic — competitors, markets, technology, codebase architecture — and produce a comprehensive written report with strategic recommendations.

What makes it different from a web search:
- **Hypothesis-driven** — formulates what it expects to find *before* searching
- **Browser-equipped** — visits live products via Playwright, takes screenshots, tests user flows
- **Incremental writing** — writes findings to file as it goes, so nothing is lost to context limits
- **Auto-splitting** — when a sub-topic is deep enough, it creates a linked sub-report
- **Adversarial** — actively searches for counter-evidence to its own findings
- **Strategic output** — produces recommendations, opportunity assessments, threat analysis

*Where:* `agents/deep-dive.md`
*Invoke:* `/deep-dive <topic>` or say "do a deep dive on [topic]", "research [topic]", "compare X vs Y"

---

### Systems 9-13: The v3 Expansion

These five systems make the organism truly self-aware and adaptive.

**9. Sensory System — External Awareness**
The organism looks *outside* the session. On session start (and mid-session on relevant keywords), it checks:

| Check | How | What you see |
|-------|-----|-------------|
| Remote commits | `git fetch --dry-run` | "Remote has new commits on origin/master" |
| CI status | `gh run list --limit 3` | "CI FAILED: type-check" |
| Open PRs | `gh pr list --state open` | "3 open PR(s) on this repo" |
| Language detection | File existence checks | "Python project detected." / "Go project detected." / "Rust project detected." |

Mid-session checks have a 5-minute cooldown.

*Where:* `sensory-check.sh` (called by `session-start` and `context-flow.sh`)

**10. Housekeeping (the healer is dead)**
The "Healing/Repair System" was DELETED in the calibration wave — its verdict after live forensics: it never repaired damage it (or its sibling writer) didn't cause, and its rebuild path ate data. `health.local.md` is create-once + append-only now, lint-enforced; the only writers left are header creation and row append. What survives is the hygiene with a clean record, silent, on every boot:

| Check | What it does |
|-------|--------------|
| Stale temp files | Deletes `*.tmp.*` files older than 60 minutes |
| Old state backups | Removes backups older than 7 days |
| Ancient week buckets | Removes `sessions/YYYY-WNN/` dirs older than 90 days (never the current week) |

*Where:* `lib/housekeeping.sh` (sourced by `session-start`)

**11. Growth/Adaptation System — Proposal Lifecycle**
The Reproductive system (System 8) creates proposals. The Growth system manages their lifecycle:

- **Review:** via `/analyze-session` — boot surfacing retired in the calibration wave (proposal review is a maintainer act, not treatment; the pending queue rides until the experiment's verdict)
- **Approve:** Say "approve proposal" during a review — safe types auto-apply (lessons, context keywords, skill updates). Risky types (hook rules) get flagged for manual review
- **Reject:** Say "reject proposal" — status set to rejected
- **Duplicate detection:** Won't apply content that already exists in the target file

6 proposal types:

| Type | Target | Apply method |
|------|--------|-------------|
| `lesson` | `tasks/lessons.md` | Append |
| `context-keyword` | `context-flow.sh` | Append |
| `skill-update` | A skill file | Append |
| `claude-md-amendment` | `CLAUDE.md` | Append |
| `context-file` | New context file | Create |
| `hook-rule` | A hook script | **Manual review only** |

*Where:* `apply-proposal.sh` (called by `context-flow.sh` on approve/reject keywords)

**12. Feedback Loop System — Health-Driven Behavior**
The organism reads its own health history and adjusts behavior — and since v4, the metrics are **git-derived and externally verifiable** (fix-commit ratio, reworked files), never self-graded. Trend verdicts require at least 10 non-idle sessions of data and use medians, not means.

| Health signal | Behavioral change |
|--------------|------------------|
| Median fix-ratio rising (last 5 vs prior 5, by more than 0.15) | Switch to **cautious mode** — adds a "plan before acting" reminder on the first prompt |
| Recurrent rework (3+ reworked files in 3 of the last 5 sessions) | Switch to **cautious mode** |
| Everything healthy (or not enough data yet) | Normal mode, default thresholds |

Cautious mode doesn't block anything — it injects one gentle reminder per session.

The loop also **grades itself**: every nudge it fires (commit nudge, re-edit warning, journal checkpoint, cautious-mode injection, Codex reminder) is logged as an `intervention` event and scored at read time for follow-through — did a commit actually land after the nudge? Any nudge fired 10+ times with under 20% follow-through is surfaced as a retirement candidate every 10th session. A feedback system that can't tell whether its feedback works is decoration; this one keeps receipts.

*Where:* `session-start` computes mode from `lib/health-trend.sh`; `lib/event-io.sh` (`eio_intervention_report`) scores follow-through; `/status` and the statusline display the rates

**13. Social/Communication System — Cross-Session Intelligence**
Patterns that only emerge across multiple sessions:

- **Domain tagging:** Each session gets a domain tag derived from the most-edited top-level directory (ties or fewer than 3 edits → `mixed`; none → `idle`). Written into the health row.
- **Pattern detection** (runs at session start):
  - *Domain clustering:* "Last 3 of 5 sessions were all scoring work" — surfaces focus patterns
  - *Session length trends:* Compares recent session durations
  - *Hot files:* Files edited in 4+ distinct sessions get called out — **derived directly from the event logs at read time** (no tracker file to corrupt or prune)

*Where:* `session-end-dispatch.sh` (writes the health row) → `session-start` + `lib/event-io.sh` (`eio_hot_files`) analyze at boot

---

## Enforced vs Advisory — What Actually Blocks

The honest ledger. "Blocks" means a hard deny or a blocked Stop; everything else is a reminder or derived information — valuable, but it will never stand in your way.

| Mechanism | Class | Notes |
|-----------|-------|-------|
| Stop Gate 1 — uncommitted work | **Blocks** | Tracked changes only (untracked-only sessions pass); cross-checked against `git status` |
| Stop Gate 3 — tests since last source edit | **Blocks** | Only with 4+ files edited AND a detectable test ecosystem; otherwise reminds |
| Stop Gates 4/5 — carry-over / stale carry-over | **Blocks** | Escape hatch after 2 consecutive blocks |
| Migration linter — `now()` etc. in migrations | **Blocks** | PreToolUse deny |
| Plan-file guard — overwriting an existing plan | **Blocks once** | Same-path retry allowed (deliberate rewrite) |
| TDD guard | Reminds (lab only) | Once per session; the old strict-profile deny is retired |
| Stop Gates 2/6/7 — docs / root-cause / decisions | Reminds (lab only) | Never emit a block |
| Codex-review gate | Reminds (lab only) | Promotion to blocking runs through follow-through data, not fiat |
| Commit nudge, re-edit warning, journal checkpoint | Reminds (lab only) | Each fire is scored for follow-through |
| Cautious mode | Reminds (lab only) | One injection per session |
| Health trend, domain tags, hot files, intervention rates | Derives (lab display) | Read-time computation from logs; drives nothing directly |

Everything in the "Blocks" class runs in BOTH conditions (protection is not treatment); every "Reminds" row is lab-only — a core session is provably silent (see `tests/integration/test-conditions.sh`).

## Statusline

The organism displays its pulse at the start of every session and on-demand via `/status` — two lines, plus a third when intervention follow-through data exists:

```
✏️  3 edits · 📦 1 commits · 🧪✅ · 📄❌
💚 thriving │ 🧠 62 absorbed │ 🧬 1 mutations queued │ ↗ improving
🔁 interventions: nudge 4/12 · checkpoint 2/3
```

### Line 1 — Session Activity

| Icon | Meaning |
|------|---------|
| ✏️  `N edits` | Files edited since last commit (resets on commit) |
| 📦 `N commits` | Commits made this session |
| 🧪 ✅/❌ | Whether tests have been run this session |
| 📄 ✅/❌ | Whether documentation was updated this session |

### Line 2 — Organism Health

| Element | Meaning |
|---------|---------|
| 💚 `thriving` | Git-derived trend is improving (fix-ratio falling, no rework spikes) |
| 💛 `adapting` | Normal operation — stable trend, or not enough data yet |
| 🧡 `cautious` | Feedback system activated cautious mode (rising fix-ratio or recurrent rework) |
| ❤️‍🩹 `stressed` | Health trend is degrading — extra care needed |
| 🧠 `N absorbed` | Total lessons in `tasks/lessons.md` (cumulative knowledge base) |
| 🧬 `N mutations queued` | Pending evolution proposals waiting for approval |
| ↗/→/↘ `trend` | Trend verdict from ≥10 sessions of git-derived medians; below that it shows the honest raw count: `📊 6 sessions tracked — trend at 10` |

### Line 3 — Intervention Follow-Through (only when data exists)

`followed/fired` per nudge kind over the last 30 days — `nudge 4/12` means the commit nudge fired 12 times and was actually followed by a commit 4 times. The feedback loop grading its own advice.

---

## Components

### 16 Skills

| Layer | Skills |
|-------|--------|
| **Mission** | security-posture, data-integrity |
| **Domain** | database-query-safety, migration-safety |
| **Methodology** | tdd-enforcement, systematic-debugging |
| **Workflow** | feature-design-flow, pre-commit-checklist, deploy-readiness, plan-audit, plan-estimation |
| **Learning** | session-start, session-end, pattern-escalation |
| **Diagnostics** | validate-refs, graph |

Skills are invoked via `/cortex:<skill-name>` (e.g., `/cortex:plan-audit`). Each skill is a Markdown file with YAML frontmatter that defines its name, description, and trigger conditions.

#### Plan Audit (the highest-value skill)

`/cortex:plan-audit` runs a layered 44-gate audit on implementation plans with risk-tiered depth:

**Irreducible Core** (every plan, always first):
1. Show the Math — all resource estimates computed, not asserted
2. What Breaks If This Fails — premortem + blast radius
3. Prove the Data Exists — cite evidence for every external data assumption

**Killer 7** (every plan, all tiers):
Premortem, Show the Math, Source Evidence, Success Criteria, Blast Radius, Lessons Check, AI-ism Smell Test

**Risk tiers** control depth:
- **Tier S** (scoring, auth, pipeline architecture): 20-30 gates, 25-35 min
- **Tier A** (new features, data sources, API routes): 12-18 gates, 15-20 min
- **Tier B** (bug fixes, multi-file refactors): 8-12 gates, 10-15 min
- **Tier C** (typos, config tweaks): Killer 7 only, 5-10 min

**44 gates** organized into 3 sequential phases (Understanding → Evaluation → Holistic), covering: silent failures, data integrity, security, migrations, math, caching, frontend, architecture, estimates, validation depth, documentation, commit strategy, quality, references, lessons, decisions, journal, data source provenance, resource modeling, verification fidelity, idempotency, race conditions, partial failure, cardinality, observability, freshness contracts, upstream stability, implicit coupling, downstream impact, rollback safety, environment divergence, attack surface, monotonicity, calendar awareness, type coercion, success criteria, blast radius, premortem, invariant preservation, precedent check, ripple effects, AI-ism detection, and product-value alignment.

Gate definitions live in `context/plan-audit-gates.md`. AI-ism taxonomy (87 patterns + 8 anti-patterns) in `context/ai-ism-taxonomy.md`. Meta-principles and research evidence in `context/plan-audit-reference.md`.

### 7 Hook Events (all native in `hooks.json`)

| Event | Script | What |
|-------|--------|------|
| SessionStart | session-start (+ async drift-detector.sh) | Create event log, healing, carry-over, sensory, feedback, statusline |
| PreToolUse | pre-dispatch.sh | Routes to migration-linter + plan-file-guard + tdd-guard |
| PostToolUse | post-dispatch.sh | Tool counter + routes to edit/bash tracking + pattern templates |
| UserPromptSubmit | context-flow.sh | Context injection, decision detection, cautious-mode injection |
| Stop | stop-gate.sh | Honest stop gates (4 blocking + 4 reminders + escape hatch) |
| PreCompact | pre-compact.sh | Preserve carry-over |
| SessionEnd | session-end-dispatch.sh | Health row v2 (git-derived metrics, domain tag) |

### 4 Agents

| Agent | What | Invoke |
|-------|------|--------|
| conversation-analyzer | Detects correction patterns across sessions, proposes evolution rules | `/analyze-session` |
| deep-dive | Exhaustive research with browser, hypothesis-driven methodology, strategic reports | `/deep-dive <topic>` |
| code-reviewer | 3-pass code review (bug/logic, security, conventions) with confidence scoring >=80 | `/code-review` |
| memory-synthesis | Curates collaboration patterns and workflows — dedup, merge, staleness flags, index sync | `/curate-memory` |

### 10 Commands

| Command | What it does |
|---------|-------------|
| `/status` | Display the organism statusline — session activity, health pulse, lessons absorbed, pending mutations |
| `/curate-memory` | Run the memory-synthesis agent — curate collaboration patterns, workflows, and file organization |
| `/session-end` | Write journal entry, carry-over, reasoning audit, health metrics |
| `/deep-dive <topic>` | Launch exhaustive research — produces a comprehensive written report |
| `/analyze-session` | Deep adaptive immunity scan (triggered by corrections or reasoning misses) |
| `/review-decisions` | Review decisions from 7-14 days ago for validation |
| `/setup` | Initialize project workspace — create skeleton files, verify Cortex installation, display profile |
| `/code-review` | 3-pass code review — bug/logic, security, project conventions with confidence scoring |
| `/create-skill` | Interactive scaffold for new skills — frontmatter, templates, optional context file wiring |
| `/uninstall` | Guide for cleanly removing Cortex — bootstrap entries, state files, plugin registration |

### State Files

All state lives in `.claude/cortex/` (gitignored):

| Path | Purpose |
|------|---------|
| `cortex/sessions/YYYY-WNN/{session-id}.events.log` | **The source of truth**: per-session append-only event log (`epoch\|event_type\|value`), weekly buckets. Every count is derived from it at read time — no stored counters anywhere |
| `cortex/health.local.md` | Historical: one v2 row per session (git-derived metrics + labeled self-report column). Trends computed on read |
| `cortex/proposals.local.md` | Pending/applied/rejected evolution proposals |
| `cortex/decisions.local.md` | Decision journal entries with metadata (category, reversibility, confidence) |
| `cortex/config.local` | Optional per-project vocabulary: `architectural_patterns`, `docs_file`, `lessons_file`, `test_command`, `commit_nudge_threshold` |
| `cortex/enabled` | The opt-in sentinel (created by `/cortex:setup`) — without it every hook is inert |
| `cortex/profile.local` | Condition override (`core`/`lab`; legacy `minimal`/`standard`/`strict` alias) |

No shared mutable identity files remain: `native-hooks.ok` and `current-session.id` were deleted in the calibration wave (a guest boot clobbered both in one week — the session id now travels explicitly through the boot context injection, pre-compact re-injection, and skill/command arguments; leftover files from older versions are ignored).

### 12 Context Files

8 keyword-injected files (via `context-flow.sh`) + 3 plan-audit reference files (loaded on demand via `@context/`) + 1 index.

**Keyword-injected** (auto-discovery via `keywords:` frontmatter):

| File | Keywords |
|------|----------|
| deploy-readiness.md | deploy, vercel, go live, push to prod, production, ship it |
| testing-conventions.md | vitest, test suite, write test, add test, run test, fix test, coverage |
| math-review.md | formula, statistics, probability, monte carlo, sigmoid, z-score, distribution, likelihood, half-life, ornstein, mean reversion, … |
| typescript-discipline.md | typescript, type error, tsc, nouncheckedindexedaccess, type guard, as never, use client |
| python-patterns.md | python, pyproject.toml, venv, pytest, django, flask, fastapi, poetry, ruff, mypy, pydantic |
| go-patterns.md | golang, go.mod, goroutine, go.sum, cobra, fiber |
| rust-patterns.md | rustc, cargo.toml, lifetime, tokio, async-std, serde, clippy, rust-lang |
| synthesis-memory.md | collaboration pattern, workflow pattern, synthesis, curate memory, how we work, … |

**Plan-audit reference** (loaded via `@context/` when plan-audit skill fires):

| File | Contents |
|------|----------|
| plan-audit-gates.md | Full 44-gate catalog with all checklist questions |
| ai-ism-taxonomy.md | 87 AI-ism patterns, 8 anti-patterns with code examples, detection heuristics |
| plan-audit-reference.md | 15 meta-principles, cognitive bias mitigations, gaming countermeasures, cross-domain research evidence |

**Index:** `_index.md` — master index of keyword-injected context files

---

## Domain Packs

Cortex is extensible via **domain packs** — separate plugins that add project-specific skills, agents, commands, and context files.

Context files with `keywords:` frontmatter are auto-discovered when placed in directories listed in the `CORTEX_EXTRA_CONTEXT_DIRS` environment variable or the `.claude/cortex-context-dirs.local` config file.

To create a domain pack:
1. Create a new plugin with `skills/`, `agents/`, `commands/`, and `context/` directories
2. Add a SessionStart hook that registers the context directory
3. Install alongside Cortex — both plugins' skills/agents/commands are available

---

## How to Extend

| Task | How |
|------|-----|
| Add a skill | Create `skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`, `version`) |
| Add a context file | Create in `context/` with `keywords:` as the first line (comma-separated) |
| Add a hook (PreToolUse/PostToolUse) | Add routing in the dispatcher script (`pre-dispatch.sh` or `post-dispatch.sh`) |
| Add a command | Create `commands/<name>.md` with YAML frontmatter (`name`, `description`) |
| Add an agent | Create `agents/<name>.md` with frontmatter (`name`, `description`, `tools`) |

---

## Test Suite

41 test scripts (900+ assertions) organized by type, run on every push against **ubuntu and windows** CI legs:

```text
tests/
  run-all.sh                              # Test runner
  unit/                                   # 9 — event-io, state-io, json-extract, escape-json, validate-organism, lint scans, fixtures, mocks, hooks.json contract
  integration/                            # one per hook script + opt-in gate, singleton-free, conditions, old-cache overlap, hook contract, profiles
  edge/                                   # Windows paths
  regression/                             # health dedup, pipefail glob, concurrent appends, session-start perf budget, timeout contract
  lib/                                    # 3 shared helpers — fixtures, mocks, test framework
```

Run all tests: `bash tests/run-all.sh`

---

## File Structure

```text
cortex/
  .claude-plugin/
    plugin.json                            # Plugin manifest (name, version)
    marketplace.json                       # Marketplace listing metadata
  hooks/
    hooks.json                             # ALL 7 events, native registration
    session-start                          # SessionStart: event-log creation + housekeeping + carry-over + condition-gated adaptive tier
    scripts/
      pre-dispatch.sh                      # PreToolUse dispatcher
      post-dispatch.sh                     # PostToolUse dispatcher (tool counter + routing)
      post-edit-dispatch.sh                # Edit tracking + commit nudge + re-edit warning
      post-bash-dispatch.sh                # Commit/test/codex detection + commit format validation
      migration-linter.sh                  # Block now() in migrations
      plan-file-guard.sh                   # Block plan overwrites (once per path)
      tdd-guard.sh                         # TDD reminder (lab condition only; the strict deny is retired)
      context-flow.sh                      # Keyword context + decisions + cautious mode
      drift-detector.sh                    # Async codebase spot-checks
      pattern-template.sh                  # Convention exemplar injection
      stop-gate.sh                         # Honest stop gates (blocking + reminders)
      sensory-check.sh                     # External awareness (git, CI, PRs)
      apply-proposal.sh                    # Proposal approve/reject lifecycle
      pre-compact.sh                       # Preserve carry-over on context compaction
      session-end-dispatch.sh              # Health row v2 (git-derived metrics + domain tag)
      statusline.sh                        # Organism statusline renderer (2-3 lines)
      lib/
        escape-json.sh                     # JSON string escaping (control-char safe)
        json-extract.sh                    # Lightweight JSON field extraction
        event-io.sh                        # THE state layer: append_event + read-time derivations + condition resolution
        health-trend.sh                    # Read-time trend medians from v2 health rows
        housekeeping.sh                    # Boot hygiene: temp/backup cleanup + week-dir pruning (the healer is deleted)
  skills/             # 16 skill directories
  commands/           # 10 slash commands
  agents/             # conversation-analyzer + deep-dive + code-reviewer + memory-synthesis
  context/            # 12 context files (8 keyword-matched + 3 plan-audit reference + 1 index)
  tests/              # 41 test scripts + 3 helpers (run-all.sh); ubuntu + windows CI
```

---

## Version History

- **4.0.0** — The event-log rearchitecture (v4 redesign complete). State is an append-only per-session event log — the mutable state file, its `write_field` sed primitive (two proven corruption bugs), and the lost-update race are structurally gone; every count derives from the log at read time. All 7 hook events register natively from `hooks.json` (settings.json bootstrap retired; stale entries inert via a per-session marker). Activation is opt-in per project (`/cortex:setup` → `.claude/cortex/enabled`; un-opted repos are fully inert). Health rows v2 carry git-derived metrics (fix-ratio, rework, real test results) — self-reported tags demoted to a labeled column that drives nothing; trend verdicts need ≥10 sessions and use medians. Gates are honest: verify-where-cheap blocks (uncommitted, tests-after-last-source-edit, carry-over), everything else reminds. The feedback loop scores its own nudges for follow-through and flags chronic ignored ones for retirement. Per-language test detection (vitest/pytest/go/cargo + config override). Undercurrent-specific vocabulary moved to per-project `config.local`. Cross-session hot files derived from logs (tracker file retired). Windows + ubuntu CI. Lint scans keep the mutation idioms dead. **v4.2 deletion calendar:** `bootstrap-hooks.sh`, the v3.7 migration chain, the legacy `*.local.md` carry-over reader, and opt-in grandfathering all get deleted in 4.2.
- **3.13.2** — Plan-audit v1.0: layered 44-gate architecture (was 18 flat gates). Irreducible Core (3 questions on every plan). Killer 7 universal gates. Risk-tiered depth (Tier S/A/B/C). 26 new gates covering idempotency, race conditions, partial failure, blast radius, observability, type coercion, and more. 5 existing gates enhanced (mandatory arithmetic, source evidence, data exposure, staleness windows, full-universe scaling). 3 new context files: `plan-audit-gates.md` (44 gate definitions), `ai-ism-taxonomy.md` (87 patterns + 8 anti-patterns; earlier README versions misstated 122), `plan-audit-reference.md` (15 meta-principles + research evidence).
- **3.12.1** — Session-start statusline now displays model metadata (model name, reasoning effort, context window) as a third line.
- **3.12.0** — Fix TDD guard deny format (strict mode was silently broken — wrong JSON format for Claude Code hook API). Sync all documentation counts and versions. Fix 5 stale references from v3.7 migration. Add missing version frontmatter to graph and validate-refs skills. Clarify superpowers as optional integration.
- **3.11.0** — Memory enforcement: plan-audit gates 16-18 (lessons surfaced, decision pre-capture, journal pre-entry). Stop-gate Gate 7 (decision capture after plan-mode sessions). Decision journal integration with context-flow. 18-gate plan-audit (was 13).
- **3.10.0** — Graph skill (Mermaid diagram of reference knowledge graph). Validate-refs skill (knowledge graph health checks). Plan-audit gates 14-15 (reference coverage + freshness).
- **3.9.3** — Fix session tracking undercounting (~60% of sessions invisible). Session-end skill now calls `session-end-dispatch.sh` directly (SessionEnd hook was only firing ~40% of the time). Session-start writes `current-session.id` for correct state file resolution. Zero-metric sessions tagged `topology=idle` instead of dropped. Rolling averages exclude idle sessions. Conversation analyzer counts session files, not health rows. Fixed `grep -c || echo 0` double-output bug corrupting health rows. Cleaned stale hook registrations from `settings.json`.
- **3.9.2** — Fix 14 audit findings: stale v3.7 path references, unquoted variables, debug noise, superpowers fallbacks, TodoWrite removal, missing version fields, redundant grep, README count corrections, uninstall command, CI pipeline.
- **3.9.1** — Fix keyword collisions in language detection (Go: `go` → `golang`, removed `gin`/`chan`/`defer`; Rust: `rust` → `rustc`/`rust-lang`, removed `borrow`). 4 collision avoidance tests.
- **3.9.0** — Phase 2: 3-pass code review agent (bug/logic, security, conventions with confidence scoring). Language detection (Python/Go/Rust) in sensory system + context files. `/create-skill` command with interactive scaffold + skill authoring guide.
- **3.7.1** — Fix stop-gate escape hatch with dedicated counter file (decoupled from session state resolution). Git status verification in Gate 1 filters gitignored files. `post-edit-dispatch.sh` uses `git check-ignore -q` to prevent false edit counts.
- **3.7.0** — State file directory reorganization: flat files → `cortex/sessions/YYYY-WNN/` weekly buckets. Singletons to `cortex/` subdir. Two-phase migration with `.migrated-v3.7` sentinel. `resolve_state_file()` searches both layouts for backwards compatibility.
- **3.6.1** — Fix stop-gate escape hatch (debug logging + recency filter for state file resolution). Fix health dedup ordering (zero-metric sessions no longer burn the dedup flag). Fix cross-session tracking (runs before zero-metric exit). Test fixture updates (7 failures → 0).
- **3.6.0** — Genericized reference files for public distribution. Hook profiles (`CORTEX_PROFILE=minimal|standard|strict`). Blog post outline.
- **3.5.0** — Bootstrap targets global `~/.claude/settings.json` (proven reliable) instead of project-level `settings.local.json`. Cleans up stale project-level entries on upgrade.
- **3.4.x** — Wire up `tool_calls_count` increment in post-dispatch (was tracked but never incremented). Bootstrap all 6 non-SessionStart events with smart idempotency.
- **3.3.0** — Comprehensive audit fixes: state file resolution, health dedup, legacy migration, `hooks.json` cleanup.
- **3.2.0** — Organism statusline (visible in chat), session-end statusline diff.
- **3.1.0** — Genericized for any project. Domain pack extraction. Hook bootstrap system. Context auto-discovery via keywords frontmatter. Platform-agnostic bash paths.
- **3.0.0** — 13 systems: added sensory, healing, growth, feedback, social.
- **2.1.0** — Dispatcher architecture, global plugin (no project guards), Windows path fixes.
- **2.0.0** — Full organism: skills, hooks, agents, context files, commands.
- **1.0.0** — Initial scaffold (session-start hook only).

---

## Updating

The plugin is installed from GitHub via Claude Code's marketplace system. To update:

```bash
claude plugins marketplace update undercurrent-studio   # Refresh index from GitHub
claude plugins update cortex@undercurrent-studio         # Install new version
```

These are **two separate operations** — `plugins update` only checks the cached index. Always run both.

---

## Uninstalling

Simple since v4 — there is no settings.json surgery to do:

1. `claude plugins uninstall cortex@undercurrent-studio`
2. Per project, delete `.claude/cortex/` (state) — or just delete the `enabled` sentinel to keep the history but deactivate.

`/cortex:uninstall` walks you through it, including cleanup of any bootstrap-era leftovers from pre-4.0 installs.

---

## License

MIT. See [LICENSE](LICENSE).
