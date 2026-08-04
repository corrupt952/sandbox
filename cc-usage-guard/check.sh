#!/usr/bin/env bash
#
# Inspects the dump written by statusline-probe.sh and reports whether the
# `rate_limits` field is actually delivered on this machine / plan.

set -uo pipefail

DUMP="${CC_PROBE_DUMP:-$HOME/.cache/cc-usage-guard/statusline-input.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

if [ ! -f "$DUMP" ]; then
  cat >&2 <<EOF
No dump at: $DUMP

The probe has not run yet. Register statusline-probe.sh as statusLine.command,
then start a session and send at least one prompt — rate_limits is documented to
appear only after the first API response in the session.
EOF
  exit 1
fi

now=$(date +%s)
mtime=$(stat -f %m "$DUMP" 2>/dev/null || stat -c %Y "$DUMP")
age=$((now - mtime))

echo "dump    : $DUMP"
echo "age     : ${age}s"
echo "version : $(jq -r '.version // "?"' "$DUMP")"
echo "model   : $(jq -r '.model.display_name // "?"' "$DUMP")"
echo

if [ "$(jq -r 'has("rate_limits")' "$DUMP")" != "true" ]; then
  echo "rate_limits : ABSENT"
  echo
  echo "Not delivered on this account. The status-line based design does not"
  echo "apply here; the OAuth usage endpoint would be the only remaining source."
  echo
  echo "Top-level keys present:"
  jq -r 'keys[] | "  - " + .' "$DUMP"
  exit 2
fi

echo "rate_limits : PRESENT"
jq -r '
  .rate_limits
  | to_entries[]
  | "  \(.key): used=\(.value.used_percentage // "absent")%  resets_at=\(.value.resets_at // "absent")"
' "$DUMP"

echo
jq -r '
  .rate_limits
  | to_entries[]
  | select(.value.resets_at != null)
  | "  \(.key) resets in \(((.value.resets_at - now) / 60) | floor) min"
' "$DUMP"
