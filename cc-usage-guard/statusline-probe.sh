#!/usr/bin/env bash
#
# statusLine probe: dumps the JSON that Claude Code pipes to the status line
# command on stdin, so we can confirm whether `rate_limits` is populated.
#
# Register it as `statusLine.command` in settings.json, then look at the dump
# with ./check.sh. It never touches the network.

DUMP="${CC_PROBE_DUMP:-$HOME/.cache/cc-usage-guard/statusline-input.json}"

input=$(cat)

mkdir -p "$(dirname "$DUMP")"
printf '%s' "$input" >"$DUMP.tmp" && mv "$DUMP.tmp" "$DUMP"

# Keep the visible status line short — the real inspection happens in check.sh.
if ! command -v jq >/dev/null 2>&1; then
  printf 'cc-usage-guard: jq not found'
  exit 0
fi

five=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

printf 'probe  5h=%s  7d=%s' "${five:-ABSENT}" "${seven:-ABSENT}"
