# Plan Audit — Full Gate Catalog (44 Gates)

> Single source of truth for all gate definitions. Referenced by `skills/plan-audit/SKILL.md`.
> Do NOT register this file in `context/_index.md` — it is loaded via direct `@context/` reference, not keyword auto-injection.

---

## Existing Gates (1-18) — Enhanced Where Noted

### Gate 1: Silent Failure Patterns
- **Priority:** P0
- **Applicability:** Any plan with database queries, error handling, or null-producing data paths

**Checklist:**
- PostgREST query results: Does any query use `.select()`, `.update()`, `.upsert()`, `.in()`? Check:
  - No `.update().or().select()` (returns empty — read-then-write instead)
  - No `.maybeSingle()` after `.update()` (returns 406)
  - `.in()` and all multi-entity queries: **show the math.** `entity_count` = [N], `rows_per_entity` = [N], `total = entity_count * rows_per_entity` = [N]. If total > 50K: redesign the query (don't add `.limit()`). Format: `[COMPUTED: 600 * 365 = 219,000 > 50K — FAIL]`
  - Bad `.select()` column names return `{ data: null, error }`, NOT a throw
  - With `Promise.allSettled`, null data silently becomes `[]`
  - Upsert includes ALL NOT NULL columns (even for existing rows)
- Error swallowing: Does any `try/catch` or `Promise.allSettled` silently discard errors?
- Empty/null propagation: If upstream returns null, does downstream handle it or crash silently?

---

### Gate 2: Data Integrity & Pipeline
- **Priority:** P0
- **Applicability:** Any plan with data pipeline operations, external data sources, or database queries

**Checklist:**
- Batch operations: Can a single batch failure corrupt data for the whole run? (Yahoo batch → false delistings pattern)
- Data source assumptions: Does the plan assume an API returns a specific format? Verify against actual API behavior.
- **For every new field the plan expects from an external source: cite a sample response, official documentation URL, or tested query that confirms the field exists and has the expected type. "I assume it returns X" is a FAIL.**
- Column existence: Every column referenced in `.select()` — does it actually exist in the schema? Check `documentation.md` or migration files.
- Aggregation semantics: Are nulls handled correctly? (`null` in avg vs `0` in avg produce different results)
- Data freshness: Could stale cached data produce incorrect results?

---

### Gate 3: Security & Auth
- **Priority:** P0
- **Applicability:** Any plan with API routes, user input, authentication, or new tables

**Checklist:**
- Route protection: New dashboard routes → middleware matcher updated? API routes → auth check present?
- Input validation: User-supplied values bounded and sanitized? (Zod schemas, length limits)
- CSRF: Mutation endpoints (POST/PATCH/DELETE) → CSRF token verified?
- Secrets: No hardcoded keys. `server-only` on sensitive modules. No secrets in client bundles.
- Rate limiting: New API endpoints → rate limiter present?
- RLS: New tables → RLS enabled + policies + GRANT statements?
- **Data exposure: For every API response that includes user data or computed data: are there fields that should be admin-only but are included in the authenticated response? Check against the profile column security model (migration 024). Does the error response include stack traces, internal IDs, or SQL error details?**

---

### Gate 4: Schema & Migration Safety
- **Priority:** P0
- **Applicability:** Any plan with database migrations

**Checklist:**
- Constraint names: `DROP CONSTRAINT IF EXISTS` for BOTH explicit name AND Postgres default pattern (`{table}_{col}_key`, `{table}_{col}_fkey`)
- Transactional rollback: If ANY statement in migration fails, ALL roll back. Include all dependencies (CREATE TABLE + RLS + policies + seed) in same migration.
- FK ordering: Seed data with foreign keys → `WHERE EXISTS` guard or insert referenced rows first.
- IMMUTABLE requirement: Partial index WHERE clauses → no `now()`, `CURRENT_DATE`, `clock_timestamp()`
- NOT NULL traps: New columns → default value or nullable? Upsert paths include all NOT NULL columns?
- Data types: BIGINT for counts/dollars + `Math.round()` at ingestion. NUMERIC for ratios/EPS/per-share.

---

### Gate 5: Math & Algorithm Correctness
- **Priority:** P0
- **Applicability:** Any plan with mathematical computations, scoring, signal processing, or algorithms

**Checklist:**
- Sign conventions: Addition vs subtraction correct? (Bearish signals subtract from P(bullish), not add)
- Dimensional consistency: Units match across operations? (`dt` in correct units, probabilities in [0,1], percentages in [0,100])
- Edge values: Division by zero? Log of zero? Empty arrays to `Math.max()`/`Math.min()`?
- Dead code: Is the computed value actually used downstream? (surpriseMagnitude, control variate patterns)
- Known analytical solutions: Can you verify with a hand-calculated example? If yes, do it.
- Probability bounds: Values clamped to [0,1]? Log-odds clamped to prevent infinity?

---

### Gate 6: Caching & State
- **Priority:** P1
- **Applicability:** Any plan with caching, state management, or `"use cache"` directives

**Checklist:**
- Cache key design: Pro/Free tier in shared cache keys? User-scoped data uses `'use cache: private'`?
- Null caching: Supabase errors inside cached functions MUST throw (never cache null results)
- `"use cache"` + cookies: No `getUser()` inside cached page functions
- `"use client"` exports: Data constants exported from `"use client"` files are `undefined` in RSC (Turbopack)
- State persistence: No code that assumes in-memory state persists between serverless requests
- **Staleness window: For every cached data path: compute the total staleness window = `source_refresh_interval + cache_stale_duration + propagation_delay`. State the result: "Stock prices can be up to [10 min pipeline + 2 min cache stale] = 12 minutes old." Is this acceptable for the use case?**

---

### Gate 7: Frontend & React
- **Priority:** P1
- **Applicability:** Any plan with React/Next.js frontend components

**Checklist:**
- Suspense boundaries: `useSearchParams()` → wrapped in Suspense?
- Server/client boundary: Event handlers → `"use client"` directive? `server-only` imports → not in client components?
- Router state: Multiple `router.replace()` calls → batched into single call?
- Key props: Dynamic lists → stable, unique keys (not array index)?
- Loading/empty/error states: All three present for data-driven components?

---

### Gate 8: Architecture & Lessons
- **Priority:** P0
- **Applicability:** Universal

**Checklist:**
- Read `documentation.md`: Does the plan conflict with existing architecture, schema, or patterns?
- Read `tasks/lessons.md`: Surface ALL lessons matching the plan's domain. Do not limit to "top N."
  - DB/Supabase/PostgREST → surface DB lessons
  - Pipeline/cron → surface pipeline lessons
  - Auth/RLS/middleware → surface auth lessons
  - React/Next.js → surface frontend lessons
  - Bash/hooks/scripts → surface bash lessons
  - Migrations → surface migration lessons
  - Scoring/signals → surface scoring lessons
- Naming collisions: New files/functions/routes → no conflicts with existing?
- Pattern consistency: Follows existing patterns in codebase?

---

### Gate 9: Estimate & Scope Validation
- **Priority:** P1
- **Applicability:** Any plan with time estimates, batch processing, or shell scripts

**Checklist:**
- Wave count: Compare to similar past work in `memory/` journals. Flag if optimistic.
- Scope creep: Does the plan do exactly what was asked? No silent feature additions?
- Deployment constraints: Total runtime within 300s Vercel limit? Sequential API calls under timeout?
- Bash portability (plugin work): Windows/Git Bash, `set -euo pipefail`, `grep` inside `if`, `cut -d:` on Windows paths.
- **Full-universe scenario: If this worker/script could eventually target the full entity universe (backfill, catch-up, initial seed): `full_entity_count * per_entity_time = full_runtime`. If `full_runtime > timeout`, the plan MUST include a chunking/resumption strategy. What's the growth rate? When does the current design break?**

---

### Gate 10: Validation Depth
- **Priority:** P1
- **Applicability:** Any plan with a verification/testing section

**Checklist:**
- Does the verification require EXECUTION tests, not just existence checks? (file exists ≠ file works)
- For each component: is there a command that proves it works with realistic input?
- Are edge cases covered for critical paths (empty input, missing files, error conditions)?

---

### Gate 11: Documentation Completeness
- **Priority:** P1
- **Applicability:** Universal

**Checklist:**
- Doc file identification: Does the plan explicitly name which documentation files need updating?
- Timing: Are doc updates scheduled during or immediately after the implementation wave that changes behavior — not deferred to a "cleanup wave" at the end?
- Architecture/schema/pattern changes: If the plan alters database schema, API routes, architectural patterns, scoring logic, or conventions — corresponding docs MUST be updated in the same wave.
- New feature completion: If a feature is being completed, does the plan include a summary entry for the project's history/changelog file?
- Behavioral drift: If the plan modifies existing behavior, does it identify which existing documentation describes that behavior and schedule an update?

---

### Gate 12: Commit Strategy & Verification Cadence
- **Priority:** P1
- **Applicability:** Universal

**Checklist:**
- Commit boundaries: Are commits planned at logical boundaries — one per wave, one per independently shippable unit?
- Working state invariant: Does each commit leave the system in a working state?
- Test coverage breadth: Are tests planned for ALL new functionality — not just happy path?
- Multi-wave cadence: For plans with 2+ waves, each wave should have its own commit cycle explicitly stated.
- Push/PR timing: Are pushes or PRs planned at appropriate points?

---

### Gate 13: Quality & Completeness Standard
- **Priority:** P0
- **Applicability:** Universal

**Checklist:**
- Completeness: Does the plan deliver a fully realized outcome, or a skeleton? Half-built sections, placeholder logic, and "we'll add this later" deferrals must be explicitly flagged and justified.
- Edge case thinking: Has the plan considered what happens when things go wrong, when inputs are unexpected, when state is missing?
- Thoughtfulness: Does the plan reflect genuine understanding of the problem space, or is it a mechanical "add X, modify Y" checklist?
- Consistency & craft: Does the work follow existing patterns and conventions?
- Performance & efficiency: Does the plan consider the cost of what it's adding?
- Source traceability: If the plan was derived from a research doc, design doc, or requirements list — does every item from the source appear in the plan as either a task or an explicit "Deferred: [reason]" entry? Silently dropping items is a FAIL.
- The bar: "Is this work thorough enough that someone reviewing it would find nothing half-done, nothing overlooked, and nothing they'd immediately want to redo?"

---

### Gate 14: Reference Coverage
- **Priority:** P1
- **Applicability:** Projects with a `references/` directory

**Checklist:**
- For each domain the plan touches, identify the corresponding reference file
- Check whether the plan's approach aligns with canonical facts in that reference file
- If the plan would change a `[canonical]` fact, flag that the reference file needs updating in the same wave

---

### Gate 15: Reference Freshness
- **Priority:** P1
- **Applicability:** Projects with a `references/` directory

**Checklist:**
- Flag any reference file that will become stale after implementation
- Ensure the plan schedules reference file updates in the SAME wave as the behavior change
- Check `last-verified` frontmatter if available — flag files not verified in 30+ days

---

### Gate 16: Lessons Surfaced & Applied
- **Priority:** P0
- **Applicability:** Universal when `tasks/lessons.md` exists

**Checklist:**
- For every domain the plan touches, grep lessons.md by domain tag:
  - Plugin/hooks → `grep "Plugin:\|Shell:\|Hook:"`
  - DB/queries → `grep "Database:\|PostgREST:"`
  - Pipeline → `grep "Pipeline:\|Cron:"`
  - Frontend → `grep "Frontend:\|React:"`
  - Auth/security → `grep "Auth:\|Security:"`
  - Migrations → `grep "Migration:\|constraint"`
  - Scoring/signals → `grep "Scoring:\|Signal:"`
- For each matching lesson: quote it verbatim + state **Applies: yes** (how plan addresses it) | **Applies: no** (why not relevant) | **Applies: n/a** (different context).
- Cannot write "no lessons found" without running the grep. Cannot defer to Gate 8.

---

### Gate 17: Decision Pre-Capture
- **Priority:** P1
- **Applicability:** Any plan with non-obvious choices

**Checklist:**
- For each decision:
  1. Write to `.claude/cortex/decisions.local.md` (appending):
     ```
     ## YYYY-MM-DD - [short title]
     category=[architecture|data|UX|pipeline|security] reversibility=[easy|hard|irreversible] confidence=[high|medium|low]
     [1-2 sentence rationale: why this over the alternatives]
     ```
  2. Include a Bash tool call to actually write the entry
  3. Mark capture complete by appending a `decision_logged` event — use the `Session id: <sid>` line from your boot context (never a file, never a guess; this clears stop-gate Gate 7's reminder):
     `SID="<SID-FROM-CONTEXT>" && EIO=$(ls -t ~/.claude/plugins/cache/undercurrent-studio/cortex/*/hooks/scripts/lib/event-io.sh 2>/dev/null | head -1) && [ -n "$EIO" ] && source "$EIO" && resolve_event_log "{\"session_id\":\"${SID}\"}" && append_event decision_logged "true"`
- "No decisions in this plan" is valid ONLY for purely mechanical tasks.

---

### Gate 18: Journal Pre-Entry
- **Priority:** P1
- **Applicability:** Universal

**Checklist:**
- Confirm `memory/YYYY-MM-DD.md` has an entry for this planning session.
- If no entry: write one now (2-4 lines):
  - What is being built and why
  - What approach was chosen vs alternatives
  - Any constraints or risks to remember
  - Tag: `[planning]`

---

## New Gates (19-44)

### Gate 19: Data Source Provenance
- **Priority:** P0
- **Applicability:** Any plan that creates schema to receive external data, adds new data source integrations, or assumes a new field from an existing source

**Checklist:**
1. For every new column/field the plan expects to populate: **what is the specific data source, and does it actually return this data?** Cite one of:
   - A sample API response showing the field (fetched, not assumed)
   - Official API documentation page with the field documented
   - A tested query that returned non-null values
2. If the plan introduces a new parser or transformation: **has the raw input been inspected?** (Not the expected input — the *actual* input from a real API call or file.)
3. If the data source is an aggregation API (like SEC CompanyFacts): **does it aggregate away the detail you need?** Scalar APIs don't provide dimensional breakdowns. Summary APIs don't provide row-level data. Batch APIs may omit optional fields.
4. For JSONB/structured columns: **is the source data actually structured the way the schema assumes?** (e.g., does the API return a typed breakdown, or just a scalar total?)
5. If the answer to any of the above is "I assume so" or "it should" — **FAIL this gate.**

---

### Gate 20: Quantitative Resource Modeling
- **Priority:** P0
- **Applicability:** Any plan with database queries returning multiple rows per entity, batch processing loops, external API calls, or GitHub Actions workflows with timeouts

**Checklist (with arithmetic):**
1. **Row math:** For every database query that returns multiple rows per entity:
   - `expected_entities` = ?
   - `avg_rows_per_entity` = ?
   - `total_rows = expected_entities * avg_rows_per_entity` = ?
   - Is `total_rows < MAX_QUERY_ROWS (50K)`? If not, **the query design is wrong** — don't add .limit(), redesign.
2. **Time math:** For every batch operation:
   - `entity_count` = ? (not the batch size — the FULL universe if the plan can target full universe)
   - `per_entity_time` = ? (include network latency, not just processing)
   - `total_time = entity_count * per_entity_time` = ?
   - Is `total_time < timeout * 0.67` (33% headroom)? If not, the batch size or architecture is wrong.
3. **API call math:** For every external API integration:
   - `calls_per_entity` = ?
   - `entities_per_run` = ?
   - `total_calls = calls_per_entity * entities_per_run` = ?
   - `call_rate = total_calls / expected_duration` = ?
   - Is `call_rate < rate_limit * 0.8` (20% safety margin)?
4. **Scale trajectory:** If the plan works now, will it work at 2x entity count? What's the growth rate? When does it break?
5. **Worst-case vs typical:** The math above uses averages. What's the worst case? (e.g., tickers with 200+ filings instead of the average 44)
6. **Cold start impact:** For serverless (Vercel, Lambda): does the first request include connection establishment, module loading, etc.? Is that accounted for in the time budget?

---

### Gate 21: Verification Path Fidelity
- **Priority:** P1
- **Applicability:** Any plan with database writes, batch processing, or external API integration

**Checklist:**
1. **Operation parity:** For every database operation in the plan:
   - What operation does production use? (INSERT, UPDATE, UPSERT, DELETE)
   - What operation does the test/verification use?
   - Are they the same? If not, **flag it.** (Postgres INSERT rejects fractional BIGINT; UPDATE silently truncates.)
2. **Scale parity:** For every batch operation:
   - What's the test dataset size?
   - What's the production dataset size?
   - If they differ by >10x, does the test cover the scaling edge cases?
3. **Environment parity:** For every external integration:
   - Is the test hitting the real API or a mock?
   - If mocked, does the mock accurately represent the API's behavior for edge cases?
4. **Data type parity:** For every value written to the database:
   - What type does the source return? (float, string, integer)
   - What type does the column expect? (BIGINT, NUMERIC, TEXT)
   - Is coercion happening? If so, is it explicit (Math.round()) or implicit (Postgres casting)?
   - **Does the coercion work the same way for INSERT and UPDATE?** (It doesn't for BIGINT.)
5. **End-to-end path:** Can you trace the data from source API response → transformation → database write → downstream query, and confirm every step is tested together (not just individually)?

---

### Gate 22: Idempotency & Re-Run Safety
- **Priority:** P0
- **Applicability:** Any plan with database writes, external API calls with side effects, email/notification sends, or cron/worker logic

**Checklist:**
1. For every write operation in the plan: is the operation idempotent? (UPSERT = yes, INSERT without UNIQUE constraint = no, counter increment = no, email send = no)
2. If the cron/worker is interrupted mid-batch and re-runs from the start, does the system converge to the correct state or accumulate errors?
3. For operations that are NOT idempotent: what prevents duplicate execution? (Lock? Dedup key? Idempotency token? "Processed" flag?)
4. If a webhook or callback is delivered twice (network retry), does the handler deduplicate? (Undercurrent uses `webhook_events` table for Stripe — does the new feature follow this pattern?)

---

### Gate 23: Temporal Ordering & Race Conditions
- **Priority:** P0
- **Applicability:** Any plan with concurrent execution, cron/worker timing, multi-step database operations, or time-based filtering

**Checklist:**
1. Does the plan assume data from step A is available when step B runs? If so, what enforces that ordering? (Sequential execution? Polling? Explicit dependency?)
2. If two instances of this code run concurrently (overlapping cron, duplicate webhook, user double-click), what happens? Is there a lock, dedup, or at-least-once-is-safe design?
3. Does the plan read a value, make a decision, then write based on that decision? If so, can the read value change between read and write? (TOCTOU)
4. Are there any time-based comparisons (`> now()`, "within last 24h", "today's date")? Do they handle timezone correctly? Are they using UTC consistently?
5. Does the plan involve scheduling (cron expressions, `setTimeout`, `setInterval`)? Has DST behavior been considered?

---

### Gate 24: Partial Failure & Recovery Semantics
- **Priority:** P0
- **Applicability:** Any plan with batch processing, multi-item operations, or sequential pipeline steps

**Checklist:**
1. For every batch operation: if one item fails, do the others still succeed? (`Promise.allSettled` vs `Promise.all`? `batchUpsert` vs raw `.upsert()`?)
2. After a partial failure, is the system in a consistent state? Can the next run complete what was missed, or are failed items permanently lost?
3. Are independent operations sharing error fate? (Two operations that don't depend on each other should NOT be in the same try/catch)
4. If a batch is interrupted (timeout, crash), is there a checkpoint so the next run starts where this one stopped, or does it restart from scratch?
5. For multi-step operations (fetch → transform → write): if the write fails, is the fetch result lost? Should it be cached/staged?
6. Do workers compete for the same database connections or API rate limits? If multiple workers or cron runs could overlap, is there a lock mechanism?

---

### Gate 25: Data Volume & Cardinality Awareness
- **Priority:** P0
- **Applicability:** Any plan with database queries returning multiple rows, batch processing, or aggregation functions

**Checklist:**
1. For every database query in the plan, state the expected row count: `[entity count] * [rows per entity] = [total]`. Is that total under the PostgREST `max_rows` (50K)?
2. For every aggregation or window function: is it operating on the correct population? (Per-ticker, not per-ticker-date?)
3. For every loop or batch: what's the entity count at current scale? At 2x? At full universe (~6K tickers, ~10K including delisted)?
4. Does the plan handle the difference between "typical" and "worst case"? (AAPL has 200+ insider transactions; a small-cap has 2.)
5. Are there any `SELECT *` or unbounded queries? What's their worst-case result size?
6. If the query results feed a `new Set()` or deduplication step: **the fact that you need dedup is a design smell. Can you restructure to avoid needing it?**
7. If the query has no explicit ORDER BY: **is the implicit ordering acceptable?** Postgres doesn't guarantee order without ORDER BY. Could missing rows at the end of an unordered, truncated result set cause systematic bias?

---

### Gate 26: Observability & Failure Detectability
- **Priority:** P1
- **Applicability:** Any plan that adds new data sources, new pipeline steps, new background workers, or new cron jobs

**Checklist:**
1. For each new data flow: what metric or log would change if this silently stopped working? (Not "an error would be logged" — what if the error is swallowed?)
2. If the data source starts returning empty/partial results instead of errors, how would you detect it? (Freshness check? Row count assertion? Downstream anomaly?)
3. Is there a `data_source_health` entry for any new data source? Does the pipeline checkpoint track it?
4. For background workers: if the worker runs but processes 0 records, is that logged as a warning or silently treated as success?
5. What is the maximum time this feature could be broken before anyone notices? Is that acceptable?

---

### Gate 27: Data Freshness & Staleness Contracts
- **Priority:** P1
- **Applicability:** Any plan that reads or serves data to users, computes derived metrics, or introduces caching

**Checklist:**
1. For each data source the plan reads: what's the maximum staleness? (How often is it refreshed? What's the worst-case gap?)
2. If a data source stops updating, does the plan's feature degrade gracefully or serve stale data silently?
3. Does the UI/output indicate data freshness? (Timestamps, "as of", freshness badges?) If not, should it?
4. If the plan adds a new computed metric: what's its effective freshness? (The stalest input determines the output freshness.)
5. For cached data: what's the total staleness = source refresh interval + cache TTL + any additional propagation delay?

---

### Gate 28: Upstream Contract & Dependency Stability
- **Priority:** P1
- **Applicability:** Any plan that integrates with external APIs, upgrades dependencies, or parses external data formats

**Checklist:**
1. Does the plan depend on an external API? Is it documented/stable (e.g., SEC EDGAR) or unofficial/volatile (e.g., Yahoo Finance)?
2. If the API response adds a new field, changes a field type, or removes a field — what happens? Does the code validate/filter or pass through blindly?
3. Is there a fallback if the primary data source is unavailable? (Finnhub as Yahoo fallback, for example.)
4. Does the plan lock to a specific API version or library version? If not, could a dependency update break it?
5. For npm packages wrapping external APIs: when was the package last updated? Is it maintained? Are there known breaking changes in the changelog?

---

### Gate 29: Implicit Coupling & Hidden Dependencies
- **Priority:** P1
- **Applicability:** Any plan that modifies shared infrastructure (database tables, cache keys, utility functions, constants, types)

**Checklist:**
1. Does the plan write to a database table that other systems also read? If so, are those read patterns compatible with the new write pattern? (Schema, timing, volume.)
2. Does the plan introduce or modify cache invalidation? Are ALL write paths that affect this cache covered?
3. Does the plan depend on another system's output being available at a certain time? Is that dependency documented and enforced?
4. If you grep the codebase for the table/cache/API the plan touches, do you find other consumers that will be affected by this change?
5. Does the plan modify a shared utility function, constant, or type? What other call sites exist?

---

### Gate 30: Downstream Consumer Impact
- **Priority:** P1
- **Applicability:** Any plan that modifies database table schemas, API response shapes, or computation methods for existing features

**Checklist:**
1. For every table the plan writes to: what code paths SELECT from it? (Use grep/LSP to find all consumers.)
2. For every API response the plan modifies: are there frontend components, export features, or external consumers that depend on the current shape?
3. If the plan changes the semantics of a column (same name, different meaning): do downstream consumers need updating?
4. If the plan adds new nullable columns: do all consumers handle NULL for that column?
5. Does the plan's change require cache invalidation for downstream consumers? Are all relevant cache tags covered?

---

### Gate 31: Rollback & Forward-Fix Safety
- **Priority:** P1
- **Applicability:** Any plan with database migrations, data transformations, or schema changes

**Checklist:**
1. If this feature needs to be reverted after deployment, what's the rollback plan for each migration?
2. Are there any destructive migrations (DROP COLUMN, ALTER TYPE, NOT NULL without default)? If so, is the plan using expand-contract (add new → migrate data → drop old)?
3. For data transformations: is the original data preserved, or is it transformed in place? (In-place = irreversible.)
4. If the feature is disabled via feature flag or code revert, does the database state remain compatible with the previous code version?
5. For seed data or one-time scripts: can they be safely re-run? (Idempotent seed data.)

---

### Gate 32: Environment & Deployment Divergence
- **Priority:** P2
- **Applicability:** Any plan that adds new API integrations, shell scripts, GH Actions workflows, or env vars

**Checklist:**
1. Does the plan introduce any new external API calls? Have they been tested from the target execution environment (Vercel, GH Actions), not just locally?
2. Are there new env vars? Are they configured in ALL environments (local `.env`, Vercel dashboard, GH Actions secrets)?
3. Does the plan assume file system access, local state, or specific OS behavior? (Serverless = stateless. GH Actions = Linux. Local dev = Windows.)
4. If the plan adds a new GH Actions workflow: does the runner have the required tools installed?
5. For shell scripts: are they POSIX-compatible or do they use bash-specific features?

---

### Gate 33: Attack Surface Delta
- **Priority:** P1
- **Applicability:** Any plan that adds API endpoints, accepts user input, integrates third-party services, or modifies auth logic

**Checklist:**
1. Does the plan add any new endpoints? For each: what data does it expose? Could that data be sensitive in aggregate even if individual fields are not?
2. Does the plan accept new user input (forms, query params, file uploads)? Is every input validated with specific constraints (not just "is present")?
3. Does the plan add new third-party dependencies? What's their security reputation? Do they have known CVEs?
4. Does the plan create any new paths from unauthenticated context to sensitive data?
5. Does the plan log any user data that shouldn't be in logs? (Emails, IPs, financial data in error messages?)

---

### Gate 34: Monotonicity & Data Regression Guards
- **Priority:** P1
- **Applicability:** Any plan that computes scores, rankings, trends, or time-series metrics

**Checklist:**
1. Can the plan's output value decrease/change purely because an input became unavailable (not because the underlying reality changed)?
2. If a data source is temporarily unavailable, does the feature fall back to the last known value, return null, or return a misleadingly low value?
3. For time-series data: does the plan handle gaps? (Missing data points should be interpolated, held forward, or explicitly marked as gaps — not silently treated as 0.)
4. If the plan changes a computation formula: are historical values still comparable? Should historical data be recomputed or flagged?

---

### Gate 35: External Timing & Calendar Awareness
- **Priority:** P2
- **Applicability:** Any plan that displays financial data with time context, processes data with periodic availability, or computes time-windowed metrics

**Checklist:**
1. Does the plan depend on data that arrives on a schedule (quarterly filings, weekly COT, monthly French factors)? Is the feature designed to handle the gap between releases?
2. Are there market holidays or non-trading days where the plan's data sources won't update? Does the plan handle this gracefully?
3. If the plan involves reporting lags (congressional 45-day, 13F quarterly): does the UI communicate this to the user?
4. For time-windowed features ("last 30 days"): does the window account for weekends and holidays?

---

### Gate 36: Type Coercion Boundary Analysis
- **Priority:** P1
- **Applicability:** Any plan that writes data to a database from an external source, especially when mixing BIGINT/NUMERIC columns

**Checklist:**
1. **Source-to-storage type trace:** For each field being written to the database:
   - Source type (API returns): float? string? integer? null?
   - Application type (TypeScript): number? string? bigint?
   - Database type (Postgres): BIGINT? NUMERIC? TEXT? JSONB?
   - At each boundary, is the conversion explicit or implicit?
2. **Coercion hazards by column type:**
   - BIGINT: Does `Math.round()` wrap every value?
   - NUMERIC: Are precision/scale appropriate?
   - JSONB: Is the structure validated before insertion?
   - TEXT: Are there length limits that could truncate?
3. **Operation-dependent behavior:**
   - Does the column behave the same on INSERT and UPDATE? (BIGINT silently truncates on UPDATE but rejects on INSERT.)
   - Does the column behave the same on UPSERT's INSERT path vs UPDATE path?
4. **Null vs missing vs zero:**
   - If the source returns `null`, `undefined`, `0`, or omits the field entirely — are all four handled?
   - Do they all map to the correct database value?

---

### Gate 37: Success Criteria Definition
- **Priority:** P0
- **Applicability:** Every plan

**Checklist:**
1. What metric or behavior changes when this is successfully deployed?
2. How soon after deployment can you confirm success? (Immediately? After next pipeline run? After a week?)
3. What would failure look like, and how quickly would you detect it?

---

### Gate 38: Blast Radius Assessment
- **Priority:** P0
- **Applicability:** Any plan that modifies shared infrastructure, pipeline logic, or database writes

**Checklist:**
1. If this plan's code throws an unhandled exception, what is the blast radius? (One component? One page? The entire pipeline? All users?)
2. Is the blast radius contained? (Error boundary? Try/catch? Separate worker?)
3. If the blast radius is "all users" or "entire pipeline," is there a circuit breaker or failsafe?

---

### Gate 39: Premortem
- **Priority:** P0
- **Applicability:** Every plan

**Checklist:**
1. "Assume this plan was implemented exactly as written and failed catastrophically in production. Write 3 specific, plausible reasons it failed — focusing on things the other gates might not catch."

---

### Gate 40: Invariant Preservation
- **Priority:** P1
- **Applicability:** Any plan that adds new write paths, modifies computations, or changes data flow

**Checklist:**
1. What constraints must remain true after this change? (Score ranges, uniqueness, FK relationships, data freshness, etc.)
2. Does the plan explicitly preserve each constraint, or does it rely on the assumption that existing code handles them?
3. If a new code path is added, does it enforce the same invariants as existing paths?

---

### Gate 41: Precedent Check
- **Priority:** P1
- **Applicability:** Any plan that creates new utilities, new data pipelines, new UI patterns, or new integration patterns

**Checklist:**
1. Does a working implementation of this pattern already exist in the codebase? (Search for similar file names, function signatures, or data flow patterns.)
2. If yes, does the plan reuse it? If not, why not?
3. If a similar feature was attempted and abandoned, what went wrong?

---

### Gate 42: Ripple Effect Trace
- **Priority:** P1
- **Applicability:** Any plan that modifies shared code, database schemas, cache keys, or API contracts

**Checklist:**
1. For each file the plan modifies, what other files import from or depend on it?
2. For each database column the plan changes, what queries read it?
3. For each cache key the plan affects, what code paths invalidate it?
4. Are all affected downstream paths updated in the plan, or are they assumed to "just work"?

---

### Gate 43: AI-ism Smell Test
- **Priority:** P1
- **Applicability:** All plans (LC/UX for customer-facing; CQ/AR for code; PP/ST for all plans)

**Quick check (all plans — ST-1 and ST-2):**
- **ST-1**: Would a senior engineer under deadline pressure produce this plan? If it feels too thorough, too balanced, too polished — it probably needs more opinion and less coverage.
- **ST-2**: Is there anything surprising or opinionated in the plan? If every choice is "the safe choice," the plan likely lacks human judgment.

**Full check (when customer-facing or significant code — load @context/ai-ism-taxonomy.md):**

Language and Copy (LC-1 through LC-4):
- LC-1: Any user-facing text contain forbidden AI words? (comprehensive, robust, leverage, seamless, delve, innovative, etc.)
- LC-2: Same sentence structure repeated in UI copy?
- LC-3: Error messages specific to the failure, or generic?
- LC-4: Text starts with "In today's..." or rhetorical question openers?

Code Quality (CQ-1 through CQ-5):
- CQ-1: Comments explain *what* instead of *why*?
- CQ-2: Utility functions only used once?
- CQ-3: Try/catch at every level instead of boundaries?
- CQ-4: Abstract classes with one implementation?
- CQ-5: Naming reflects domain or generic? (`ScoreEngine` vs `DataProcessor`)

Architecture (AR-1 through AR-5):
- AR-1: Suspiciously symmetric phases?
- AR-2: Abstractions for "future extensibility" with no second use case?
- AR-3: Every entity gets identical treatment regardless of complexity?
- AR-4: Everything configurable when values never change?
- AR-5: Error handling uniform regardless of actual risk?

UX (UX-1 through UX-3):
- UX-1: Empty/error/loading states specific or generic templates?
- UX-2: Tooltips concise or documentation paragraphs?
- UX-3: Visual hierarchy present or everything equally weighted?

Process (PP-1 through PP-4):
- PP-1: Plan has an opinion or presents all options equally?
- PP-2: Time estimates specific and asymmetric, or round and equal?
- PP-3: Plan addresses 1-2 real risks, or lists 5 of equal weight?
- PP-4: Plan skips trivial steps, or treats setup as a phase?

---

### Gate 44: Product-Value Alignment
- **Priority:** P1
- **Applicability:** Plans that add new features or significantly rework existing ones. Does NOT apply to bug fixes, refactors, or infrastructure changes.

**Checklist:**
1. What user need does this change address? Is there evidence the need exists?
2. If this feature worked perfectly, would a user notice? Would they care?
3. Is this the simplest change that addresses the need?
4. Does this change the user's mental model of how the product works? If so, is that intentional?
5. Is the implementation cost proportional to the value delivered?
