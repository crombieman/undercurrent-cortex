---
name: session-start
description: This skill should be used when starting or resuming a session — reads memory, creates journal, surfaces carry-over and domain-relevant lessons.
version: 0.5.0
---

# Session Start

**TL;DR**: Always: MEMORY.md + journal + carry-over. Scale up based on task scope.

## Always (every session)
1. Read `MEMORY.md` (project root) — personal context, preferences, active decisions
2. Read or create `memory/YYYY-MM-DD.md` — if missing, create: `# Journal - YYYY-MM-DD` + `## HH:MM - Session start`. Do not ask. Just create it.
3. Check `memory/[yesterday].md` — if hook surfaced a missed-session-end warning, run `/cortex:session-end` retrospective for yesterday first. Then check last 3 entries for `[carry-over]` tags and surface them.
4. Read `~/.cortex/synthesis/collaboration.md` (full file) — how we work together. If the file doesn't exist, skip (first-run: create it via seed data or let session-end populate it).
   - **Promotion sweep**: *(Automated by hook — check hook output for "Promoted N pattern(s)". Manual fallback: scan for `Reinforced` >= 2 + `[unconfirmed]` in heading, remove the tag.)*
   - **Staleness check**: *(Automated by hook — check hook output for stale pattern warnings. Manual fallback: flag patterns with `Last validated` older than 30 days.)*
   - **Applied tracking**: After reading, note which patterns are relevant to today's task or conversation. Log them in the journal. At session-end, check which were actually followed and increment their `Applied` count then.
   - **Duplicate detection**: Scan for entries that describe semantically similar behaviors (same pattern worded differently across sessions). Flag to user: "Patterns X and Y look like duplicates — merge or keep separate?"
5. Read `~/.cortex/synthesis/workflows/_index.md` (compact index only) — awareness of reusable approaches. If the file doesn't exist, skip.
6. **Display the organism statusline.** The SessionStart hook injects it into system context (inside `<cortex-session-start>` tags), but the user cannot see system context. Copy the statusline lines verbatim (two lines, plus a third `🔁 interventions:` line when follow-through data exists), then append a final line with model metadata extracted from your system context:
   ```
   🤖 {model_name} · ⚡ {effort_level} · 🪟 {context_window}
   ```
   - `model_name`: Your model name (e.g., "Opus 4.6", "Sonnet 4.6", "Haiku 4.5")
   - `effort_level`: Reasoning effort if set (e.g., "effort: 85"), or "default" if not specified
   - `context_window`: Context window size if known (e.g., "1M context", "200K context")
   Display all the lines in your first response to the user.

## If task is non-trivial (new feature, bug, architectural decision — not a quick question)
7. Read `tasks/todo.md` + scan `tasks/lessons.md` by domain:
   - DB/Supabase/PostgREST → surface all DB lessons
   - Pipeline/cron/sync-tickers → surface pipeline lessons
   - Auth/RLS/middleware → surface auth lessons
   - React/Next.js/components → surface frontend lessons
   - SEC/EDGAR/XBRL → surface SEC lessons
   Surface all matches. Do not limit to "last 5."
   - **Surfaced-lesson logging**: when you surface lessons, log their stable IDs (`L-YYYYMMDD-nn`, or the heading if un-ID'd) in today's journal entry — the curate-memory retirement pass counts these mentions to decide which lessons still pay rent (spec §7.2).
   - **Domain workflow loading**: Check each workflow in `_index.md` — if its scope tags match the current task domain, read the full detail file from `~/.cortex/synthesis/workflows/`. Example: task involves design or brainstorming → load `design-through-conversation.md`. Task involves audit or code-quality → load `probe-then-fix.md`.

## If touching architecture, schema, or pipeline
8. Read `documentation.md`. Run `git log --oneline -5 documentation.md` — if not touched in 3+ commits while code changed, flag staleness to Will before proceeding.

## State file protocol
9. Check `tasks/todo.md` for in-progress items (unchecked boxes). If the previous session left work mid-flight, complete it before starting new tasks.

## Housekeeping (lightweight, after greeting)
After displaying the statusline and beginning the session, run these non-blocking checks. Use the Bash tool for mv/rm operations, Read + Grep for carry-over detection:

1. If any journals in `memory/` are from a previous month AND have no open `[carry-over]` (grep `^- \[carry-over\]` returns 0 = safe to move), move them to `memory/archive/YYYY-MM/`. Create the archive dir if needed.
2. If any session files in `.claude/cortex/sessions/` are from a previous week AND have no `[carry_over]` section with content, move them to `.claude/cortex/sessions-archive/YYYY-WNN/`.
3. Clean any `.tmp.*` files from `.claude/cortex/` (bash `rm -f`).
4. If 10+ sessions have passed since the last curation run (check `~/.cortex/synthesis/collaboration.md` modification date vs session count), suggest: "It's been a while since memory curation ran. Want me to run `/cortex:curate-memory`?"
5. If `~/.cortex/synthesis/collaboration.md` has >20 H3 entries (count `###` headings), warn: "Collaboration patterns file has grown to [N] entries. Consider splitting into per-theme files for better token efficiency."

## Carry-over re-injection
When surfacing carry-over items from previous sessions, explicitly write them as the first item in today's journal entry. Do not just acknowledge them — write them to the journal so they are tracked:
```
## HH:MM - Session start
- Carry-over from [date]: [carry-over] Item description here
```

See `references/memory-tiers.md` for the full memory hierarchy and rules.

## Reference file staleness check
After reading MEMORY.md and journal, check if `references/` directory exists. If it does, scan for reference files with `last-verified` frontmatter older than 30 days while related code has changed. Surface staleness warnings:
> "references/pipeline.md hasn't been verified since [date] — 3 pipeline commits since then."

This is read-only guidance — it doesn't block work.

**Default to reading** — skip only if the session is purely conversational (no files, no decisions, no code). When in doubt, read.

---
## See Also
- [session-end](../session-end/SKILL.md) — Session lifecycle pair: start reads memory, end writes it [lifecycle]
- [pattern-escalation](../pattern-escalation/SKILL.md) — Session start surfaces pending escalation proposals for review [lifecycle]
