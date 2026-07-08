#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# event-io.sh (NOT state-io.sh): this routed sub-handler only needs PROJECT_DIR.
# state-io.sh runs migrate_state_files() at SOURCE time (mkdir sessions/, write
# .migrated-v3.7) — sourcing it here would make mid-session opt-in leak side
# effects even when this session has no event log (Codex I-1).
source "$SCRIPT_DIR/lib/event-io.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/json-extract.sh" || { printf '{}'; exit 0; }
source "$SCRIPT_DIR/lib/escape-json.sh" || { printf '{}'; exit 0; }

PROJECT_DIR="$(eio_project_dir)"

# Read stdin JSON, extract file path
file_path=$(cat | extract_json_field "tool_input.file_path")
file_path=$(echo "$file_path" | sed 's|\\|/|g')

[ -z "$file_path" ] && { printf '{}'; exit 0; }

# Match path pattern to curated exemplar
# Projects can override by placing exemplar files in .claude/exemplars/
exemplar=""
pattern_name=""

EXEMPLAR_DIR="${PROJECT_DIR}/.claude/exemplars"

# Generic pattern matching — check for project-provided exemplars first
if [ -d "$EXEMPLAR_DIR" ]; then
  # Extract the file extension and directory pattern
  basename_file=$(basename "$file_path")
  ext="${basename_file##*.}"

  # Look for exemplar files matching the extension
  for candidate in "$EXEMPLAR_DIR"/*."$ext"; do
    if [ -f "$candidate" ]; then
      exemplar="$candidate"
      pattern_name="$(basename "$candidate" | sed 's/\.[^.]*$//' | tr '-' ' ' | tr '_' ' ')"
      break
    fi
  done
fi

# Guard: exemplar file must exist
[ -z "$exemplar" ] || [ ! -f "$exemplar" ] && { printf '{}'; exit 0; }

# Read first 50 lines of exemplar
snippet=$(head -50 "$exemplar" 2>/dev/null || true)
[ -z "$snippet" ] && { printf '{}'; exit 0; }

# Build and output systemMessage
exemplar_basename=$(basename "$exemplar")
header="${pattern_name} convention reference (from ${exemplar_basename}):"
escaped=$(escape_for_json "${header}

${snippet}")

printf '{"systemMessage":"%s"}' "$escaped"
exit 0
