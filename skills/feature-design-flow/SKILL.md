---
name: feature-design-flow
description: This skill should be used when starting any feature, significant change, or architectural decision — sets quality bar, sequences design before implementation.
version: 0.1.0
---

# Feature Design Flow

> **Optional integration**: If a `superpowers` plugin is installed, this skill can delegate to its `brainstorming`, `writing-plans`, and `executing-plans` skills. Otherwise, all phases are performed directly. Cortex's own `code-reviewer` agent is used for plan review.

**TL;DR**: Quality bar → brainstorm+doc → plan → audit → execute.

## Before Phase 1 — Ground in product mission
If a product-identity skill is available (e.g., via a domain pack), invoke it to verify the feature aligns with the product mission and respects gating philosophy.

## Phase 1 — Quality bar check (answer before brainstorming)
- What problem does this solve for a professional analyst?
- **Institutional-grade checklist** (all must be yes before shipping):
  - Sub-second loads
  - All states: loading, empty, error
  - Every number traceable to source
  - Works at 3am unattended
  - Information density over whitespace
  - No half-built sections
- Full feature or half-feature? If half: what's cut and why (written down)?
- Data sources / schema changes?
- Edge cases and failure modes?
- Explicit OUT OF SCOPE list?

## Phase 2 — Brainstorm + design doc
Brainstorm by listing 3-5 approaches, evaluating tradeoffs for each, and selecting the best fit. Write findings to the design doc.
Design doc → `tasks/design-[feature-name].md` (canonical — see CLAUDE.md).

**Parking discipline — the legal form of "later"**: deferring an idea, feature, or
surfaced downside is legitimate ONLY when the parked entry carries all three:
1. **Deferral-safety proof** — show that nothing being built now forecloses it
   (later activation stays cheap; no schema/architecture decision blocks it).
2. **Pinned revisit trigger** — a named, checkable condition ("when real usage
   shows X", "at hosting rung 2", "on first request for Y"), never "someday".
3. **A recorded home** — the parked item lives in the design doc's out-of-scope/
   parked section with the proof and trigger attached, not in conversation memory.
Deferral-as-shortcut fails this test; so does absorbing a downside as an accepted
trade-off. Every surfaced downside gets engineered away or parked under these
three conditions — parking without them is scope-loss, not sequencing.

## Phase 3 — Implementation plan
Decompose the work into atomic waves with a commit checkpoint per wave. Each wave should be independently shippable.

## Phase 4 — Plan Audit Gate (before any code)

Run the 15-item self-audit checklist from `references/plan-audit-checklist.md` across 3 tiers:

**Tier 1: Codebase Accuracy** — Did I Read every file to modify? Do types/signatures match? Did I check for existing utilities? Are file paths verified?

**Tier 2: Constraint Compliance** — Pipeline budget respected? PostgREST queries safe? Middleware updated for new routes? Env vars in all 3 locations?

**Tier 3: Architectural Integrity** — Scope check? Waves independently shippable? No forward dependencies? Test expectations per wave?

Write `## Plan Self-Audit` at the bottom of the plan file with pass/fail + evidence for each item. **Tier 1/2 failures = fix the plan before proceeding.** Tier 3 failures are flagged but don't hard-block if the user accepts the tradeoff.

See `examples/design-doc-template.md` for the design doc format.

## Phase 5 — Code-Reviewer Agent Audit (after self-audit passes)

For features touching pipeline, scoring, security, or multi-wave implementations: launch the Cortex code-reviewer agent (`/cortex:code-review`) for a 3-pass review against the plan file. The reviewer checks for:
- Data flow mismatches (function signatures vs actual types)
- Constraint violations (API limits, DB schema, hook event types)
- Missing error handling paths
- Dependency ordering bugs (wave X references something built in wave Y where Y > X)
- Security implications

Incorporate all CRITICAL and IMPORTANT findings into the plan before calling ExitPlanMode. MINOR findings are noted but don't block approval.

Proceed with implementation following the plan's wave structure. Execute one wave at a time, verify before proceeding to the next.

## Mid-execution stop conditions — STOP and re-evaluate if
- Feature taking 2x longer than planned
- A design assumption was wrong
- What's being built doesn't solve the original problem
- Institutional checklist can no longer be answered "yes"
Do not push through degraded implementation. Re-read design doc, re-run Phase 1, adjust or surface to Will.

---
## See Also
- [data-integrity](../data-integrity/SKILL.md) — Design phase must ensure data accuracy rules are met before implementation [downstream]
- [plan-audit](../plan-audit/SKILL.md) — Feature design invokes plan audit as the Phase 4 gate [workflow]
- [plan-estimation](../plan-estimation/SKILL.md) — Estimation calibrates wave count before design proceeds to planning [upstream]
