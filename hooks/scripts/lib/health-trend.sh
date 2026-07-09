#!/usr/bin/env bash
# health-trend.sh — v2 health-row READ-TIME trend computation (spec §6.2).
# session-end-dispatch.sh writes v2|... rows (git-derived measurement core,
# spec §6.1); this file is the SOLE place that turns those rows back into a
# trend verdict. Sourced by hooks/session-start (feeds mode_set) and
# hooks/scripts/statusline.sh (feeds the trend arrow / "N sessions tracked"
# line) — a shared lib keeps the verdict math defined exactly once instead of
# drifting between the two callers. Pure health-file reader: no event-log
# access, no writes.

# WAVE-4 TUNABLE constants (spec §6.2) — the ONLY place these thresholds live.
# fix_ratio: median(last-5) - median(prior-5) beyond this magnitude signals a
# directional shift (positive = proportionally MORE fix:/revert commits = worse).
HT_FIX_RATIO_DELTA=0.15
# rework_files: a v2 row counts as "high rework" once its rework_files reaches this.
HT_REWORK_FILES_THRESHOLD=3
# Degrading requires at least this many high-rework rows among the last 5.
HT_REWORK_DEGRADE_COUNT=3
# Non-idle v2 rows required before any verdict is computed at all.
HT_MIN_ROWS_FOR_TREND=10

# _ht_median — reads newline-delimited numbers on stdin, echoes the median (4
# decimal places) or an empty string on no input. Portable: `sort -n` does the
# ordering, awk just picks the middle — no gawk-only asort (ubuntu CI runs mawk).
_ht_median() {
  local sorted count
  sorted=$(sort -n)
  [ -z "$sorted" ] && { echo ""; return 0; }
  count=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
  printf '%s\n' "$sorted" | awk -v n="$count" '
    { a[NR] = $1 }
    END {
      if (n % 2 == 1) printf "%.4f", a[(n + 1) / 2]
      else printf "%.4f", (a[n / 2] + a[n / 2 + 1]) / 2
    }'
}

# ht_total_row_count <health_file>
# All data rows (v2 + legacy) — comments/header directives/blank lines
# excluded. Legacy rows ARE counted here (spec: "Legacy rows counted for the
# N display, EXCLUDED from median math") — the exclusion from median math
# happens in ht_trend below, which filters on the v2 sentinel separately.
ht_total_row_count() {
  local file="$1"
  [ -f "$file" ] || { echo 0; return 0; }
  local n
  n=$(grep -v '^#' "$file" 2>/dev/null | grep -v '^$' | grep -v '^trend_' \
    | grep -v '^avg_' | grep -v '^---' | grep -c '|' 2>/dev/null || true)
  echo "${n:-0}"
}

# ht_trend <health_file>
# Echoes: <total_row_count>|<nonidle_v2_count>|<verdict>|<reason>
#   verdict: "" (fewer than HT_MIN_ROWS_FOR_TREND non-idle v2 rows) | improving
#            | stable | degrading
#   reason:  "" | fix_ratio | rework — the mode_set event's reason token; only
#            meaningful when verdict=degrading.
# v2 row layout (spec §6.1):
#   1=v2 2=date 3=session_id 4=commits 5=material_edits 6=fix_ratio 7=reverts
#   8=rework_files 9=tests_pass 10=duration_min 11=max_re_edits 12=topology
#   13=domain 14=self_misses
ht_trend() {
  local file="$1"
  local total=0 nonidle_count=0 verdict="" reason=""
  total=$(ht_total_row_count "$file")

  if [ -f "$file" ]; then
    # v2 rows only, domain != idle, file order preserved (chronological).
    local v2_rows
    v2_rows=$(awk -F'|' '$1 == "v2" && $13 != "idle"' "$file" 2>/dev/null || true)
    if [ -n "$v2_rows" ]; then
      nonidle_count=$(printf '%s\n' "$v2_rows" | wc -l | tr -d ' ')
    fi

    if [ "${nonidle_count:-0}" -ge "$HT_MIN_ROWS_FOR_TREND" ]; then
      local last10 prior5 last5
      last10=$(printf '%s\n' "$v2_rows" | tail -10)
      prior5=$(printf '%s\n' "$last10" | head -5)
      last5=$(printf '%s\n' "$last10" | tail -5)

      # fix_ratio medians (skip literal "null" — commits==0 rows).
      local prior_fr last_fr fr_delta=""
      prior_fr=$(printf '%s\n' "$prior5" | awk -F'|' '$6 != "null" { print $6 }' | _ht_median)
      last_fr=$(printf '%s\n' "$last5" | awk -F'|' '$6 != "null" { print $6 }' | _ht_median)
      if [ -n "$prior_fr" ] && [ -n "$last_fr" ]; then
        fr_delta=$(awk -v a="$last_fr" -v b="$prior_fr" 'BEGIN { printf "%.4f", a - b }')
      fi

      # rework_files: how many of the last 5 rows are "high rework".
      local rework_high_count
      rework_high_count=$(printf '%s\n' "$last5" | awk -F'|' -v t="$HT_REWORK_FILES_THRESHOLD" '
        $8 >= t { c++ } END { print c + 0 }')
      rework_high_count="${rework_high_count:-0}"

      local fr_degrading=false fr_improving=false rw_degrading=false rw_improving=false
      if [ -n "$fr_delta" ]; then
        if awk -v d="$fr_delta" -v t="$HT_FIX_RATIO_DELTA" 'BEGIN { exit !(d > t) }'; then
          fr_degrading=true
        fi
        if awk -v d="$fr_delta" -v t="$HT_FIX_RATIO_DELTA" 'BEGIN { exit !(d < -t) }'; then
          fr_improving=true
        fi
      fi
      [ "$rework_high_count" -ge "$HT_REWORK_DEGRADE_COUNT" ] && rw_degrading=true
      [ "$rework_high_count" -eq 0 ] && rw_improving=true

      # Degrading wins if either signal fires (fix_ratio checked first — it's
      # the more direct self-correction signal). Improving requires BOTH
      # signals to point the improving direction ("mirrors" of the two
      # degrading conditions above — spec §6.2). Anything else is stable.
      if [ "$fr_degrading" = true ]; then
        verdict="degrading"; reason="fix_ratio"
      elif [ "$rw_degrading" = true ]; then
        verdict="degrading"; reason="rework"
      elif [ "$fr_improving" = true ] && [ "$rw_improving" = true ]; then
        verdict="improving"
      else
        verdict="stable"
      fi
    fi
  fi

  printf '%s|%s|%s|%s\n' "$total" "${nonidle_count:-0}" "$verdict" "$reason"
}
