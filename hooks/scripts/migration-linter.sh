#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# No state-io.sh source: this linter uses ONLY extract_json_field + escape_for_json
# (it never touches PROJECT_DIR or any state-io constant). Sourcing state-io.sh
# would run migrate_state_files() at SOURCE time (mkdir sessions/, write
# .migrated-v3.7) — a side effect this pure content linter has no reason to
# cause, and one that broke mid-session opt-in inertness (Codex I-1).
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh" || { printf '{}'; exit 0; }

# Buffer stdin
input=$(cat)

# Extract file path
file_path=$(echo "$input" | extract_json_field "tool_input.file_path")
file_path=$(echo "$file_path" | sed 's|\\\\|/|g')

# Early exit: not a migration file
case "$file_path" in
  *supabase/migrations/*) ;;
  *) printf '{}'; exit 0 ;;
esac

# Extract content (Write→content, Edit→new_string)
content=$(echo "$input" | extract_json_field "tool_input.content")
if [ -z "$content" ]; then
  content=$(echo "$input" | extract_json_field "tool_input.new_string")
fi
[ -z "$content" ] && { printf '{}'; exit 0; }

# CHECK 1: IMMUTABLE violation — DENY
# now(), CURRENT_DATE, clock_timestamp() in WHERE clause
if echo "$content" | grep -iE 'WHERE[^;]*\b(now\(\)|CURRENT_DATE|clock_timestamp\(\))' >/dev/null 2>&1; then
  msg=$(escape_for_json "BLOCKED: now()/CURRENT_DATE/clock_timestamp() detected in WHERE clause. These functions are NOT IMMUTABLE — PostgreSQL rejects them in partial index predicates.. Use a materialized column or remove the time condition from the WHERE clause. See migration-safety skill.")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}' "$msg"
  exit 0
fi

# Collect warnings
warnings=""

# CHECK 2: CREATE TABLE without RLS
if echo "$content" | grep -iE 'CREATE\s+TABLE' >/dev/null 2>&1; then
  if ! echo "$content" | grep -iE 'ENABLE\s+ROW\s+LEVEL\s+SECURITY' >/dev/null 2>&1; then
    warnings="${warnings}- Missing ENABLE ROW LEVEL SECURITY for new table.\n"
  fi

  # CHECK 3: Missing GRANT
  if ! echo "$content" | grep -iE 'GRANT\s+.*\s+TO\s+' >/dev/null 2>&1; then
    warnings="${warnings}- Missing GRANT statement for new table (need at minimum: GRANT SELECT ON ... TO authenticated, service_role).\n"
  fi
fi

# CHECK 4: DROP CONSTRAINT without IF EXISTS
if echo "$content" | grep -iE 'DROP\s+CONSTRAINT' >/dev/null 2>&1; then
  if ! echo "$content" | grep -iE 'DROP\s+CONSTRAINT\s+IF\s+EXISTS' >/dev/null 2>&1; then
    warnings="${warnings}- DROP CONSTRAINT without IF EXISTS. Auto-generated constraint names vary between environments. Use dual-name pattern:\n  ALTER TABLE t DROP CONSTRAINT IF EXISTS explicit_name;\n  ALTER TABLE t DROP CONSTRAINT IF EXISTS auto_generated_name;\n"
  fi
fi

# CHECK 5: INSERT without FK safety guard
if echo "$content" | grep -iE 'INSERT\s+INTO' >/dev/null 2>&1; then
  if ! echo "$content" | grep -iE 'WHERE\s+EXISTS' >/dev/null 2>&1; then
    warnings="${warnings}- INSERT INTO without WHERE EXISTS FK safety guard. If inserting rows with foreign keys, use a CTE with WHERE EXISTS to skip missing references.\n"
  fi
fi

if [ -n "$warnings" ]; then
  msg=$(escape_for_json "Migration warnings:\n${warnings}See migration-safety skill for details.")
  printf '{"systemMessage":"%s"}' "$msg"
  exit 0
fi

printf '{}'
exit 0
