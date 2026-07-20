---
name: tdd-enforcement
description: This skill should be used when implementing any feature or bugfix, before writing implementation code — enforces RED-GREEN-REFACTOR test-driven development cycle.
version: 0.1.0
---

# TDD Enforcement

**TL;DR**: Write failing test (RED) -> minimal code to pass (GREEN) -> clean up (REFACTOR). Never write production code without a failing test first.

This is a rigid methodology skill. Follow the phases exactly. Do not skip steps.

## Phase 1 — RED: Write a Failing Test

1. Before touching any production code, write a test that describes the desired behavior.
2. Run the test. It **MUST** fail. If it passes, either the test is wrong or the behavior already exists — investigate which.
3. The test should be specific: test one behavior per test case.
4. Record the test file path — the PreToolUse hook tracks this to enforce test-first discipline.

## Phase 2 — GREEN: Make It Pass

1. Write the **minimum** production code to make the failing test pass.
2. No extra features. No premature abstraction. No "while I'm here" additions.
3. Run tests. ALL must pass (not just the new one).
4. If you need to change more than the minimum, stop — you may be solving the wrong problem.

## Phase 3 — REFACTOR: Clean Up

1. With all tests passing, clean up both test and production code.
2. Extract helpers, rename for clarity, simplify logic.
3. Run tests again — they must still pass after refactoring.
4. No new behavior in this phase. If you're adding behavior, start a new RED cycle.

## Cycle Rules

- **One cycle per behavior unit.** Each distinct behavior gets its own RED-GREEN-REFACTOR cycle.
- **Never skip RED.** Writing production code without a failing test is not TDD.
- **GREEN means "just enough."** The minimum code to pass, nothing more.
- **REFACTOR means "no new behavior."** Only restructure, never add functionality.
- **Commit at cycle end.** After a complete RED-GREEN-REFACTOR cycle, commit the work.

## Phase 0 — Fixtures at Spec Time (upstream of RED)

RED cases are cheapest to derive while the design reasoning is fresh, not when
implementation starts. Two rules:

1. **A spec ruling is not closed until it names the fixtures that would catch its
   violation.** When a design decision, law, or fold is recorded in a spec/design
   doc, record its concrete fixture list in the same entry — the exact input/state
   and the exact wrong output the rule forbids ("aggregate view over an abstained
   parent must render nothing"; "stored-status render must fail"; "single-score
   similarity render must fail"). Same logic as capturing rationale in real time:
   after the fact loses the nuance, and the violation cases ARE the nuance.
2. **Harvest before you derive.** At implementation planning, sweep the spec's
   recorded fixture lists into the test plan FIRST; only then derive additional
   cases. The spec's fixtures encode the failure modes the design process actually
   worried about — a fresh derivation from the code's shape will miss them.

Evidence for the pattern: one design phase recorded fixture lists across ~15 fold
batches at ruling time; the lists repeatedly named negative cases (must-fail
renders, must-refuse merges, must-abstain queries) that a code-first test derivation
has no reason to imagine.

## Enforcement

A PreToolUse hook monitors edits to production code (`src/` files). If no test file has been created or edited this session, the hook intervenes:

- **minimal profile**: No enforcement (hook disabled).
- **standard profile**: Warning — reminds you to write a test first.
- **strict profile**: Blocks the edit until a test file is created.

The hook automatically skips: test files themselves, type definitions (`.d.ts`), non-`src/` files, config files, documentation.

## When TDD Doesn't Apply

- Pure configuration changes (env vars, tsconfig, package.json)
- Documentation-only edits
- Migration files (covered by migration-safety skill)
- Refactoring that doesn't change behavior (existing tests cover it)
- Emergency hotfixes (but add the regression test immediately after)

For emergency skips, set `CORTEX_PROFILE=minimal` or acknowledge the TDD warning twice.

---
## See Also
- [systematic-debugging](../systematic-debugging/SKILL.md) — Test-driven development and systematic debugging form a complementary pair: TDD prevents bugs, debugging resolves them [related]
- [pre-commit-checklist](../pre-commit-checklist/SKILL.md) — Tests must pass before committing; TDD ensures they exist [enforcement]
