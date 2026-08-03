#!/usr/bin/env bash
# python-resolve.sh — run a snippet under the first USABLE Python 3.
# Pure function definitions, no source-time side effects (event-io rule).
#
# Why not `command -v python3`: on Windows the "App execution alias"
# python3.exe is a Microsoft Store stub — a real executable on PATH that
# prints an install hint to stderr and exits 49 without ever running Python.
# PATH presence is therefore not proof of usability; only a real execution's
# exit status is. Candidate order: python3 → python → py -3 (the python.org
# installer registers the py launcher even when "add to PATH" was unticked).
#
# Usage:  out=$(printf '%s' "$json" | cortex_python3_run "<code>" [argv...]) || out=""
# Exit 0: an interpreter ran <code> (stdout may still be legitimately empty).
# Exit 1: no usable interpreter — callers fall through to their awk tier.
# Cost: the happy path (working python3) is one exec, exactly as before the
# resolver existed; later candidates are only tried after a fast stub/127
# failure, so healthy systems see no extra probe launches.

cortex_python3_run() {
  local code="${1:-}"
  shift 2>/dev/null || true
  local input cand out
  input=$(cat)  # Buffer stdin once — candidates may need it re-fed
  for cand in "python3" "python" "py -3"; do
    # Unquoted $cand is deliberate: "py -3" must word-split into command +
    # flag. No glob/space risk — candidates are fixed literals, never paths.
    # shellcheck disable=SC2086
    if out=$(printf '%s' "$input" | $cand -c "$code" "$@" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}
