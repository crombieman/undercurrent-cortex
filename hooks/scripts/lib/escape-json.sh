#!/usr/bin/env bash
# Shared JSON string escaping — sourced by hook scripts that output JSON.
# Extracted from hooks/session-start (original lines 8-16).

escape_for_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Strip remaining raw C0 controls (0x00-0x1F). \n\r\t were already converted
  # to two-char escape sequences above, so only stray controls are removed —
  # any one of them makes the embedding JSON invalid and kills the hook output.
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '%s' "$s"
}
