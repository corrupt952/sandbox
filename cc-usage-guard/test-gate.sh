#!/usr/bin/env bash
#
# Feeds synthetic state files and hook payloads to usage-gate.sh and checks
# whether it blocks. Every case must fail open unless it is a genuine overrun.

set -uo pipefail
cd "$(dirname "$0")"

TMP="$PWD/.test-tmp"
[ -d "$TMP" ] && rm -r "$TMP"
trap '[ -d "$TMP" ] && rm -r "$TMP"' EXIT

export CC_GUARD_STATE="$TMP/state.json"
export CC_GUARD_CONF_DIR="$TMP/conf"
mkdir -p "$CC_GUARD_CONF_DIR"

NOW=$(date +%s)
pass_count=0 fail_count=0

state() { # five_hour_pct seven_day_pct age_seconds resets_offset
  jq -n --argjson f "$1" --argjson s "$2" --argjson age "$3" \
        --argjson off "$4" --argjson now "$NOW" '{
    five_hour: { used_percentage: $f, resets_at: ($now + $off) },
    seven_day: { used_percentage: $s, resets_at: ($now + $off) },
    observed_at: ($now - $age)
  }' >"$CC_GUARD_STATE"
}

check() { # name expected(pass|block) prompt
  local name=$1 expect=$2 prompt=${3:-hello}
  local out got
  out=$(jq -n --arg p "$prompt" '{hook_event_name:"UserPromptSubmit", prompt:$p}' \
        | ./usage-gate.sh)
  if [ -z "$out" ]; then got=pass
  elif [ "$(printf '%s' "$out" | jq -r '.decision // ""')" = "block" ]; then got=block
  else got="unexpected:$out"; fi

  if [ "$got" = "$expect" ]; then
    printf '  ok    %-42s %s\n' "$name" "$got"; pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %-42s want=%s got=%s\n' "$name" "$expect" "$got"; fail_count=$((fail_count + 1))
  fi
}

check_tool() { # name expected(pass|deny)
  local name=$1 expect=$2
  local out got
  out=$(jq -n '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:"ls"}}' \
        | ./usage-gate.sh)
  if [ -z "$out" ]; then got=pass
  elif [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""')" = "deny" ]; then got=deny
  else got="unexpected:$out"; fi

  if [ "$got" = "$expect" ]; then
    printf '  ok    %-42s %s\n' "$name" "$got"; pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %-42s want=%s got=%s\n' "$name" "$expect" "$got"; fail_count=$((fail_count + 1))
  fi
}

echo "usage-gate.sh"

check "no state file" pass

state 3 76 10 3600
check "both under threshold (90)" pass

state 95 10 10 3600
check "5h over threshold" block

state 3 95 10 3600
check "7d over threshold" block

state 95 99 10 3600
check "both over threshold" block

state 95 99 100000 3600
check "state older than max_age" pass

state 95 99 10 -60
check "window already reset" pass

state 95 99 10 3600
check "prompt carries [guard-bypass]" pass "fix it [guard-bypass]"

state 95 99 10 3600
CC_GUARD_OFF=1 check "CC_GUARD_OFF=1" pass

state 95 99 10 3600
touch "$CC_GUARD_CONF_DIR/disabled"
check "disabled marker file" pass
rm "$CC_GUARD_CONF_DIR/disabled"

jq -n --argjson now "$NOW" '{five_hour:null, seven_day:null, observed_at:$now}' >"$CC_GUARD_STATE"
check "rate_limits absent from payload" pass

state 85 10 10 3600
printf 'limit_5h=80\n' >"$CC_GUARD_CONF_DIR/config"
check "config file lowers 5h limit to 80" block

state 85 10 10 3600
CC_GUARD_5H=95 check "env overrides config file" pass
rm "$CC_GUARD_CONF_DIR/config"

state 90 10 10 3600
check "exactly at threshold blocks" block

# PreToolUse is the one that can stop a runaway agent mid-turn.
state 3 5 10 3600
check_tool "PreToolUse under threshold" pass

state 95 10 10 3600
check_tool "PreToolUse over threshold denies" deny

state 95 10 100000 3600
check_tool "PreToolUse with stale state" pass

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
