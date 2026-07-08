#!/usr/bin/env bash
# Test fixtures — mock state files, health files, JSON builders, sandbox setup.
# Sourced by test files after test-framework.sh.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# create_event_log <claude_dir> <session_id> [event-lines...]
# Creates a v4 append-only event log in the test-week bucket.
# <claude_dir> is the fake .claude dir (same convention as create_state_file).
# Extra args are appended verbatim (caller supplies full "epoch|type|value" lines).
# Echoes the log path.
create_event_log() {
  local dir="$1" sid="$2"
  shift 2
  mkdir -p "$dir/cortex/sessions/test-week"
  local file="$dir/cortex/sessions/test-week/${sid}.events.log"
  printf '%s|session_start|2026-03-14T00:00:00Z test-model\n' "1700000000" > "$file"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
  echo "$file"
}

# create_state_file <dir> <session_id> [overrides...]
# Creates a well-formed state file. Overrides: "field=value" pairs.
# Returns the file path.
# LEGACY-ONLY (v3 reader tests; delete in 4.2) — the write surface that used
# to produce these files (write_field/increment_field/append_to_section/
# init_state_file) was deleted in the storage-conversion wave; this fixture
# exists only to exercise state-io.sh's remaining read path
# (read_field/read_section) until session-start drops its legacy reader.
create_state_file() {
  local dir="$1" sid="$2"
  shift 2
  mkdir -p "$dir/cortex/sessions/test-week"
  local file="$dir/cortex/sessions/test-week/${sid}.local.md"
  cat > "$file" << 'EOF'
session_id=PLACEHOLDER_SID
session_start=2026-03-14T00:00:00Z
model_name=test-model
commits_count=0
edits_since_last_commit=0
tool_calls_count=0
tests_run=false
docs_updated=false
carry_over_addressed=false
stop_hook_active=false
consecutive_blocks=0
carry_over_age=0
debug=false
mode=normal
commit_nudge_threshold=15
last_sensory_check=
last_remote_head=
last_ci_status=
health_written=false

[files_modified]

[carry_over]

[activity_log]
EOF
  # Replace placeholder session_id
  sed -i "s|session_id=PLACEHOLDER_SID|session_id=${sid}|" "$file"

  # Apply overrides
  for override in "$@"; do
    local key="${override%%=*}"
    local val="${override#*=}"
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  done
  echo "$file"
}

# create_legacy_state_file <dir> [overrides...]
# Creates a legacy (non-session-scoped) state file.
create_legacy_state_file() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local file="$dir/cortex-state.local.md"
  cat > "$file" << 'EOF'
session_id=legacy
session_start=2026-03-14T00:00:00Z
model_name=test-model
commits_count=0
edits_since_last_commit=0
tool_calls_count=0
tests_run=false
docs_updated=false
carry_over_addressed=false
stop_hook_active=false
consecutive_blocks=0
carry_over_age=0
debug=false
mode=normal
health_written=false

[files_modified]

[carry_over]

[activity_log]
EOF
  for override in "$@"; do
    local key="${override%%=*}"
    local val="${override#*=}"
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  done
  echo "$file"
}

# create_health_file <filepath> [data_rows...]
create_health_file() {
  local filepath="$1"
  shift
  cat > "$filepath" << 'HEADER'
# Cortex Health Log
# Fields: date|reasoning_misses|edits_per_commit|docs_synced|tests_delta|lessons_created|carry_resolved|carry_total|duration_min|max_re_edits|topology|domain_tag
trend_direction=stable
avg_reasoning_misses=0.0
avg_edits_per_commit=0.0
avg_duration_min=0
---
HEADER
  for row in "$@"; do
    echo "$row" >> "$filepath"
  done
}

# create_proposals_file <filepath> <proposal_blocks...>
# Each block: "id|status|type|target|summary|body"
create_proposals_file() {
  local filepath="$1"
  shift
  mkdir -p "$(dirname "$filepath")"
  > "$filepath"
  for block in "$@"; do
    local id status ptype target summary body
    IFS='|' read -r id status ptype target summary body <<< "$block"
    cat >> "$filepath" << EOF
id=${id}
status=${status}
type=${ptype}
target=${target}
surfaced_count=0
**Summary**: ${summary}
**Body**: ${body}
---
EOF
  done
}

