#!/usr/bin/env bash
#
# Sensor half of the guard.
#
# Claude Code delivers `rate_limits` to the status line but not to hooks, so this
# script records what it sees to a state file that usage-gate.sh can read. It
# also renders a compact status line, since a statusLine command has to print
# something.

STATE="${CC_GUARD_STATE:-$HOME/.cache/cc-usage-guard/state.json}"

input=$(cat)

command -v jq >/dev/null 2>&1 || { printf 'cc-usage-guard: jq not found'; exit 0; }

mkdir -p "$(dirname "$STATE")"

# `now` is stamped here rather than read from the payload so the gate can tell
# how stale the reading is.
#
# The `select` is what keeps a reading from being erased. The first render of a
# session happens before its first API response, so `rate_limits` is absent from
# that payload; recording it would null out a good reading left by a previous
# session and stand the gate down for the opening prompt. `jq` succeeds on a
# missing field, so the junk check below never caught this. Writing nothing instead
# lets an old reading age out through the gate's `max_age`, which is the case the
# gate already reasons about.
if printf '%s' "$input" | jq -c '
  select(.rate_limits.five_hour != null or .rate_limits.seven_day != null)
  | { five_hour: .rate_limits.five_hour
    , seven_day: .rate_limits.seven_day
    , observed_at: (now | floor)
    }
' >"$STATE.tmp" 2>/dev/null && [ -s "$STATE.tmp" ]; then
  mv "$STATE.tmp" "$STATE"
elif [ -e "$STATE.tmp" ]; then
  # Leave the previous good state in place rather than replacing it with junk.
  rm "$STATE.tmp"
fi

printf '%s' "$input" | jq -r '
  def pct(w): (w.used_percentage // null)
    | if . == null then "--" else "\(. | floor)%" end;

  [ (.model.display_name // "?")
  , "5h " + pct(.rate_limits.five_hour)
  , "7d " + pct(.rate_limits.seven_day)
  ] | join("  │  ")
'
