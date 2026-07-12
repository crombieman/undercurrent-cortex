#!/usr/bin/env bash
# Codebase Drift Detector — SessionStart async hook
# Runs 1 of 2 rotating spot-checks per session (day-of-year mod 2).
# Silent when clean. Reports drift as additional_context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# event-io.sh (not state-io.sh): state-io.sh runs migrate_state_files() at
# SOURCE TIME, which does mkdir -p on .claude/cortex/ unconditionally (unless
# already migrated) — a side effect that would fire before the opt-in gate
# below ever gets a chance to run, defeating spec §4.3's "zero directory
# creation in un-opted repos" requirement. event-io.sh's _eio_project_dir()
# provides the same PROJECT_DIR value with no source-time side effects.
source "$SCRIPT_DIR/lib/event-io.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh" || { printf '{}'; exit 0; }

# Consume stdin (hook may pass data; we don't need it)
cat > /dev/null 2>&1 || true

# Opt-in gate (spec §4.3): un-opted repos are fully inert. Directory
# existence is NOT the signal — only the explicit sentinel file, written by
# /cortex:setup.
[ -f "$(_eio_cortex_dir)/enabled" ] || { printf '{}'; exit 0; }

# LAB-only (T6 emitter census): drift warnings are advisory treatment.
[ "$(eio_get_profile)" = "lab" ] || { printf '{}'; exit 0; }

PROJECT="$(_eio_project_dir)"

# Rotate checks: day-of-year mod 2 → picks check 0-1
day_of_year=$(date +%j | sed 's/^0*//')
day_of_year="${day_of_year:-1}"
check_index=$(( day_of_year % 2 ))

findings=""

case $check_index in
  0)
    # Check: Bare process.env usage outside env.ts (server-side only)
    violations=""
    if [ -d "$PROJECT/src" ]; then
      violations=$(grep -rn "process\.env\." "$PROJECT/src" \
        --include="*.ts" --include="*.tsx" \
        2>/dev/null \
        | grep -v "src/lib/env\.ts" \
        | grep -v "__tests__" \
        | grep -v "\.test\." \
        | grep -v "node_modules" \
        | grep -v "NEXT_PUBLIC_" \
        | grep -v "NODE_ENV" \
        | grep -v "NEXT_RUNTIME" \
        | grep -v "instrumentation\.ts" \
        | head -5 \
        || true)
    fi
    if [ -n "$violations" ]; then
      count=$(echo "$violations" | wc -l | tr -d ' ')
      first_file=$(echo "$violations" | head -1 | sed "s|$PROJECT/||" | cut -d: -f1)
      findings="Drift: ${count} server-side process.env usage(s) outside src/lib/env.ts (first: ${first_file}). Route through getServerEnv()."
    fi
    ;;

  1)
    # Check: docs freshness vs src/ commits
    if ! command -v git >/dev/null 2>&1 || [ ! -d "$PROJECT/.git" ]; then
      printf '{}'
      exit 0
    fi
    # Check any of: documentation.md, CLAUDE.md, README.md
    doc_hash=""
    for doc_file in documentation.md CLAUDE.md README.md; do
      if [ -f "$PROJECT/$doc_file" ]; then
        candidate=$(cd "$PROJECT" && git log --format=%H -1 -- "$doc_file" 2>/dev/null || echo "")
        if [ -n "$candidate" ]; then
          # Use the most recently committed doc file
          if [ -z "$doc_hash" ]; then
            doc_hash="$candidate"
          else
            # Compare: use whichever is more recent (closer to HEAD)
            behind_candidate=$(cd "$PROJECT" && git rev-list --count "${candidate}..HEAD" 2>/dev/null || echo "999")
            behind_current=$(cd "$PROJECT" && git rev-list --count "${doc_hash}..HEAD" 2>/dev/null || echo "999")
            if [ "${behind_candidate:-999}" -lt "${behind_current:-999}" ]; then
              doc_hash="$candidate"
            fi
          fi
        fi
      fi
    done
    if [ -z "$doc_hash" ]; then
      printf '{}'
      exit 0
    fi
    commits_behind=$(cd "$PROJECT" && git rev-list --count "${doc_hash}..HEAD" -- src/ 2>/dev/null || echo "0")
    commits_behind=$(echo "$commits_behind" | tr -d ' \r')
    if [ "${commits_behind:-0}" -ge 3 ]; then
      findings="Drift: docs are ${commits_behind} src/ commits behind HEAD. Update docs to reflect recent code changes."
    fi
    ;;
esac

# Output: silent when clean
if [ -z "$findings" ]; then
  printf '{}'
  exit 0
fi

escaped=$(escape_for_json "$findings")

cat <<EOF
{"additional_context":"<drift-detector>${escaped}</drift-detector>"}
EOF
exit 0
