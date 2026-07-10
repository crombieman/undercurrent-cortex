#!/usr/bin/env bash
# Synthesis automation: promotion sweep + staleness check.
# Called by hooks/session-start. Outputs action messages to stdout.
# Always exits 0 — failures must not kill the session-start hook.
#
# Env: COLLAB_FILE — path to collaboration.md (required)
#
# PERF CONTRACT: this runs inside session-start's sync hook budget. Both
# scans MUST be single-pass awk — per-line `echo | grep`/`sed`/`date` spawns
# inside while-read loops cost ~15-25ms/process under Windows MSYS and took
# ~98s on a 988-line collaboration.md (2026-07-10 live failure: blew the
# hooks.json timeout, cancelling session-start's entire context injection).
# Guarded by perf_real_size_within_budget in test-synthesis-automation.sh.
# awk constructs must stay mawk-compatible (no mktime/gensub — ubuntu CI).

set +e  # Must not fail on grep/sed misses

COLLAB_FILE="${COLLAB_FILE:-}"
if [ -z "$COLLAB_FILE" ] || [ ! -f "$COLLAB_FILE" ]; then
  exit 0
fi

synthesis_actions=""

# --- Promotion sweep ---
# Single awk pass: find [unconfirmed] headings whose following **Reinforced**
# count (before the next heading/section break) is >= 2. Emits the qualifying
# heading line numbers comma-joined, e.g. "12,47,".
promote_lines=$(awk '
  /^### .* \[unconfirmed\]/ { hl = NR; next }
  hl > 0 && /\*\*Reinforced\*\*:/ {
    line = $0
    sub(/.*\*\*Reinforced\*\*: /, "", line)
    sub(/[^0-9].*/, "", line)
    if (line + 0 >= 2) printf "%d,", hl
    hl = 0
    next
  }
  hl > 0 && (/^###/ || /^## / || /^---/) { hl = 0 }
' "$COLLAB_FILE" 2>/dev/null)

promoted_count=0
if [ -n "$promote_lines" ]; then
  promoted_count=$(printf '%s' "$promote_lines" | awk -F',' '{print NF - 1}')
fi

if [ "${promoted_count:-0}" -gt 0 ]; then
  temp_file="${COLLAB_FILE}.tmp.$$"
  # Build sed expression: for each qualifying line, remove " [unconfirmed]"
  sed_expr=""
  IFS=',' read -ra lines_arr <<< "$promote_lines"
  for ln in "${lines_arr[@]}"; do
    [ -z "$ln" ] && continue
    sed_expr="${sed_expr}${ln}s/ \[unconfirmed\]//;"
  done
  sed "$sed_expr" "$COLLAB_FILE" > "$temp_file" 2>/dev/null

  # Safety check: new file must exist, be non-empty, and have same line count
  orig_lines=$(wc -l < "$COLLAB_FILE")
  new_lines=$(wc -l < "$temp_file" 2>/dev/null || echo "0")
  if [ -s "$temp_file" ] && [ "$new_lines" -ge "$((orig_lines - 1))" ]; then
    mv "$temp_file" "$COLLAB_FILE"
    synthesis_actions="Promoted ${promoted_count} pattern(s) from [unconfirmed] (Reinforced >= 2)."
  else
    rm -f "$temp_file"
  fi
fi

# --- Staleness check ---
# Single awk pass over the (possibly just-updated) file. Date age is computed
# with pure integer arithmetic (days-from-civil algorithm) — no mktime (gawk
# extension, absent in mawk) and no per-line `date` spawns.
now_epoch=$(date +%s)
stale_warnings=$(awk -v now_epoch="$now_epoch" '
  function civil_days(y, m, d,   era, yoe, doy, doe) {
    if (m <= 2) y--
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  BEGIN { now_days = int(now_epoch / 86400) }
  /^### / {
    h = $0
    sub(/^### /, "", h)
    sub(/ \[unconfirmed\]/, "", h)
    last_heading = h
  }
  /\*\*Last validated\*\*:/ {
    d = $0
    sub(/.*\*\*Last validated\*\*: /, "", d)
    sub(/[^0-9-].*/, "", d)
    if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
      age = now_days - civil_days(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0)
      if (age >= 30) printf "  - \"%s\" (%s, %dd ago)\n", last_heading, d, age
    }
  }
' "$COLLAB_FILE" 2>/dev/null)

if [ -n "$stale_warnings" ]; then
  synthesis_actions="${synthesis_actions:+${synthesis_actions}$'\n'}Stale collaboration patterns (>30d since last validated):"$'\n'"${stale_warnings}"
fi

# Output combined results
if [ -n "$synthesis_actions" ]; then
  printf '%s' "$synthesis_actions"
fi

exit 0
