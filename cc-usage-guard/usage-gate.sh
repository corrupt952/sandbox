#!/usr/bin/env bash
#
# Gate half of the guard: a UserPromptSubmit hook that refuses to let a turn
# start once a configured share of a rate-limit window has been spent.
#
# Reads the state file written by statusline.sh. Fails open in every ambiguous
# case — a guard that jams the session shut on a missing file is worse than no
# guard at all.

set -uo pipefail

STATE="${CC_GUARD_STATE:-$HOME/.cache/cc-usage-guard/state.json}"
CONF_DIR="${CC_GUARD_CONF_DIR:-$HOME/.config/cc-usage-guard}"

# Config file overrides built-in defaults; environment overrides the config file.
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"

LIMIT_5H="${CC_GUARD_5H:-${limit_5h:-90}}"
LIMIT_7D="${CC_GUARD_7D:-${limit_7d:-90}}"
MAX_AGE="${CC_GUARD_MAX_AGE:-${max_age:-900}}"

pass() { exit 0; }

# --- escape hatches ------------------------------------------------------
# Both work without restarting Claude Code, which matters: once the gate is
# blocking, there is no way to ask Claude to turn it off.
[ -f "$CONF_DIR/disabled" ] && pass
[ "${CC_GUARD_OFF:-}" = "1" ] && pass

payload=$(cat)
command -v jq >/dev/null 2>&1 || pass

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')

# Only UserPromptSubmit carries a prompt, so this hatch is turn-scoped by nature.
case "$(printf '%s' "$payload" | jq -r '.prompt // ""')" in
  *'[guard-bypass]'*) pass ;;
esac

# --- read state ----------------------------------------------------------
[ -f "$STATE" ] || pass

now=$(date +%s)
observed=$(jq -r '.observed_at // 0' "$STATE" 2>/dev/null) || pass
[ "$observed" -gt 0 ] 2>/dev/null || pass

# A stale reading means the status line is not running — `claude -p`, for
# instance. Blocking on a number from an hour ago would be guesswork.
[ $((now - observed)) -gt "$MAX_AGE" ] && pass

# --- evaluate windows ----------------------------------------------------
over() { # window_key limit -> prints "pct resets_at" when over budget
  local key=$1 limit=$2 pct resets
  pct=$(jq -r --arg k "$key" '.[$k].used_percentage // empty' "$STATE")
  resets=$(jq -r --arg k "$key" '.[$k].resets_at // empty' "$STATE")
  [ -n "$pct" ] || return 1
  # An elapsed window has already rolled over; the recorded percentage is void.
  [ -n "$resets" ] && [ "$resets" -le "$now" ] 2>/dev/null && return 1
  awk "BEGIN{exit !($pct >= $limit)}" || return 1
  printf '%s %s' "$pct" "${resets:-0}"
}

for spec in "five_hour:$LIMIT_5H:5時間枠" "seven_day:$LIMIT_7D:週次枠"; do
  key=${spec%%:*}; rest=${spec#*:}; limit=${rest%%:*}; label=${rest#*:}

  hit=$(over "$key" "$limit") || continue
  pct=${hit%% *}; resets=${hit##* }

  if [ "$resets" -gt 0 ] 2>/dev/null; then
    when=$(date -r "$resets" '+%m/%d %H:%M' 2>/dev/null || date -d "@$resets" '+%m/%d %H:%M')
    until_txt="リセットは ${when} です"
  else
    until_txt="リセット時刻は不明です"
  fi

  reason="${label}を ${pct}% 消費しました（自主上限 ${limit}%）。${until_txt}。
続行する場合はプロンプトに [guard-bypass] を含めるか、touch ~/.config/cc-usage-guard/disabled で無効化してください。"

  # PreToolUse fires inside a turn, so it is what actually contains a runaway
  # agent; UserPromptSubmit only ever catches the next turn boundary.
  if [ "$event" = "PreToolUse" ]; then
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  else
    jq -n --arg reason "$reason" '{ decision: "block", reason: $reason }'
  fi
  exit 0
done

pass
