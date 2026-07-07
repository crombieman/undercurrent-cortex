# Cortex

A Claude Code plugin that works like a **living organism** — 13 biological systems that learn, adapt, protect, and evolve across your coding sessions.

---

## What Does It Actually Do?

Imagine a second brain sitting alongside Claude that:

- **Remembers** every file you edit, every commit you make, every tool call
- **Blocks** dangerous operations before they happen (like using `now()` in a Postgres migration)
- **Injects context** when you mention a topic — keyword-matched context files flow to where they're needed
- **Nudges** you to commit when edits pile up, and validates commit message format
- **Guards** session end so you don't walk away with uncommitted work or stale docs
- **Watches** the outside world — did CI fail? Did someone push to remote? Any open PRs?
- **Heals** itself — corrupted state files get repaired automatically on boot
- **Adapts** its behavior based on your recent session quality
- **Proposes** its own improvements and waits for your approval
- **Tracks patterns** across sessions — which files keep getting re-edited, what domains you focus on
- **Audits** your implementation plans before you start building (44 gates with Killer 7 universal core, risk-tiered depth, and domain-specific activation)

All of this happens through bash hooks that fire at specific moments in your Claude Code session.

---

## Setup

### Requirements

- **Claude Code** (CLI or VS Code extension)
- **Git Bash** on your PATH (Windows: comes with [Git for Windows](https://git-scm.com/))
- **Python 3** on your PATH (needed for bootstrap and JSON manipulation)
- **GitHub CLI** (`gh`) — optional, but needed for the Sensory system (CI/PR checks)

### Installation

```bash
claude plugins marketplace add Undercurrent-Studio/undercurrent-cortex
claude plugins install cortex@undercurrent-studio
```

Restart Claude Code. On first session start, the plugin bootstraps all hook events into your global `~/.claude/settings.json` automatically.

### Hook Architecture

Cortex uses a two-tier hook dispatch system due to a [known bug](https://github.com/anthropics/claude-code/issues/34573) where plugin `hooks.json` command hooks are unreliable for most events:

| Tier | Location | Events | Why |
|------|----------|--------|-----|
| **hooks.json** | Plugin manifest | SessionStart only | Proven working; serves as the bootstrap's lifeline |
| **Global settings.json** | `~/.claude/settings.json` | PreToolUse, PostToolUse, PreCompact, Stop, SessionEnd, UserPromptSubmit | Bootstrapped on every session start; the only location proven to reliably fire hooks |

The `bootstrap-hooks.sh` script runs on every SessionStart and:
1. Injects 6 hook events into `~/.claude/settings.json` (idempotent — skips if already correct)
2. Replaces stale entries when the plugin version changes (path-aware)
3. Cleans up orphan entries from old plugin versions (matches by script name pattern)
4. Cleans up legacy entries from the old project-level `settings.local.json`

All bootstrapped entries are tagged with `"_cortex_bootstrap": true` for identification.

### Profiles

Cortex supports three hook profiles that control which systems are active:

| Profile | Events Injected | Use Case |
|---------|----------------|----------|
| `standard` (default) | All 6 events | Full organism — recommended for most projects |
| `minimal` | PreToolUse, PostToolUse, SessionEnd only | Lightweight — enforcement + state tracking only |
| `strict` | All 6 events + proposals auto-surfaced | Full organism with more aggressive adaptation |

Set via `CORTEX_PROFILE` env var or `.claude/cortex/profile.local` file in your project.

---

## The 13 Systems

Think of the plugin as a body. Each system has a specific job, and they work together.

### Systems 1-4: The Core Loop

These fire every session and handle the basics.

**1. Nervous System — State Tracking**
Every edit, commit, and tool call gets counted in a session-scoped state file. The nervous system is how the organism "feels" what's happening — it's the raw sensory data that other systems read.

*Where:* `post-dispatch.sh` (universal counter), `post-edit-dispatch.sh`, `post-bash-dispatch.sh`
*State:* `edits_since_last_commit`, `commits_count`, `tool_calls_count`, `[files_modified]` section

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
The skeleton that everything hangs on. Initializes state at session start, loads health history, runs an async codebase spot-check (drift detector), and writes a 12-field health row at session end.

*Where:* `session-start` (SessionStart hook), `drift-detector.sh` (async), `session-end-dispatch.sh` (SessionEnd hook)

---

### Systems 5-8: Intelligence Layer

These add learning, patterns, and guardrails.

**5. Digestive System — Pattern Templates**
When you create a new file, the plugin can inject a real example from the codebase as a convention reference. Instead of guessing the project's patterns, Claude gets a concrete exemplar from a configurable exemplars directory.

*Where:* `pattern-template.sh` (PostToolUse on Write)

**6. Endocrine System — Commit Enforcement**
Nudges you to commit when edits accumulate. The threshold is dynamic — the Feedback system (System 12) can raise or lower it based on your recent session health. Also validates conventional commit format (`feat:`, `fix:`, `refactor:`, etc.) on `git commit`.

*Where:* `post-edit-dispatch.sh` (edit counting + nudge), `post-bash-dispatch.sh` (commit format validation)
*Default threshold:* 15 edits (adjustable by Feedback system)

**7. Memory System — Stop Gates**
When Claude tries to end the session (Stop event), 7 gates must pass:

| Gate | What it checks | When it fires |
|------|---------------|---------------|
| 1 | Uncommitted changes | Always (with git status self-heal) |
| 2 | `documentation.md` not updated after architectural changes | When 3+ files modified, touching scoring/pipeline/signals/etc. |
| 3 | Tests not run after modifying TypeScript files | When 3+ files modified, touching `.ts`/`.tsx` |
| 4 | Carry-over items from prior session not addressed | When carry-over exists in state |
| 5 | Stale carry-over unresolved for 3+ sessions | When `carry_over_age >= 3` |
| 6 | Root cause not documented after `fix:` commits | When session has `fix:` commits (standard/strict profiles) |
| 7 | Decisions not captured after plan-mode session | When plan mode was used and commits were made |

If a gate fails, the session continues with a warning. After 2 consecutive blocks on the same gate, an escape hatch opens — sometimes you genuinely need to stop.

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

**10. Healing/Repair System — Self-Recovery**
On every boot, the organism checks its own state files for damage and fixes what it finds:

| Check | What it fixes |
|-------|--------------|
| Corrupted state file | Backs up and continues |
| Out-of-range counters | Clamps to valid range |
| Bloated file lists | Deduplicates when >200 entries |
| Missing health header | Rebuilds summary fields |
| Oversized health log | Prunes to last 100 rows |
| Missing file separators | Adds `---` to proposals/decisions files |
| Stale temp files | Deletes `*.tmp.*` files older than 60 minutes |
| Old state backups | Removes backups older than 7 days |
| Bloated cross-session file | Prunes entries older than 30 days |

*Where:* `lib/validate-organism.sh` (sourced by `session-start`)

**11. Growth/Adaptation System — Proposal Lifecycle**
The Reproductive system (System 8) creates proposals. The Growth system manages their lifecycle:

- **Surfacing:** On each session start, pending proposals are shown with increasing urgency
- **Approve:** Say "approve proposal" — safe types auto-apply (lessons, context keywords, skill updates). Risky types (hook rules) get flagged for manual review
- **Reject:** Say "reject proposal" — status set to rejected, won't surface again
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
The organism reads its own health history and adjusts behavior:

| Health signal | Behavioral change |
|--------------|------------------|
| `trend_direction=degrading` | Switch to **cautious mode** — adds "plan before acting" reminders |
| Session topology = `high-churn` | Switch to **cautious mode** |
| High `avg_edits_per_commit` | Lower the commit nudge threshold (nudge sooner) |
| Everything healthy | Normal mode, default thresholds |

Cautious mode doesn't block anything — it adds a gentle reminder to think before acting.

*Where:* `session-start` computes mode + threshold from health file, `context-flow.sh` and `post-edit-dispatch.sh` read these values

**13. Social/Communication System — Cross-Session Intelligence**
Patterns that only emerge across multiple sessions:

- **Domain tagging:** Each session gets a domain tag based on which subdirectory was most edited. Written as the 12th field in each health row.
- **Cross-session file tracking:** Every file edited gets logged with its session count and last-edit date in `.claude/cortex/cross-session.local.md`.
- **Pattern detection** (runs at session start):
  - *Domain clustering:* "Last 4 sessions were all scoring work" — surfaces focus patterns
  - *Session length trends:* Compares recent session durations to historical average
  - *Hot files:* Files edited in 5+ sessions get called out

*Where:* `session-end-dispatch.sh` (writes domain tag + updates cross-session file) → `session-start` (reads and analyzes patterns)

---

## Statusline

The organism displays a two-line pulse at the start of every session and on-demand via `/status`:

```
✏️  3 edits · 📦 1 commits · 🧪✅ · 📄❌
💚 thriving │ 🧠 62 absorbed │ 🧬 1 mutations queued │ ↗ improving
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
| 💚 `thriving` | Organism is healthy — zero recent reasoning misses, stable trend |
| 💛 `adapting` | Normal operation — some misses detected, learning from them |
| 🧡 `cautious` | Feedback system activated cautious mode (high churn or degrading trend) |
| ❤️‍🩹 `stressed` | Health trend is degrading — extra care needed |
| 🧠 `N absorbed` | Total lessons in `tasks/lessons.md` (cumulative knowledge base) |
| 🧬 `N mutations queued` | Pending evolution proposals waiting for approval |
| ↗/→/↘ `trend` | Health trend direction: `improving`, `stable`, or `degrading` |

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

### 7 Hook Events

| Event | Source | Script | What |
|-------|--------|--------|------|
| SessionStart | hooks.json | session-start | Init state, load health, healing, sensory, feedback, social, bootstrap |
| PreToolUse | bootstrap | pre-dispatch.sh | Routes to migration-linter + plan-file-guard + tdd-guard |
| PostToolUse | bootstrap | post-dispatch.sh | Universal tool counter + routes to edit/bash tracking + patterns |
| UserPromptSubmit | bootstrap | context-flow.sh | Context injection, decision detection, cautious mode |
| Stop | bootstrap | stop-gate.sh | 7-gate session end (includes root cause documentation + decision capture) |
| PreCompact | bootstrap | pre-compact.sh | Preserve carry-over |
| SessionEnd | bootstrap | session-end-dispatch.sh | Health metrics, domain tag, cross-session tracking |

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

All state files live in `.claude/cortex/` (gitignored):

| Path | Purpose |
|------|---------|
| `cortex/sessions/YYYY-WNN/{session-id}.local.md` | Session state: edit counts, commit counts, tool calls, mode, thresholds, file list. Organized in weekly buckets. |
| `cortex/health.local.md` | Historical: one row per session with 12 metrics. Rolling averages computed on read. |
| `cortex/proposals.local.md` | Pending/applied/rejected evolution proposals |
| `cortex/decisions.local.md` | Decision journal entries with metadata (category, reversibility, confidence) |
| `cortex/cross-session.local.md` | File edit frequency across sessions |
| `cortex/current-session.id` | Pointer to active session state file (ensures correct resolution) |
| `cortex/profile.local` | Hook profile override (minimal/standard/strict) |

### 12 Context Files

8 keyword-injected files (via `context-flow.sh`) + 3 plan-audit reference files (loaded on demand via `@context/`) + 1 index.

**Keyword-injected** (auto-discovery via `keywords:` frontmatter):

| File | Keywords |
|------|----------|
| deploy-readiness.md | deploy, vercel, production, ship, go live |
| testing-conventions.md | vitest, test suite, write test, add test, run test, fix test, coverage |
| math-review.md | formula, statistics, probability, monte carlo, sigmoid, z-score, distribution, likelihood, half-life |
| typescript-discipline.md | typescript, type error, tsc, nouncheckedindexedaccess, type guard |
| python-patterns.md | python, pyproject.toml, pytest, django, flask, fastapi, poetry, ruff, mypy |
| go-patterns.md | golang, go.mod, goroutine, cobra, fiber |
| rust-patterns.md | rustc, cargo.toml, lifetime, tokio, serde, clippy, rust-lang |
| synthesis-memory.md | collaboration pattern, workflow pattern, synthesis |

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

28 test scripts organized by type:

```text
tests/
  run-all.sh                              # Test runner
  unit/                                   # 6 tests — state-io, json-extract, escape-json, validate-organism, lint-antipatterns, event-io
  integration/                            # 17 tests — one per hook script + profiles + migration v3.7
  edge/                                   # 2 tests — empty stdin, Windows paths
  regression/                             # 3 tests — health dedup, pipefail glob, concurrent appends
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
    hooks.json                             # SessionStart only (bootstrap lifeline)
    session-start                          # SessionStart: init + healing + sensory + feedback + social + bootstrap
    scripts/
      bootstrap-hooks.sh                   # Injects 6 events into ~/.claude/settings.json
      pre-dispatch.sh                      # PreToolUse dispatcher
      post-dispatch.sh                     # PostToolUse dispatcher (universal counter + routing)
      post-edit-dispatch.sh                # Edit tracking + commit nudge
      post-bash-dispatch.sh                # Bash tracking + commit format validation
      migration-linter.sh                  # Block now() in migrations
      plan-file-guard.sh                   # Block plan overwrites
      tdd-guard.sh                         # Block implementation before tests
      context-flow.sh                      # Keyword context + decisions + cautious mode
      drift-detector.sh                    # Async codebase spot-checks
      pattern-template.sh                  # Convention exemplar injection
      stop-gate.sh                         # 7-gate session end
      sensory-check.sh                     # External awareness (git, CI, PRs)
      apply-proposal.sh                    # Proposal approve/reject lifecycle
      pre-compact.sh                       # Preserve carry-over on context compaction
      session-end-dispatch.sh              # Health metrics + domain tag + cross-session tracking
      statusline.sh                        # Organism statusline renderer
      lib/
        escape-json.sh                     # JSON string escaping
        json-extract.sh                    # Lightweight JSON field extraction
        state-io.sh                        # read_field/write_field/read_section/append_to_section
        validate-organism.sh               # Healing system: 9 self-repair checks
  skills/             # 16 skill directories
  commands/           # 10 slash commands
  agents/             # conversation-analyzer + deep-dive + code-reviewer + memory-synthesis
  context/            # 12 context files (8 keyword-matched + 3 plan-audit reference + 1 index)
  tests/              # 28 test scripts + 3 helpers (run-all.sh)
```

---

## Version History

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

To cleanly remove Cortex and all its artifacts, run `/uninstall` in any Claude Code session with the plugin still installed. This guides you through removing bootstrap entries from `~/.claude/settings.json`, project-level state files, and the plugin itself.

---

## License

MIT. See [LICENSE](LICENSE).
