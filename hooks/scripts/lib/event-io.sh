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

# eio_last_line_of <type> [value_ere] [file]
# Echoes the 1-based LINE NUMBER of the most recent event of <type> whose
# value matches [value_ere] (POSIX ERE against the LOWERCASED value; empty =
# any value); echoes 0 if none. Line order is the authoritative event order
# (spec §3.2), so callers compare positions — e.g. stop-gate Gate 3's "no
# test_run after the last source file_edit" — never epochs.
eio_last_line_of() {
  local type="$1" vre="${2:-}" file="${3:-$EVENT_LOG}"
  [ -n "$file" ] && [ -f "$file" ] || { echo 0; return 0; }
  TYPE="$type" VRE="$vre" awk '
    { sub(/\r$/, "") }
    !/^[0-9]+\|[a-z_]+\|/ { next }
    {
      rest = substr($0, index($0, "|") + 1)
      t = substr(rest, 1, index(rest, "|") - 1)
      if (t != ENVIRON["TYPE"]) next
      v = substr(rest, index(rest, "|") + 1)
      if (ENVIRON["VRE"] != "" && tolower(v) !~ ENVIRON["VRE"]) next
      last = NR
    }
    END { print last + 0 }
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

# --- Intervention follow-through scoring (wave 4, spec §6.3 / L2 / L11) ---
# The feedback loop grades its own nudges: every intervention event is scored
# against whether the nudged behavior actually followed, derived entirely from
# the same append-only logs (no new files, no stored counters).
#
# Follow-through definitions (line order authoritative, per log):
#   commit_nudge       followed iff a commit event lands while fewer than 5
#                      r-flagged file_edits have elapsed since the nudge
#                      ("within the next 5 material edits, or before session
#                      end if fewer")
#   journal_checkpoint followed iff a journal_edit lands within the next 10
#                      tool_call events
#   re_edit_warning    followed iff the warned path is edited FEWER than 2
#                      more times this session
#   cautious_mode      followed iff the session never goes high-churn (no
#                      single path edited 3+ times across the whole log)
#   codex_reminder     followed iff a codex_review event appears later in the
#                      same session
#
# eio_intervention_report_dirs <sessions_dir> [days]
# Scans <sessions_dir>/*/*.events.log with mtime within [days] (default 30);
# echoes "kind|fired|followed" lines, sorted by kind. Kinds never fired are
# omitted. Public wrapper below defaults to the project's own sessions dir.
eio_intervention_report_dirs() {
  local sessions_dir="$1" days="${2:-30}"
  [ -d "$sessions_dir" ] || return 0
  local cutoff_epoch now_epoch
  now_epoch=$(date +%s)
  cutoff_epoch=$(( now_epoch - days * 86400 ))

  local f f_epoch
  for f in "$sessions_dir"/*/*.events.log; do
    [ -f "$f" ] || continue
    f_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
    if [ "$f_epoch" -gt 0 ] && [ "$f_epoch" -lt "$cutoff_epoch" ]; then
      continue
    fi
    awk '
      { sub(/\r$/, "") }
      !/^[0-9]+\|[a-z_]+\|/ { next }
      {
        rest = substr($0, index($0, "|") + 1)
        t = substr(rest, 1, index(rest, "|") - 1)
        v = substr(rest, index(rest, "|") + 1)
        sp = index(v, " ")
        first = (sp > 0) ? substr(v, 1, sp - 1) : v
        tail  = (sp > 0) ? substr(v, sp + 1)   : ""

        if (t == "intervention") {
          fired[first]++
          if (first == "commit_nudge") { cn_n++; cn_left[cn_n] = 5; cn_hit[cn_n] = 0 }
          else if (first == "journal_checkpoint") { jc_n++; jc_left[jc_n] = 10; jc_hit[jc_n] = 0 }
          else if (first == "re_edit_warning") { rw_n++; rw_path[rw_n] = tail; rw_count[rw_n] = 0 }
          # cautious_mode / codex_reminder resolve at END
        }
        else if (t == "file_edit") {
          p = tail
          edits[p]++
          if (edits[p] > maxrep) maxrep = edits[p]
          if (first == "r") {
            for (i = 1; i <= cn_n; i++)
              if (!cn_hit[i] && cn_left[i] > 0) cn_left[i]--
          }
          for (i = 1; i <= rw_n; i++)
            if (p == rw_path[i]) rw_count[i]++
        }
        else if (t == "commit") {
          for (i = 1; i <= cn_n; i++)
            if (!cn_hit[i] && cn_left[i] > 0) cn_hit[i] = 1
        }
        else if (t == "tool_call") {
          # Floor at -1, not 0: the journal Write LOGS ITS OWN tool_call before
          # its journal_edit, so after exactly 10 tools jc_left is 0 and the
          # edit is still WITHIN the window; only an 11th tool (-1) is out.
          for (i = 1; i <= jc_n; i++)
            if (!jc_hit[i] && jc_left[i] > -1) jc_left[i]--
        }
        else if (t == "journal_edit") {
          for (i = 1; i <= jc_n; i++)
            if (!jc_hit[i] && jc_left[i] >= 0) jc_hit[i] = 1
        }
        else if (t == "codex_review") {
          # Only a review LATER than the reminder counts (spec §6.3): the flag
          # arms only once a codex_reminder has already fired in this log.
          if ("codex_reminder" in fired) cr_after = 1
        }
      }
      END {
        for (i = 1; i <= cn_n; i++) if (cn_hit[i]) fol["commit_nudge"]++
        for (i = 1; i <= jc_n; i++) if (jc_hit[i]) fol["journal_checkpoint"]++
        for (i = 1; i <= rw_n; i++) if (rw_count[i] < 2) fol["re_edit_warning"]++
        # `in` tests, NOT fired[k]>0 subscripts: merely referencing fired["x"]
        # INSTANTIATES the key, so a zero-intervention log would emit spurious
        # "x|0|0" rows (contract: kinds never fired are omitted).
        if (("cautious_mode" in fired) && maxrep < 3) fol["cautious_mode"] = fired["cautious_mode"]
        if (("codex_reminder" in fired) && cr_after)  fol["codex_reminder"]  = fired["codex_reminder"]
        for (k in fired) printf "%s|%d|%d\n", k, fired[k], fol[k] + 0
      }
    ' "$f"
  done | awk -F'|' '
    { f[$1] += $2; w[$1] += $3 }
    END { for (k in f) printf "%s|%d|%d\n", k, f[k], w[k] }
  ' | sort
}

# eio_intervention_report [days] — project-default wrapper.
eio_intervention_report() {
  eio_intervention_report_dirs "$(_eio_sessions_dir)" "${1:-30}"
}

# eio_hot_files [days] [min_sessions] [sessions_dir]
# Cross-session hot files, derived at read from week-bucket logs (spec §3.5,
# locked D6: the mutable cross-session.local.md tracker is retired — legacy
# files on disk are inert, no reader and no writer). Emits
# "path|distinct_session_count" lines, most-recurrent first, for r-flagged
# file_edit paths appearing in >= min_sessions DISTINCT session logs whose
# mtime falls within [days] (defaults 30, 4). Per-log dedup means N edits of
# one path in one session still count as ONE session. Plugin-infrastructure
# paths (.claude/, .claude-plugin/) are excluded, matching the old tracker.
eio_hot_files() {
  local days="${1:-30}" min_sessions="${2:-4}" sessions_dir="${3:-$(_eio_sessions_dir)}"
  [ -d "$sessions_dir" ] || return 0
  local now_epoch cutoff_epoch f f_epoch
  now_epoch=$(date +%s)
  cutoff_epoch=$(( now_epoch - days * 86400 ))
  for f in "$sessions_dir"/*/*.events.log; do
    [ -f "$f" ] || continue
    f_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
    if [ "$f_epoch" -gt 0 ] && [ "$f_epoch" -lt "$cutoff_epoch" ]; then
      continue
    fi
    awk '
      { sub(/\r$/, "") }
      !/^[0-9]+\|[a-z_]+\|/ { next }
      {
        rest = substr($0, index($0, "|") + 1)
        t = substr(rest, 1, index(rest, "|") - 1)
        if (t != "file_edit") next
        v = substr(rest, index(rest, "|") + 1)
        if (substr(v, 1, 2) != "r ") next
        p = substr(v, 3)
        if (p ~ /\.claude\// || p ~ /\.claude-plugin\//) next
        if (!(p in seen)) { seen[p] = 1; print p }
      }
    ' "$f"
  done | sort | uniq -c | MINS="$min_sessions" awk '
    {
      # uniq -c: leading spaces, count, single space, then the path verbatim
      # (substr reconstruction — field splitting would mangle spaced paths).
      if (!match($0, /^[[:space:]]*[0-9]+ /)) next
      c = substr($0, 1, RLENGTH - 1)
      gsub(/[[:space:]]/, "", c)
      p = substr($0, RLENGTH + 1)
      if (c + 0 >= ENVIRON["MINS"] + 0) printf "%s|%d\n", p, c
    }
  ' | sort -t'|' -k2,2nr
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
