#!/usr/bin/env bash
# Synthesis automation: promotion sweep + staleness check.
# Called by hooks/session-start. Outputs action messages to stdout.
# Always exits 0 — failures must not kill the session-start hook.
#
# Env: COLLAB_FILE — path to collaboration.md (required)

set +e  # Must not fail on grep/sed misses

COLLAB_FILE="${COLLAB_FILE:-}"
if [ -z "$COLLAB_FILE" ] || [ ! -f "$COLLAB_FILE" ]; then
  exit 0
fi

synthesis_actions=""

# --- Promotion sweep ---
# Single pass: find [unconfirmed] headings, check Reinforced count, collect line numbers
promoted_count=0
promote_lines=""
current_heading_line=0

line_num=0
while IFS= read -r line; do
  line_num=$((line_num + 1))
  if echo "$line" | grep -q '^### .* \[unconfirmed\]'; then
    current_heading_line=$line_num
  elif [ "$current_heading_line" -gt 0 ]; then
    if echo "$line" | grep -q '\*\*Reinforced\*\*:'; then
      count=$(echo "$line" | sed 's/.*\*\*Reinforced\*\*: \([0-9]*\).*/\1/')
      if [ "${count:-0}" -ge 2 ]; then
        promote_lines="${promote_lines}${current_heading_line},"
        promoted_count=$((promoted_count + 1))
      fi
      current_heading_line=0
    elif echo "$line" | grep -q '^###\|^## \|^---'; then
      current_heading_line=0
    fi
  fi
done < "$COLLAB_FILE"

if [ "$promoted_count" -gt 0 ] && [ -n "$promote_lines" ]; then
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
stale_warnings=""
now_epoch=$(date +%s)
last_heading=""

while IFS= read -r line; do
  if echo "$line" | grep -q '^### '; then
    last_heading=$(echo "$line" | sed 's/^### //' | sed 's/ \[unconfirmed\]//')
  fi
  if echo "$line" | grep -q '\*\*Last validated\*\*:'; then
    val_date=$(echo "$line" | sed 's/.*\*\*Last validated\*\*: \([0-9-]*\).*/\1/')
    if [ -n "$val_date" ]; then
      # Dual fallback: GNU date || BSD date
      val_epoch=$(date -d "$val_date" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%d" "$val_date" +%s 2>/dev/null \
        || echo "0")
      if [ "$val_epoch" -gt 0 ]; then
        age_days=$(( (now_epoch - val_epoch) / 86400 ))
        if [ "$age_days" -ge 30 ]; then
          stale_warnings="${stale_warnings}  - \"${last_heading}\" (${val_date}, ${age_days}d ago)"$'\n'
        fi
      fi
    fi
  fi
done < "$COLLAB_FILE"

if [ -n "$stale_warnings" ]; then
  synthesis_actions="${synthesis_actions:+${synthesis_actions}$'\n'}Stale collaboration patterns (>30d since last validated):"$'\n'"${stale_warnings}"
fi

# Output combined results
if [ -n "$synthesis_actions" ]; then
  printf '%s' "$synthesis_actions"
fi

exit 0