# create_cross_session_file <filepath> <entries...>
# Each entry: "filepath|count|date"
create_cross_session_file() {
  local filepath="$1"
  shift
  echo "# Cross-Session File Edit Tracker" > "$filepath"
  echo "# Format: filepath|session_count|last_session_date" >> "$filepath"
  for entry in "$@"; do
    echo "$entry" >> "$filepath"
  done
}

# mock_json <fields...>
# Builds a JSON string. Top-level: "key=value". Nested: "parent.child=value".
mock_json() {
  local result="{"
  local first=true
  local nested_pairs=()

  for field in "$@"; do
    local key="${field%%=*}"
    local val="${field#*=}"

    if [[ "$key" == *.* ]]; then
      nested_pairs+=("$field")
      continue
    fi

    [ "$first" = true ] && first=false || result+=","
    result+="\"${key}\":\"${val}\""
  done

  # Group nested keys by prefix
  local current_prefix=""
  local nested_started=false
  for nk in "${nested_pairs[@]}"; do
    local full_key="${nk%%=*}"
    local nval="${nk#*=}"
    local prefix="${full_key%%.*}"
    local subkey="${full_key#*.}"

    if [ "$prefix" != "$current_prefix" ]; then
      [ "$nested_started" = true ] && result+="}"
      [ "$first" = true ] && first=false || result+=","
      result+="\"${prefix}\":{\"${subkey}\":\"${nval}\""
      current_prefix="$prefix"
      nested_started=true
    else
      result+=",\"${subkey}\":\"${nval}\""
    fi
  done
  [ "$nested_started" = true ] && result+="}"

  result+="}"
  echo "$result"
}

# create_context_dir <parent_dir>
# Creates mock context files for context-flow testing.
create_context_dir() {
  local parent="$1"
  mkdir -p "$parent/context"
  printf '%s\n%s\n' "keywords: scoring,v10,v11,pillar,percentile,subfactor,bayesian" "Scoring architecture context loaded" > "$parent/context/scoring-architecture.md"
  printf '%s\n%s\n' "keywords: migration,alter table,create table,add column" "Migration lessons context loaded" > "$parent/context/migration-lessons.md"
  printf '%s\n%s\n' "keywords: pipeline,cron,sync-tickers,run-pipeline,sentiment worker" "Pipeline constraints context loaded" > "$parent/context/pipeline-constraints.md"
  printf '%s\n%s\n' "keywords: deploy,vercel,go live,push to prod,production,ship it" "Deploy readiness context loaded" > "$parent/context/deploy-readiness.md"
  printf '%s\n%s\n' "keywords: vitest,test suite,write test,add test,run test,fix test,coverage" "Testing conventions context loaded" > "$parent/context/testing-conventions.md"
  printf '%s\n%s\n' "keywords: stripe,checkout,subscription,payment,billing,webhook" "Payment integration context loaded" > "$parent/context/payment-integration.md"
  printf '%s\n%s\n' "keywords: formula,statistics,probability,monte carlo,sigmoid,z-score" "Math review context loaded" > "$parent/context/math-review.md"
  printf '%s\n%s\n' "keywords: typescript,type error,tsc,nouncheckedindexedaccess,type guard" "TypeScript discipline context loaded" > "$parent/context/typescript-discipline.md"
  printf '%s\n%s\n' "keywords: python,pyproject.toml,venv,pytest,django,flask,fastapi,poetry,ruff,mypy,pydantic" "Python patterns context loaded" > "$parent/context/python-patterns.md"
  printf '%s\n%s\n' "keywords: golang,go.mod,goroutine,go.sum,cobra,fiber" "Go patterns context loaded" > "$parent/context/go-patterns.md"
  printf '%s\n%s\n' "keywords: rustc,cargo.toml,lifetime,tokio,async-std,serde,clippy,rust-lang" "Rust patterns context loaded" > "$parent/context/rust-patterns.md"
}

# create_journal <dir> <date> [content]
create_journal() {
  local dir="$1" date="$2" content="${3:-# Journal - $date}"
  mkdir -p "$dir/memory"
  echo "$content" > "$dir/memory/${date}.md"
}

