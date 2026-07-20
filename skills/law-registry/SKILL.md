---
name: law-registry
description: This skill should be used when a long-lived canonical document (design doc, spec, architecture doc) states the same rule in multiple places and has produced propagation defects — a law updated in one place while another surface kept stale wording. Scaffolds a law registry (anchor regex, home, echo list) plus a mechanical verifier script. Trigger phrases include "add a law registry", "guard the doc", "echo map", "the doc drifted", or any second occurrence of a propagation defect in the same document.
version: 0.1.0
---

# Law Registry — mechanical echo-map guards for living documents

**TL;DR**: When a canonical doc states a rule at one authoritative home plus N echo
surfaces, every fold eventually updates the home while one echo keeps older wording.
Convert echo-recall into lookup: give every load-bearing law a registry row
(anchor regex · home section · echo list) and a ~90-line checker that asserts the
anchor appears at every listed surface. Run it after every edit wave.

## When to adopt — earned by friction, never preemptively

Adopt the registry when a document has produced **two or more propagation defects**
(same rule, divergent wording across surfaces). Before that, the registry is
ceremony; after that, every fold without it repeats the defect class. Origin
evidence: five consecutive fold batches in a 2,000-line design doc each produced
exactly this defect until the registry converted recall into lookup — and the
mechanical guard then caught real misses for 11+ consecutive batches.

Do NOT point this at small or short-lived files. A README does not need a law
registry. The trigger is distributed echoes in a long-lived artifact under active
amendment.

## The registry format

Add an appendix section to the document:

```markdown
## N. Law registry — echo map

| Law | Anchor (regex, `~` = alternation) | Home | Echo surfaces |
|---|---|---|---|
| SHORTNAME — one-line statement of the law | `anchor[- ]pattern~alternate wording` | 4 | 2, 7.3, 11 |
```

- **Home** = the section owning the authoritative wording; echoes cite it, never
  restate it independently.
- **Anchor** = a regex that appears wherever the law is stated. `~` stands for
  alternation (`|` collides with table delimiters).
- **Maintenance rule (write it into the appendix)**: any fold that touches a law
  updates that law's row; a fold adding a law adds a row. The checker guards the
  LISTED surfaces only, so echo-list completeness stays a standing item in every
  independent review pass — reviewers guard the lists, the machine guards the listed.
- **Exclude the audit trail**: status-history/changelog sections keep historical
  wording by design; they are never echo surfaces.

## The checker

Generic template (parametrize DOC and the heading regex to the doc's numbering
convention; ~90 lines total in the reference implementation):

```python
"""Every registry law's anchor must appear in its home + every listed echo section."""
import re, sys
from pathlib import Path

DOC = Path("docs/plans/YOUR-CANONICAL-DOC.md")
HEADING = re.compile(r"^(#{2,3})\s+(\d+(?:\.\d+)?)[.\s]")   # '## 7.' / '### 7.3'
REGISTRY_HEADING = re.compile(r"^##\s+N\.")                  # your appendix number

def split_sections(lines):
    sections, current = {}, "0"
    for line in lines:
        m = HEADING.match(line)
        if m: current = m.group(2)
        sections.setdefault(current, []).append(line)
    return {k: "\n".join(v) for k, v in sections.items()}

def parse_registry(lines):
    rows, in_reg = [], False
    for line in lines:
        if REGISTRY_HEADING.match(line): in_reg = True; continue
        if in_reg and line.startswith("## "): break
        if not in_reg or not line.startswith("|"): continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 4 or cells[0].startswith("---") or cells[0] == "Law": continue
        law, anchor_raw, home, echoes_raw = cells
        rows.append((law, anchor_raw.strip("`").replace("~", "|"), home,
                     [e.strip() for e in echoes_raw.split(",") if e.strip()]))
    return rows

def main():
    lines = DOC.read_text(encoding="utf-8").splitlines()
    sections, failures = split_sections(lines), []
    for law, anchor, home, echoes in parse_registry(lines):
        pat = re.compile(anchor)
        for target in [home, *echoes]:
            sec = sections.get(target)
            if sec is None: failures.append(f"{law}: section {target} missing")
            elif not pat.search(" ".join(sec.split())):
                failures.append(f"{law}: anchor not found in section {target}")
    print("FAILED:\n" + "\n".join(failures) if failures else "PASSED")
    return 1 if failures else 0

if __name__ == "__main__": sys.exit(main())
```

Note the `" ".join(sec.split())` — anchors must match across line-wrapped prose;
matching raw lines produces false negatives on wrapped text.

## Anchor discipline — the rules that keep the guard honest

1. **New conjuncts get NEW rows, never alternation-widening.** Alternation is OR:
   widening `old wording~new wording` lets a surface pass on the OLD wording alone,
   silently certifying a law that changed. When a fold ADDS a requirement to an
   existing law, give the new conjunct its own row with its own anchor.
2. **Presence is not semantics.** The checker proves propagation (the words appear),
   not meaning (the sections agree). Independent review passes remain the semantic
   check; the registry frees them from mechanical echo-hunting so they can do it.
3. **Derive echo lists bottom-up, never from recall**: grep the anchor doc-wide,
   prune, then write the row. Recall-derived lists are how echoes get missed.
4. **Sweep vocabulary shifts**: a law's echo may restate it in shifted vocabulary
   that the anchor misses. When folding a law change, grep the CONCEPT's synonyms,
   not just the anchor, before trusting the row.

## The guard family — beyond the echo map

The same run-after-every-edit-wave posture supports other ~cheap mechanical guards;
add them as the doc's failure modes earn them:

- **Residue guards**: assert retired wording does NOT appear (regex must-not-match) —
  catches half-applied renames.
- **Class-enumeration guards**: when the doc maintains parallel enumerations (every
  record class must appear in lifecycle + backup + export + deletion lists), assert
  each named class appears in ALL of them. This guard class has caught real misses
  its own authors made while adding it.
- **Count assertions**: expected law/table/tag counts per section — blunt, but they
  catch silent deletions.
- **Tag presence**: every fold batch's inline tags (e.g. "F8", "RC3") must appear
  where the fold claimed to land.

## Reader-orientation header

A doc under continuous amendment carries a **current-state header** (status line,
items trail, where-to-look pointers) refreshed **as part of every fold** — the
human approval gate reads the doc, and orientation is part of the artifact, not a
courtesy. A fold that leaves the header stale is unfinished; treat the header as an
implicit echo surface of every fold.

---
## See Also
- [validate-refs](../validate-refs/SKILL.md) — same guard philosophy pointed at the reference-file knowledge graph instead of one canonical doc [related]
- [feature-design-flow](../feature-design-flow/SKILL.md) — design-before-implementation produces the canonical docs this skill guards [lifecycle]
- [pattern-escalation](../pattern-escalation/SKILL.md) — the adoption trigger (2+ propagation defects) is this skill's instance of the 2+ escalation rule [meta]
