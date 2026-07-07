#!/usr/bin/env bash
# event-io.sh — v4 append-only session event log (spec §3).
# Line format: epoch|event_type|value  — value is EVERYTHING after the 2nd pipe.
# NEVER parse values with awk '{print $3}' — values may contain pipes.
# Does NOT source state-io.sh (state-io runs v3.7 migration on source).

# --- Path derivation (self-contained; mirrors state-io without side effects) ---
# Lazy (per-call, not source-time): tests override via CORTEX_PROJECT_DIR_OVERRIDE
# after sourcing, and hooks may run before cwd is settled.
EVENT_LOG="${EVENT_LOG:-}"

_eio_project_dir() {
  echo "${CORTEX_PROJECT_DIR_OVERRIDE:-${CORTEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
}
_eio_cortex_dir()   { echo "$(_eio_project_dir)/.claude/cortex"; }
_eio_sessions_dir() { echo "$(_eio_cortex_dir)/sessions"; }
_eio_week_dir() {
  echo "$(_eio_sessions_dir)/$(date +%G-W%V 2>/dev/null || echo unknown)"
}

# resolve_event_log "<hook_stdin_json>"
# Sets EVENT_LOG from session_id in the JSON. Empty session_id => EVENT_LOG=""
# (appends require an attributable session; spec §3.4). Never creates directories.
resolve_event_log() {
  local json="${1:-}" sid=""
  EVENT_LOG=""
  if [ -n "$json" ]; then
    if command -v jq >/dev/null 2>&1; then
      sid=$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null)
    fi
    if [ -z "$sid" ] && command -v python3 >/dev/null 2>&1; then
      sid=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
    fi
    if [ -z "$sid" ]; then
      local tmp="${json#*\"session_id\":\"}"
      [ "$tmp" != "$json" ] && sid="${tmp%%\"*}"
    fi
  fi
  [ -z "$sid" ] && return 0

  local candidate="$(_eio_week_dir)/${sid}.events.log"
  if [ -f "$candidate" ]; then
    EVENT_LOG="$candidate"
    return 0
  fi
  # Session may span an ISO-week boundary — search all week dirs.
  local d
  for d in "$(_eio_sessions_dir)"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}${sid}.events.log" ]; then
      EVENT_LOG="${d}${sid}.events.log"
      return 0
    fi
  done
  # Not found: leave EVENT_LOG as the current-week candidate ONLY for
  # session-start (which creates it); appends elsewhere no-op on missing file.
  EVENT_LOG="$candidate"
}

# resolve_event_log_readonly — READ-ONLY surfaces only (/status, statusline).
# Falls back to current-session.id when no session_id is available. A singleton
# marker must never route another session's WRITES (spec §3.4).
resolve_event_log_readonly() {
  local json="${1:-}"
  resolve_event_log "$json"
  if [ -z "$EVENT_LOG" ] || [ ! -f "$EVENT_LOG" ]; then
    local marker="$(_eio_cortex_dir)/current-session.id" sid=""
    if [ -f "$marker" ]; then
      sid=$(head -1 "$marker" | tr -d '[:space:]')
      [ -n "$sid" ] && resolve_event_log "{\"session_id\":\"${sid}\"}"
    fi
  fi
}

# append_event <type> <value>
# The ONLY write primitive in the hook path. Writes go to $EVENT_LOG exclusively —
# no file parameter, so call sites can't route writes past resolve_event_log
# (spec §3.4: appends require session_id-based resolution; the readonly resolver
# is for read surfaces only). Log must already exist (session-start creates it):
# makes mid-session opt-in inert and blocks writes in un-opted repos.
append_event() {
  local type="$1" value="${2:-}" file="$EVENT_LOG"
  [ -n "$file" ] || return 0
  [ -f "$file" ] || return 0
  value="${value//$'\r'/}"
  value="${value//$'\n'/ }"
  printf '%s|%s|%s\n' "$(date +%s)" "$type" "$value" >> "$file"
}

# --- Readers: single-pass awk; NR (file) order authoritative; \r-tolerant ---

