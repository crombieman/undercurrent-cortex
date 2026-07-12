---
name: session-end
description: This skill should be used when wrapping up a working session — writes journal entry, captures carry-over, runs reasoning audit and pattern escalation check.
version: 0.5.0
---

# Session End

**TL;DR**: Always write 3-line journal. Scale up only if something notable happened.

## Always (every session) — append to `memory/YYYY-MM-DD.md`
- What happened (1 line)
- Any carry-over for next session — tag `[carry-over]` (1 line, or "none")
- Quality bar: did what shipped meet institutional-grade? (1 line, or "n/a")
- Tag entry with `[session-end]`

## If something notable happened (code written, decision made, bug fixed, correction received)

**Step 1 — Full journal entry**:
- **Decisions + rationale**: Why X over Y. One line each.
- **What broke + fix**: Root cause → fix. One line each.
- **Patterns recognized**: Any recurring class of problem.
- **Mid-session pins**: Confirm any decisions pinned mid-session were captured.
Keep total entry under 25 lines. Signal over noise.

**Step 2 — Reasoning audit** (answer honestly, one line each):
1. Did I jump to implementation before fully understanding the problem?
2. Did I catch all architectural implications, or did any surface late?
3. Was there a simpler solution I overlooked or dismissed?
4. What decisions were made this session not yet in `.claude/cortex/decisions.local.md`? Log any missing ones now (same format as plan-audit Gate 17). This is the catch-all for sessions that skipped plan-audit.
5. What context would most help the next session in the first 30 seconds? Write this as a `[carry-over]` entry — not a summary, but what's *actionable* immediately.
If any "yes, I missed something" → add as `[reasoning-miss]`.
Tag explicit user corrections (user says "that's wrong", corrects a factual claim, or redirects a wrong approach) with `[correction]`.

**Step 2b — Synthesis final sweep** (safety net, not primary path):
Inline extraction (via `CLAUDE.md` rules) is the primary mechanism for capturing collaboration patterns during the session. This step is the safety net — check if anything was missed.

Quickly scan the conversation for moments that should have triggered inline extraction but didn't:
- Corrections, approvals, or pushback that reveal HOW to collaborate
- Anti-patterns (from `[correction]` tags) that reveal what DOESN'T work
- Reusable workflows (discrete reproducible steps) → create detail file in `~/.cortex/synthesis/workflows/`, add one-liner to `_index.md`

If the conversation-analyzer ran this session, consume its correction findings for anti-patterns.

For any missed items, use the same ADD/UPDATE/NOOP check against `~/.cortex/synthesis/collaboration.md`. Full metadata for new entries: Origin, Reinforced, Last validated, Scope, Importance, Negative scope, Evidence (project-qualified), Applied (starts at 0), Supersedes.

Log what was written:

```
[synthesis] Added collaboration pattern: "Pattern name" (Theme) [unconfirmed]
[synthesis] Added anti-pattern: "Don't do X" (Anti-Patterns)
[synthesis] Reinforced workflow: workflow-name (now Nx)
```

If inline extraction captured everything, skip silently.

Also: check which patterns were marked as relevant at session-start. For any that were actually followed during the session, increment their `Applied` count and update `Last validated` in `collaboration.md`.

**Step 3 — Pattern escalation check**:
For each journal item: seen this class of problem in `tasks/lessons.md` or prior journals?
- YES, 2+ times → invoke `cortex:pattern-escalation`
- NO → journal only

**Step 4 — Auto-memory sync**:
Any structural pattern or decision made today → update `~/.claude/projects/.../memory/MEMORY.md`.
Edit/replace stale entries. Never just append. Stay under 200 lines.

**Step 5 — System health check** (1 line, every session):
Did the compounding loop produce signal or noise today? Log as `[system-health]`.
If session-start didn't fire or skills were skipped — note it.

**Step 6 — Health metrics** (1 line per metric):
Assess the 5 health metrics defined in `references/health-metrics.md`:
1. Compounding signal-to-noise (did skills produce useful guidance?)
2. Session-start coverage (did the protocol execute fully?)
3. Pattern capture rate (did all corrections/decisions get logged?)
4. Memory freshness (is MEMORY.md clean and under 200 lines?)
5. Lesson deduplication (any duplicate lessons.md entries?)

Log as `[health-metrics]`:
```
[health-metrics] signal-noise=good, session-start=complete, capture=100%, memory=fresh, dedup=clean
```

