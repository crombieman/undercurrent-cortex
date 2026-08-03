#!/usr/bin/env bash
# JSON field extraction with 3-tier fallback: jq → python3 → bash string ops.
# Supports dotted nested paths (e.g., "tool_input.file_path") via jq and python3.
# Bash fallback extracts by leaf key only — adequate when keys are unique in the JSON.
#
# Usage: echo '{"tool_input":{"file_path":"src/test.ts"}}' | extract_json_field "tool_input.file_path"
# Callers should apply Windows path normalization if needed: sed 's|\\\\|/|g'

# Stub-aware Python resolution for tier 2 (optional accelerator — tier 3
# stands alone regardless). python-resolve.sh is pure function definitions,
# so lib-to-lib sourcing adds no side effects; `|| true` keeps errexit
# callers alive if the file is absent (tier 2 then simply skips).
source "$(dirname "${BASH_SOURCE[0]}")/python-resolve.sh" 2>/dev/null || true

extract_json_field() {
  local field="$1"
  local input
  input=$(cat)  # Buffer stdin — can only be consumed once

  [ -z "$input" ] && { echo ""; return 0; }

  # Tier 1: jq (supports nested paths natively)
  if command -v jq >/dev/null 2>&1; then
    local result
    result=$(echo "$input" | jq -r ".${field} // empty" 2>/dev/null)
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
  fi

  # Tier 2: Python 3 (supports nested via chained .get()) — via the
  # stub-aware resolver: `command -v python3` false-positives on the Windows
  # Store alias (a stub that exits 49 without running Python), so usability
  # is decided by executing candidates, never by PATH presence.
  if declare -F cortex_python3_run >/dev/null; then
    local result
    result=$(echo "$input" | cortex_python3_run "
import sys, json, functools
try:
    data = json.load(sys.stdin)
    keys = sys.argv[1].split('.')
    val = functools.reduce(lambda d, k: d.get(k, '') if isinstance(d, dict) else '', keys, data)
    print(val if val != '' else '')
except:
    print('')
" "$field" 2>/dev/null) || result=""
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
  fi

  # Tier 3: bash/awk string ops (leaf key only — no nesting support).
  # POSIX-awk match() + first-line-first-match: tolerates pretty-printed JSON
  # (spaces/newlines around ":") and prefers the FIRST occurrence of a
  # duplicated key, mirroring event-io.sh's resolve_event_log. No jq/python3
  # dependency — this tier must stand alone (Codex I-3).
  local leaf_key="${field##*.}"
  local result
  result=$(printf '%s' "$input" | LEAF_KEY="$leaf_key" awk '
    {
      key = ENVIRON["LEAF_KEY"]
      pat = "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
      if (match($0, pat)) {
        s = substr($0, RSTART, RLENGTH)
        sub("^\"" key "\"[[:space:]]*:[[:space:]]*\"", "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    }
  ' 2>/dev/null) || true
  if [ -z "$result" ]; then
    # Key not found
    echo ""
    return 0
  fi
  # Unescape basic JSON escapes
  result="${result//\\\"/\"}"
  result="${result//\\\\/\\}"
  echo "$result"
}
