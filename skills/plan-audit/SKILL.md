---
name: plan-audit
description: This skill should be used before calling ExitPlanMode or finalizing any implementation plan — 44-gate layered audit with Killer 7 universal core, risk-tiered depth, and domain-specific activation. Catches silent failures, data integrity bugs, security gaps, math errors, architecture conflicts, idempotency violations, race conditions, blast radius issues, and AI-isms. Non-negotiable before any plan approval.
version: 1.0.1
---

# Plan Audit v1.0

**TL;DR**: Killer 7 on every plan. Domain gates activated by what the plan touches. Risk tier controls depth. Every gate produces evidence, not checkmarks.

**Meta-instruction**: Any gate that asks "is X within Y?" requires arithmetic showing the computation. Assertions without math are a FAIL. Format: `[COMPUTED: X * Y = Z, Z < limit]`

## The Irreducible Core (Always — Every Plan)

Three questions asked FIRST, before any gates. These catch ~80% of plan-level bugs.

1. **Show the Math.** Compute every resource estimate. Row counts, time budgets, API call rates. Not "should be fine" — show `[COMPUTED: X * Y = Z, Z < limit]`.

2. **What Breaks If This Fails?** Combined premortem + blast radius. Scope: one component / one page / entire pipeline / all users. Name the containment mechanism.

3. **Prove the Data Exists.** For every field from an external source: cite a sample response, doc URL, or tested query. "I assume it returns X" is a FAIL.

If time is short, do these three. They are NEVER skipped.

## Risk Classification

Classify the plan. This determines which layers activate.

| Tier | Description | Examples | Depth |
|------|-------------|----------|-------|
| **S** | Safety-critical | Scoring formula changes, Stripe/auth, pipeline architecture, schema migrations | Full gate set + FMEA |
| **A** | High-impact | New data sources, new API routes, new GH Actions, multi-file features | Killer 7 + Phase 1-3 |
| **B** | Standard | Bug fixes, enhancements, refactors touching multiple files | Killer 7 + domain gates |
| **C** | Trivial | Typo fixes, single-file changes, doc updates, config tweaks | Killer 7 only |

## The Killer 7 (All Plans, All Tiers)

Evaluated FIRST, in this order. If a Killer 7 gate also appears in domain phases, skip it there.

| # | Gate | What to Produce |
|---|------|-----------------|
| 1 | **Premortem** (G39) | "Assume this failed catastrophically. Write 3 specific, plausible reasons why." |
| 2 | **Show the Math** (G20) | All resource estimates computed with arithmetic. `[COMPUTED: ...]` format. |
| 3 | **Source Evidence** (G19) | For every external data field: cite sample response, doc URL, or tested query. |
| 4 | **Success Criteria** (G37) | "How will you know this worked? What metric or behavior changes?" |
| 5 | **Blast Radius** (G38) | "If this breaks, what else breaks?" Scope + containment mechanism. |
| 6 | **Lessons Check** (G16) | Grep `tasks/lessons.md` by domain. Quote matches. State applicability for each. |
| 7 | **AI-ism Smell Test** (G43) | "Does this plan have opinions? Would a senior engineer under deadline produce this?" One sentence identifying strongest opinion or flagging its absence. |

## Domain Gates (Tier B+)

All 44 gate definitions live in `@context/plan-audit-gates.md`. SKILL.md references gates by number. Organized into 3 sequential phases:

### Phase 1 — Understanding (what does the plan assume?)

| Gate | Name | Triggered by |
|------|------|-------------|
| G8 | Architecture & Lessons | Universal |
| G14 | Reference Coverage | `references/` exists |
| G15 | Reference Freshness | `references/` exists |
| G41 | Precedent Check | New utilities, pipelines, UI patterns |
| G40 | Invariant Preservation | New write paths, modified computations |
| G25 | Data Volume & Cardinality | DB queries returning multiple rows, batch processing |

### Phase 2 — Evaluation (will the plan work?)

| Gate | Name | Triggered by |
|------|------|-------------|
| G1 | Silent Failure Patterns | DB queries, error handling, null paths |
| G2 | Data Integrity & Pipeline | Pipeline ops, external data, DB queries |
| G3 | Security & Auth | API routes, user input, auth, new tables |
| G4 | Schema & Migration Safety | Database migrations |
| G5 | Math & Algorithm Correctness | Math, scoring, signal processing |
| G6 | Caching & State | Caching, `"use cache"`, state management |
| G7 | Frontend & React | React/Next.js components |
| G9 | Estimate & Scope Validation | Time estimates, batch processing, shell scripts |
| G10 | Validation Depth | Verification/testing sections |
| G19 | Data Source Provenance | New schema for external data, new sources |
| G20 | Quantitative Resource Modeling | DB queries, batch loops, API calls, GH Actions |
| G21 | Verification Path Fidelity | DB writes, batch processing, API integration |
| G22 | Idempotency & Re-Run Safety | DB writes, side effects, cron/worker logic |
| G23 | Temporal Ordering & Race Conditions | Concurrent execution, cron timing, TOCTOU |
| G24 | Partial Failure & Recovery | Batch processing, multi-step pipelines |
| G26 | Observability & Failure Detectability | New data sources, pipeline steps, workers |
| G27 | Data Freshness & Staleness | Serving data to users, derived metrics, caching |
| G28 | Upstream Contract & Dependency Stability | External APIs, dependency upgrades |
| G29 | Implicit Coupling & Hidden Dependencies | Shared tables, cache keys, utilities, constants |
| G30 | Downstream Consumer Impact | Schema changes, API response changes |
| G31 | Rollback & Forward-Fix Safety | Migrations, data transformations |
| G32 | Environment & Deployment Divergence | New API calls, shell scripts, GH Actions, env vars |
| G33 | Attack Surface Delta | New endpoints, user input, third-party deps |
| G34 | Monotonicity & Data Regression Guards | Scores, rankings, trends, time-series |
| G35 | External Timing & Calendar Awareness | Financial data, periodic sources, time windows |
| G36 | Type Coercion Boundary Analysis | External source → DB writes, BIGINT/NUMERIC |

