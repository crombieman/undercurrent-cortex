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

# _eio_extract_sid "<hook_stdin_json>"
# Echoes the session_id from the hook JSON (empty string if absent/malformed).
# 3-tier jq -> python3 -> POSIX-awk fallback (the awk tier must stand alone —
# Codex I-3). Factored out of resolve_event_log so the native-marker
# suppression check (spec I-2) can prove same-session liveness without
# re-resolving the whole event log.
_eio_extract_sid() {
  local json="${1:-}" sid=""
  [ -n "$json" ] || { echo ""; return 0; }
  # || true inside each substitution: jq/python3 exit non-zero on malformed
  # JSON, and under the callers' set -euo pipefail a failing assignment kills
  # the whole hook (contract violation: hooks always exit 0 with JSON).
  if command -v jq >/dev/null 2>&1; then
    sid=$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi
  if [ -z "$sid" ] && command -v python3 >/dev/null 2>&1; then
    sid=$(printf '%s' "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || true)
  fi
  if [ -z "$sid" ]; then
    # POSIX-awk match() + first-line-first-match: tolerates pretty-printed
    # JSON (spaces/newlines around ":") and prefers the FIRST occurrence of
    # a duplicated key. No jq/python3 dependency.
    sid=$(printf '%s' "$json" | awk '
      match($0, /"session_id"[[:space:]]*:[[:space:]]*"[^"]*"/) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"session_id"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    ' 2>/dev/null) || true
  fi
  echo "$sid"
}

# resolve_event_log "<hook_stdin_json>"
# Sets EVENT_LOG from session_id in the JSON. Empty session_id => EVENT_LOG=""
# (appends require an attributable session; spec §3.4). Never creates directories.
resolve_event_log() {
  local json="${1:-}" sid=""
  EVENT_LOG=""
  sid=$(_eio_extract_sid "$json")
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

# eio_health_file / eio_proposals_file
# Public path-constant helpers — thin wrappers over the cortex dir (W4:
# consolidates the ".claude/cortex/<file>" derivation that used to be
# re-inlined independently in context-flow.sh, statusline.sh, and
# session-end-dispatch.sh).
eio_health_file() {
  echo "$(_eio_cortex_dir)/health.local.md"
}

eio_proposals_file() {
  echo "$(_eio_cortex_dir)/proposals.local.md"
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

# eio_unresolved_items <file> [file...]
# Echoes UNRESOLVED carry-over item texts, one per line, deduped (each item text
# appears once even if carried in multiple logs), in first-seen order across the
# given files. Single source of truth for carry-over reconciliation (stop-gate
# Gate 4, pre-compact, session-start cross-log scan).
#
# Semantics (spec §3.5 amendment — epoch ordering): an item is UNRESOLVED iff the
# epoch (field 1) of its LATEST carry_over event is STRICTLY GREATER than the epoch
# of the latest carry_addressed event whose value equals the item's eio_item_hash.
# No matching carry_addressed => unresolved. Equal epochs => RESOLVED (addressed
# wins ties). Re-raising identical text after addressing resurrects the item.
# Multi-file: epochs compare GLOBALLY (latest carry anywhere vs latest addressed
# anywhere).
eio_unresolved_items() {
  local -a files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0

  # One awk pass over all files → a merged, tab-delimited stream:
  #   epoch<TAB>C<TAB>value   for carry_over lines
  #   epoch<TAB>A<TAB>value   for carry_addressed lines  (value = the item hash)
  # CRLF-stripped, malformed lines skipped via the same line-format guard as the
  # other readers. Epochs are global, so no per-file separation is needed.
  local stream
  stream=$(awk '
    { sub(/\r$/, "") }
    !/^[0-9]+\|[a-z_]+\|/ { next }
    {
      ep = substr($0, 1, index($0, "|") - 1)
      rest = substr($0, index($0, "|") + 1)
      t = substr(rest, 1, index(rest, "|") - 1)
      v = substr(rest, index(rest, "|") + 1)
      if (t == "carry_over")            print ep "\tC\t" v
      else if (t == "carry_addressed")  print ep "\tA\t" v
    }
  ' "${files[@]}")

  # Fold the stream: per-hash latest carry epoch, latest addressed epoch, and the
  # first-seen carry text. Item counts are tens — linear lookups are ample.
  local -A carry_ep=() addr_ep=() text_of=()
  local -a order=()
  local ep flag val h
  while IFS=$'\t' read -r ep flag val; do
    [ -n "$ep" ] || continue
    if [ "$flag" = "C" ]; then
      h=$(eio_item_hash "$val")
      if [ -z "${text_of[$h]+set}" ]; then
        text_of[$h]="$val"
        order+=("$h")
      fi
      if [ -z "${carry_ep[$h]+set}" ] || [ "$ep" -gt "${carry_ep[$h]}" ]; then
        carry_ep[$h]="$ep"
      fi
    elif [ "$flag" = "A" ]; then
      # carry_addressed value IS the item hash (see append sites).
      h="$val"
      if [ -z "${addr_ep[$h]+set}" ] || [ "$ep" -gt "${addr_ep[$h]}" ]; then
        addr_ep[$h]="$ep"
      fi
    fi
  done <<< "$stream"

  # Emit items whose latest carry epoch strictly exceeds their latest addressed
  # epoch (or that were never addressed), in first-seen order.
  local ce ae
  for h in "${order[@]}"; do
    ce="${carry_ep[$h]}"
    ae="${addr_ep[$h]:-}"
    if [ -z "$ae" ] || [ "$ce" -gt "$ae" ]; then
      printf '%s\n' "${text_of[$h]}"
    fi
  done
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

# --- Wave 4 helpers (per-project config.local, spec §7.1) ---

# eio_config_get <key> [default]
# Reads $(_eio_cortex_dir)/config.local — a project-local file for vocabulary
# that must NOT be hardcoded into the public plugin (architectural_patterns,
# docs_file, lessons_file, test_command, commit_nudge_threshold). Format:
# "key=value" lines. FIRST match wins on a repeated key. Lines whose first
# non-whitespace char is '#' are comments and are skipped. Trailing \r is
# stripped before parsing (Windows-authored config files). The value is
# EVERYTHING after the FIRST '=' on the line, so values may themselves
# contain '=' or '|' (e.g. an ERE alternation). Missing file or missing key
# => echoes <default> (empty string if omitted). A key present with an empty
# value ("key=") echoes empty — NOT the default; only an absent key falls
# back. Errexit-safe: the awk lookup's exit status is captured via `|| ...`,
# never left bare under the callers' set -euo pipefail.
eio_config_get() {
  local key="$1" default="${2:-}" file
  file="$(_eio_cortex_dir)/config.local"
  [ -f "$file" ] || { echo "$default"; return 0; }

  local val="" hit=1
  val=$(KEY="$key" awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      eq = index(line, "=")
      if (eq == 0) next
      k = substr(line, 1, eq - 1)
      if (k != ENVIRON["KEY"]) next
      print substr(line, eq + 1)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file" 2>/dev/null) || hit=0

  if [ "$hit" -eq 1 ]; then
    echo "$val"
  else
    echo "$default"
  fi
}
