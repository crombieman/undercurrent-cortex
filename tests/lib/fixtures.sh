#!/usr/bin/env bash
# Test fixtures — mock state files, health files, JSON builders, sandbox setup.
# Sourced by test files after test-framework.sh.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# mark_opted_in <claude_dir>
# Stamps the opt-in sentinel (spec §4.3: `.claude/cortex/enabled`, a FILE —
# directory existence is explicitly NOT the signal). Shared by every fixture
# helper that builds a .claude/cortex tree, so any test using them represents
# an opted-in project by default. Idempotent (won't clobber an existing
# sentinel).
#
# FIXED timestamp, deliberately NOT $(date ...): only sentinel PRESENCE gates
# (content is diagnostic), fixed values match this file's other fixtures
# (epoch 1700000000 / 2026-03-14), and — critically — calling `date` here
# hangs test-drift-detector.sh: its create_mock_date mock (mock-commands.sh)
# captures `which date` as the "real" passthrough target, which on the 2nd+
# create_mock_date call is the previous mock itself, so any non-%j date
# invocation inside that suite re-execs itself forever. This fixture runs
# inside that mocked scope via create_state_file.
mark_opted_in() {
  local claude_dir="$1"
  mkdir -p "$claude_dir/cortex"
  [ -f "$claude_dir/cortex/enabled" ] || \
    printf 'enabled %s\n' "2026-03-14T00:00:00Z" > "$claude_dir/cortex/enabled"
}

# create_unopted_dir <claude_dir>
# Creates <claude_dir> ONLY — guarantees no cortex/ subtree exists, and
# therefore no sentinel. Mirrors the "drive-by repo" scenario spec §4.3 warns
# about: a project where hooks ran before opt-in gating existed and left
# .claude/cortex/ behind as a side effect, but never ran /cortex:setup.
# Used by un-opted-repo gate tests (tests/integration/test-opt-in-gate.sh).
# Echoes the path.
create_unopted_dir() {
  local dir="$1"
  mkdir -p "$dir"
  echo "$dir"
}

# create_event_log <claude_dir> <session_id> [event-lines...]
# Creates a v4 append-only event log in the test-week bucket.
# <claude_dir> is the fake .claude dir (same convention as create_state_file).
# Extra args are appended verbatim (caller supplies full "epoch|type|value" lines).
# Echoes the log path.
# Also stamps the opt-in sentinel (spec §4.3) — every fixture-created session
# represents an opted-in project. Un-opted-repo behavior is tested via
# create_unopted_dir, which deliberately never calls this.
create_event_log() {
  local dir="$1" sid="$2"
  shift 2
  mkdir -p "$dir/cortex/sessions/test-week"
  mark_opted_in "$dir"
  local file="$dir/cortex/sessions/test-week/${sid}.events.log"
  printf '%s|session_start|2026-03-14T00:00:00Z test-model\n' "1700000000" > "$file"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
  echo "$file"
}

# _SEED_FILE_EDIT_EPOCH: monotonic counter backing seed_file_edit's epochs.
# Deliberately NOT `date +%s` — see mark_opted_in's comment above on why
# calling `date` from a fixture helper is a landmine (create_mock_date's
# 2nd+ call recursion; now fixed, but a fixture helper used by every
# file_edit-seeding test has no business depending on it either way).
# Base value matches this file's other fixed-epoch conventions.
_SEED_FILE_EDIT_EPOCH=1700000000

# seed_file_edit <log> <flag> <path>
# Appends a well-formed "epoch|file_edit|<flag> <path>" event line to <log>.
# Fixture/production drift guard: REFUSES (returns 1, message to stderr,
# nothing appended) flag "r" paired with a non-absolute <path>. Production
# (post-edit-dispatch.sh) only ever writes flag "r" for a file_path that
# already matched `[[ "$file_path" == "${PROJECT_DIR}"* ]]` — i.e. an
# ABSOLUTE path under the project dir — so an "r" seed with a relative path
# is a fixture lying about a scenario production can't actually produce,
# which can hide a real bug in whatever reads that flag. Flag "x"
# (external/gitignored) has no such constraint.
seed_file_edit() {
  local log="$1" flag="$2" path="$3"
  if [ "$flag" = "r" ]; then
    case "$path" in
      /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;  # absolute: POSIX or Windows drive-letter
      *)
        echo "seed_file_edit: refusing flag 'r' with non-absolute path: $path" >&2
        return 1
        ;;
    esac
  fi
  _SEED_FILE_EDIT_EPOCH=$((_SEED_FILE_EDIT_EPOCH + 1))
  printf '%s|file_edit|%s %s\n' "$_SEED_FILE_EDIT_EPOCH" "$flag" "$path" >> "$log"
}

# set_config <claude_dir> <key> <value>
# Appends a "key=value" line to <claude_dir>/cortex/config.local (spec §7.1
# per-project config, creating the cortex dir + file as needed). Tests that
# rely on the OLD hardcoded Undercurrent vocabulary (architectural_patterns,
# docs_file, lessons_file, ...) must configure it explicitly via this helper
# — the public plugin's defaults are empty/generic (see eio_config_get).
set_config() {
  local claude_dir="$1" key="$2" val="$3"
  mkdir -p "$claude_dir/cortex"
  printf '%s=%s\n' "$key" "$val" >> "$claude_dir/cortex/config.local"
}

# create_state_file <dir> <session_id> [overrides...]
# Creates a well-formed LEGACY v3 state file. Overrides: "field=value" pairs.
# Returns the file path.
# Post-T4 purpose: simulates an INERT legacy artifact on disk (nothing reads
# or writes these anymore — state-io.sh and the legacy carry-over reader are
# deleted). Suites use it to prove leftover v3 files are ignored, not to
# exercise any reader.
create_state_file() {
  local dir="$1" sid="$2"
  shift 2
  mkdir -p "$dir/cortex/sessions/test-week"
  mark_opted_in "$dir"
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
  local dir="$1" date="$2"
  # Split from the local above: under `set -u`, a compound `local a=1 b=$a`
  # evaluates RHS expressions before the earlier names are visible as locals,
  # so referencing $date in the same statement's default value throws
  # "unbound variable" (pre-existing latent bug — every prior caller passed
  # all 3 args, so the default branch was never exercised until now).
  local content="${3:-# Journal - $date}"
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

  # Symlink all libraries (state-io.sh died in the calibration wave T4 —
  # every lib is side-effect-free at source time now, no patching needed)
  for f in "$plugin_root/hooks/scripts/lib/"*.sh; do
    [ -f "$f" ] || continue
    local base
    base=$(basename "$f")
    ln -sf "$f" "$sandbox/hooks/scripts/lib/$base"
  done

  # Create cortex directory structure in sandbox
  mkdir -p "$tmpdir/.claude/cortex/sessions"
  # Opt-in sentinel (spec §4.3) — the sandbox represents an opted-in project.
  # NOTE: this write happens once at sandbox setup, BEFORE any suite's first
  # setup_test() call, which wipes .claude/* per test. Callers that invoke
  # setup_test() between tests must re-stamp per test (e.g. via
  # create_event_log/create_state_file, which call mark_opted_in themselves,
  # or an explicit mark_opted_in call) — this line alone does not survive.
  mark_opted_in "$tmpdir/.claude"

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