### Phase 3 — Holistic (is this plan complete?)

| Gate | Name | Triggered by |
|------|------|-------------|
| G11 | Documentation Completeness | Universal |
| G12 | Commit Strategy & Verification Cadence | Universal |
| G13 | Quality & Completeness Standard | Universal |
| G17 | Decision Pre-Capture | Non-obvious choices |
| G18 | Journal Pre-Entry | Universal |
| G42 | Ripple Effect Trace | Shared code, schemas, cache keys, API contracts |
| G44 | Product-Value Alignment | New features, significant reworks (not bug fixes) |

## Applicability Matrix

| Plan touches... | Required gates (in addition to Killer 7) |
|-----------------|------------------------------------------|
| **Database/queries** | 1, 2, 4, 6, 8, 20, 22, 24, 25, 30, 36, 40 |
| **API routes** | 1, 3, 8, 26, 28, 30, 33, 40 |
| **Frontend components** | 6, 7, 8, 43 (LC + UX questions) |
| **Pipeline/cron** | 1, 2, 5, 8, 9, 20, 22, 23, 24, 26, 32 |
| **Scoring/signals** | 1, 2, 5, 8, 20, 27, 34, 40 |
| **Migrations** | 4, 8, 31, 30, 36 |
| **Bash/plugin scripts** | 8, 9, 32 |
| **Math/algorithms** | 5, 8, 21, 40 |
| **External data sources** | 2, 19, 26, 27, 28 |
| **Batch processing** | 9, 20, 22, 24, 25 |
| **Caching / serving data** | 6, 27, 29 |
| **Financial time-series** | 27, 34, 35 |
| **Shared infrastructure** | 29, 30, 42 |
| **New API endpoints** | 3, 33, 30 |
| **Any plan (universal)** | 11, 12, 13, 16, 17, 18 |

Gates 14-15 apply when the project has a `references/` directory.

## Gate Activation by Risk Tier

| Tier | Active Layers | Expected Gates | Target Time |
|------|--------------|----------------|-------------|
| **S** | Killer 7 + Phase 1-3 + extended | 20-30 | 25-35 min |
| **A** | Killer 7 + Phase 1-3 | 12-18 | 15-20 min |
| **B** | Killer 7 + applicable domain gates | 8-12 | 10-15 min |
| **C** | Killer 7 only | 7 | 5-10 min |

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| **CRITICAL** | Would cause production bug, data loss, or security hole | Hard block — must fix before implementation |
| **IMPORTANT** | Would cause incorrect behavior or maintenance burden | Requires explicit override with rationale |
| **MINOR** | Style, performance, or edge case polish | Noted, doesn't block |

## Output Format

Write findings to the plan file:

```
## Pre-Implementation Audit Findings

**Risk Tier:** [S/A/B/C] — [justification]
**Gates Evaluated:** [list of gate numbers]

### Killer 7

1. **Premortem:** [3 failure scenarios]
2. **Show the Math:** [computations]
3. **Source Evidence:** [citations or "no external sources"]
4. **Success Criteria:** [metric/behavior]
5. **Blast Radius:** [scope + containment]
6. **Lessons Check:** [grep output + applicability]
7. **AI-ism Smell Test:** [strongest opinion or absence]

### Domain Gate Findings

1. **[SEVERITY] — [title]**: [description]. Fix: [action]. Applied/Deferred.
```

Each gate produces either a **finding** (something discovered) or **"clear with evidence"** (a specific fact confirming correctness). Never just "PASS."

"Clear with evidence" can be one line: `"row count: 3361 * 1 = 3361 < 50K — within limits."`

On audit completion, dispatch a Codex review of the audited plan when the Codex CLI is available (pre-authorized — no need to ask; dispatch and result-harvest are two separate steps). The stop-gate Codex reminder is the structural backstop; this mention is the belt.

## Justified Exclusion

Every skipped gate must include a one-sentence justification. "N/A — this plan has no database writes" is valid. "N/A" alone is treated as a gate failure.

---
## See Also
- @context/plan-audit-gates.md — Full 44-gate catalog with checklist questions
- @context/ai-ism-taxonomy.md — 87 AI-ism patterns (loaded when Gate 43 fires)
- @context/plan-audit-reference.md — Meta-principles, evidence, appendices
- [plan-estimation](../plan-estimation/SKILL.md) — Estimation feeds audit: wave count and scope validated by Gate 9 [upstream]
- [deploy-readiness](../deploy-readiness/SKILL.md) — Plan audit catches issues pre-implementation; deploy readiness verifies pre-ship [workflow]
- [pre-commit-checklist](../pre-commit-checklist/SKILL.md) — Audit gates validate planning; pre-commit gates validate execution [workflow]
- [feature-design-flow](../feature-design-flow/SKILL.md) — Feature design invokes plan audit as Phase 4 gate before implementation [workflow]