# count_events <type> [value_prefix] [after_anchor_ere] [file]
# value_prefix matches the FIRST space-token of the value ('' = no filter).
# after_anchor_ere resets the count at each anchor occurrence => "since last anchor".
count_events() {
  local type="$1" prefix="${2:-}" anchor="${3:-}" file="${4:-$EVENT_LOG}"
  [ -n "$file" ] && [ -f "$file" ] || { echo 0; return 0; }
  TYPE="$type" PFX="$prefix" ANCH="$anchor" awk '
    { sub(/\r$/, "") }
    !/^[0-9]+\|[a-z_]+\|/ { next }
    {
      rest = substr($0, index($0, "|") + 1)
      t = substr(rest, 1, index(rest, "|") - 1)
      v = substr(rest, index(rest, "|") + 1)
      if (ENVIRON["ANCH"] != "" && t ~ ("^(" ENVIRON["ANCH"] ")$")) { c = 0; next }
      if (t != ENVIRON["TYPE"]) next
      if (ENVIRON["PFX"] != "") { split(v, a, " "); if (a[1] != ENVIRON["PFX"]) next }
      c++
    }
    END { print c + 0 }
  ' "$file"
}

# last_event <type> [file] — value of the most recent event of type (last-wins).
last_event() {
  local type="$1" file="${2:-$EVENT_LOG}"
  [ -n "$file" ] && [ -f "$file" ] || { echo ""; return 0; }
  TYPE="$type" awk '
    { sub(/\r$/, "") }
    !/^[0-9]+\|[a-z_]+\|/ { next }
    {
      rest = substr($0, index($0, "|") + 1)
      t = substr(rest, 1, index(rest, "|") - 1)
      if (t != ENVIRON["TYPE"]) next
      last = substr(rest, index(rest, "|") + 1)
    }
    END { print last }
  ' "$file"
}

# list_events <type> [file] — all values, one per line, file order.
list_events() {
  local type="$1" file="${2:-$EVENT_LOG}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  TYPE="$type" awk '
    { sub(/\r$/, "") }
    !/^[0-9]+\|[a-z_]+\|/ { next }
    {
      rest = substr($0, index($0, "|") + 1)
      t = substr(rest, 1, index(rest, "|") - 1)
      if (t != ENVIRON["TYPE"]) next
      print substr(rest, index(rest, "|") + 1)
    }
  ' "$file"
}

# --- Wave 2 helpers (event-log append-only migration) ---

# eio_project_dir
# Public alias for _eio_project_dir (echoes the project root).
eio_project_dir() {
  _eio_project_dir
}

# eio_get_profile
# Returns the active Cortex profile: minimal, standard (default), or strict.
# Resolution: CORTEX_PROFILE env → $(_eio_cortex_dir)/profile.local first line → "standard".
eio_get_profile() {
  local profile="${CORTEX_PROFILE:-}"
  if [ -z "$profile" ] && [ -f "$(_eio_cortex_dir)/profile.local" ]; then
    profile=$(head -1 "$(_eio_cortex_dir)/profile.local" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$profile" in
    minimal|strict) echo "$profile" ;;
    *) echo "standard" ;;
  esac
}

# eio_item_hash <text>
# Echoes the cksum CRC of the whitespace-trimmed text.
eio_item_hash() {
  local text="$1"
  printf '%s' "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cksum | awk '{print $1}'
}

# normalize_path "path"
# Normalizes a file path: backslash → forward slash, lowercase drive → uppercase.
# Used to prevent duplicate tracking of the same file with different path formats.
# (Copied verbatim from state-io.sh — pure string logic, no side effects.)
normalize_path() {
  local p="$1"
  # Backslash → forward slash
  p="${p//\\//}"
  # MSYS path /c/Users/... → C:/Users/...
  if [[ "$p" =~ ^/([a-zA-Z])/ ]]; then
    p="${BASH_REMATCH[1]^^}:/${p:3}"
  fi
  # Lowercase drive letter → uppercase (c:/ → C:/)
  if [[ "$p" =~ ^[a-z]:/ ]]; then
    p="${p^}"
  fi
  echo "$p"
}