**Adaptive immunity trigger**: If today's journal contains 2+ `[correction]` tags OR 1+ `[reasoning-miss]` tag, invoke `/analyze-session` for a full adaptive immunity scan before completing session-end. This is the primary feedback mechanism for the self-improvement loop. Also invoke if 3+ consecutive sessions show degraded health metrics (low capture rate, stale memory).

**What counts as notable**: touched code, made an architectural choice, received a correction, fixed a bug, or spent more than 10 minutes on anything.

See `examples/journal-entry.md` for a model journal entry with proper tags.

**Step 6c — Mark resolved carry-over** (event-log emitter, only if carry-over was inherited):
For each `[carry-over]` item that was surfaced at session-start and you verified as actually resolved this session, append an `addressed` marker to the current session's event log. Future sessions reconcile these markers by content hash and stop resurfacing the item (they also feed stop-gate Gate 4 — without an emitter, every carry-over-inheriting session stays blocked). Run once per resolved item, substituting its exact text:

The session id comes from YOUR CONTEXT: the boot injection's `Session id: <sid>` line (re-injected at compaction by pre-compact). Substitute it for `<SID-FROM-CONTEXT>` below. If the line is nowhere in your context, SKIP this step and say so — a skipped marker just means the item resurfaces next session (self-healing); a GUESSED sid writes into another session's log. Never read a sid from a file and never guess one.

```bash
SID="<SID-FROM-CONTEXT>" && EIO=$(ls -t ~/.claude/plugins/cache/undercurrent-studio/cortex/*/hooks/scripts/lib/event-io.sh 2>/dev/null | head -1 || true) && [ -n "$EIO" ] && [ -n "$SID" ] && source "$EIO" && resolve_event_log "{\"session_id\":\"${SID}\"}" && append_event carry_addressed "$(eio_item_hash "EXACT carry-over item text")" || echo "event-io not found — carry_addressed skipped"
```

Only mark items you genuinely resolved — do not blanket-close still-open carry-over. Items left open are re-surfaced by the next session-start automatically.

**Step 7 — Write health row** (every session with a known sid):
The skill is the primary path for health row writes; the native SessionEnd hook (which receives the sid in its own payload — ground truth) is the backup. Use the `Session id: <sid>` line from YOUR CONTEXT (boot injection, re-injected at compaction); substitute it for `<SID-FROM-CONTEXT>`. If it is not in your context, SKIP this step and note that the native SessionEnd hook will write the row — never guess a sid.

```bash
SID="<SID-FROM-CONTEXT>" && SCRIPT=$(ls -t ~/.claude/plugins/cache/undercurrent-studio/cortex/*/hooks/scripts/session-end-dispatch.sh 2>/dev/null | head -1 || true) && [ -n "$SCRIPT" ] && echo "{\"session_id\":\"${SID}\"}" | bash "$SCRIPT" || echo "session-end-dispatch not found"
```

After running, verify `.claude/cortex/health.local.md` — an idle session (zero r-edits, zero commits) legitimately writes NO row since the calibration wave; a working session's last row date should match today.
If the script is not found, log `[system-health] session-end-dispatch not found — health row skipped` in the journal.
The per-sid dedup guard prevents duplicate rows when both the skill and the native hook run.

**Step 8 — Display session statusline diff** (every session):
Display the organism statusline at the end, showing what changed during the session. Compare the values from session start (displayed in your first response) against current values. Format:

```
── Session Pulse ──────────────────────────────
START  ✏️  0 edits · 📦 0 commits · 🧪❌ · 📄❌
END    ✏️  4 edits · 📦 2 commits · 🧪✅ · 📄✅
       💚 thriving │ 🧠 63 absorbed │ 🧬 0 mutations queued │ → stable
───────────────────────────────────────────────
```

Show the START line (from session start), the END line (current values), and the organism health line (current). This gives the user a visible summary of session productivity.

## Reference file tracking
Add to journal entry:
> **Reference files touched:** [list any references/*.md or rules/*-deep.md files created or updated]
> **Reference files needing update:** [list any that should be updated based on code changes this session]

If a reference file was modified this session, update its `last-verified` date in frontmatter.

**Run session-end before closing every working session.** It takes 2 minutes.

---
## See Also
- [session-start](../session-start/SKILL.md) — Session lifecycle pair: end writes memory, start reads it [lifecycle]
- [pattern-escalation](../pattern-escalation/SKILL.md) — Session end triggers pattern escalation check for recurring issues [downstream]