# create_mock_migrations <project_dir> <count>
create_mock_migrations() {
  local dir="$1" count="$2"
  mkdir -p "$dir/supabase/migrations"
  for i in $(seq 1 "$count"); do
    local num
    num=$(printf '%03d' "$i")
    touch "$dir/supabase/migrations/${num}_test.sql"
  done
}

# override_state_paths <tmpdir>
# Sets all state-io.sh path variables to point at the test temp dir.
# Call immediately after sourcing state-io.sh in unit tests.
override_state_paths() {
  local dir="$1"
  PROJECT_DIR="$dir"
  STATE_DIR="$dir/.claude"
  CORTEX_DIR="$dir/.claude/cortex"
  SESSIONS_DIR="$dir/.claude/cortex/sessions"
  STATE_FILE="$dir/.claude/cortex/sessions/test-week/fallback.local.md"
  HEALTH_FILE="$dir/.claude/cortex/health.local.md"
  PROPOSALS_FILE="$dir/.claude/cortex/proposals.local.md"
  DECISIONS_FILE="$dir/.claude/cortex/decisions.local.md"
  mkdir -p "$SESSIONS_DIR/test-week"
  export PROJECT_DIR STATE_DIR CORTEX_DIR SESSIONS_DIR STATE_FILE HEALTH_FILE PROPOSALS_FILE DECISIONS_FILE
}

# setup_script_sandbox <tmpdir> [plugin_root]
# Creates a symlinked sandbox mirroring the plugin structure,
# with state-io.sh patched to use tmpdir as PROJECT_DIR.
# Returns the sandbox root path.
setup_script_sandbox() {
  local tmpdir="$1"
  local plugin_root="${2:-$PLUGIN_ROOT}"
  local sandbox="$tmpdir/sandbox"

  # Mirror the directory structure
  mkdir -p "$sandbox/hooks/scripts/lib"
  mkdir -p "$sandbox/context"
  mkdir -p "$sandbox/skills/session-start"
  mkdir -p "$sandbox/skills/session-end"

  # Symlink all real hook scripts
  for f in "$plugin_root/hooks/scripts/"*.sh; do
    [ -f "$f" ] || continue
    ln -sf "$f" "$sandbox/hooks/scripts/$(basename "$f")"
  done

  # Symlink session-start entry point
  if [ -f "$plugin_root/hooks/session-start" ]; then
    ln -sf "$plugin_root/hooks/session-start" "$sandbox/hooks/session-start"
  fi

  # Symlink non-state-io libraries
  for f in "$plugin_root/hooks/scripts/lib/"*.sh; do
    [ -f "$f" ] || continue
    local base
    base=$(basename "$f")
    [ "$base" = "state-io.sh" ] && continue
    ln -sf "$f" "$sandbox/hooks/scripts/lib/$base"
  done

  # Create patched state-io.sh — replace PROJECT_DIR with test tmpdir
  sed "s|^PROJECT_DIR=.*|PROJECT_DIR=\"$tmpdir\"|" \
    "$plugin_root/hooks/scripts/lib/state-io.sh" \
    > "$sandbox/hooks/scripts/lib/state-io.sh"

  # Disable migration in sandbox — no real state files to migrate, saves ~1.5s per invocation
  sed -i 's/^  migrate_state_files$/  #migrate_state_files  # disabled in test sandbox/' \
    "$sandbox/hooks/scripts/lib/state-io.sh"

  # Create cortex directory structure in sandbox
  mkdir -p "$tmpdir/.claude/cortex/sessions"

  # Copy context files (small, read-only)
  for f in "$plugin_root/context/"*.md; do
    [ -f "$f" ] || continue
    cp "$f" "$sandbox/context/$(basename "$f")"
  done

  # Stub skill files
  echo "Session start skill stub" > "$sandbox/skills/session-start/SKILL.md"
  echo "Session end skill stub" > "$sandbox/skills/session-end/SKILL.md"

  # Export CORTEX_PROJECT_DIR pointing at test dir
  export CORTEX_PROJECT_DIR="$tmpdir"

  echo "$sandbox"
}
