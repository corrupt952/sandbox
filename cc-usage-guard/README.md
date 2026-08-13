# cc-usage-guard

Stops Claude Code at a usage percentage you choose.

No plan lets you halt at an arbitrary point in a rate-limit window — the built-in
stop is the 100% wall, and it is not configurable. On Team and Enterprise it is
worse than not configurable: usage controls are Owner-level only, so a member has
no self-service way to stop their own consumption at all. Members do not even get
the "Request usage credits" link that seat-based Enterprise plans expose; that is
a request to an admin, not a brake.

Wanting to stop at 60% of the weekly window is a normal thing to want — pacing
work across days, leaving headroom for a teammate, keeping a reserve for an
on-call shift. There is no first-party way to express it.

The same gate doubles as a containment bound on an agent that runs away:
`PreToolUse` fires inside a turn, so a subagent fan-out or a long autonomous run
stops at the percentage you set rather than at 100%.

## Why this needs building

Claude Code delivers the authoritative rate-limit state to the `statusLine`
command on stdin. It is the same data `/usage` shows, with no extra network call:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
}
```

The numbers originate server-side: the API returns undocumented
`anthropic-ratelimit-unified-5h-*` response headers, which Claude Code holds in
memory for the session and hands to the status line. They are never written to the
session transcript, which is why local JSONL parsers can only estimate.

Hooks are the only thing that can *block* execution, but their stdin payload has
no `rate_limits` field — the common fields are `session_id`, `prompt_id`,
`transcript_path`, `cwd`, `permission_mode`, `effort` and `hook_event_name`. The
request to expose usage data to hooks
([anthropics/claude-code#38380](https://github.com/anthropics/claude-code/issues/38380))
was closed as not planned, while the request to surface it to status lines
([#55333](https://github.com/anthropics/claude-code/issues/55333)) is what shipped.
The asymmetry is deliberate, so bridging it is the only supported route.

Existing tools sit on one side of that gap or the other. Status-line trackers read
`rate_limits` but only display it; enforcement tools like
[claude-code-limiter](https://github.com/howincodes/claude-code-limiter) and
[clauditor](https://github.com/IyadhKhalfallah/clauditor) block, but tally turns or
tokens themselves rather than reading the real window — which misses usage from
other machines, exactly the case that matters on a shared plan.

The same sensor-to-hook bridge has been built before for a different signal:
[an article on Zenn](https://zenn.dev/trust_delta/articles/claude-code-context-warning-001)
(2026-01-15) routes `context_window` from the status line through a file to a
`UserPromptSubmit` hook to warn before an auto-compact. It warns rather than
blocks, and does not touch `rate_limits`.

So the sensor and the gate are split, bridged by a state file:

```
statusLine (reads rate_limits) ──▶ state file ──▶ hook (blocks)
```

## Files

| File | Role |
| --- | --- |
| `statusline.sh` | Sensor. Records `rate_limits` to the state file, renders a compact status line |
| `usage-gate.sh` | Gate. Blocks once a window is over budget, on both `UserPromptSubmit` and `PreToolUse` |
| `guard-settings.template.json` | Both wired up, for `--settings` |
| `test-gate.sh` | Gate test suite against synthetic state |
| `statusline-probe.sh`, `check.sh`, `probe-settings.template.json` | Probe used to confirm `rate_limits` is delivered at all |

Requires `jq`.

## Usage

The settings files carry absolute paths, so generate them from the templates
first:

```bash
sed "s|__DIR__|$PWD|g" guard-settings.template.json > guard-settings.json
```

Then try it without touching the real config:

```bash
claude --settings ./guard-settings.json
```

Defaults sit at 90%, so nothing fires until you are close. To watch it work, drop
a threshold below current usage: `CC_GUARD_7D=10 claude --settings ./guard-settings.json`.

To install permanently, merge the generated file into `settings.json`. The sensor
replaces the status line, so fold it into an existing one if you have any.

## Two gates, two failure modes

`UserPromptSubmit` fires at turn boundaries. That covers a human deciding to keep
going, but it cannot touch a turn already in flight — a subagent fan-out or a long
agentic run burns the window with no prompt submission in sight.

`PreToolUse` fires before every tool call, inside the turn, so it is the one that
actually contains a runaway. It also runs *before* the permission-mode check, so it
holds under `bypassPermissions` and `--dangerously-skip-permissions`. The status
line re-renders after each API response, so the reading it acts on stays current
through a long turn.

The gate detects `hook_event_name` and emits the right shape for each
(`decision: "block"` vs `hookSpecificOutput.permissionDecision: "deny"`).

## Configuration

Environment overrides the config file, which overrides the defaults.

| Setting | Env | Config key | Default |
| --- | --- | --- | --- |
| 5-hour threshold (%) | `CC_GUARD_5H` | `limit_5h` | `90` |
| 7-day threshold (%) | `CC_GUARD_7D` | `limit_7d` | `90` |
| Max state age (sec) | `CC_GUARD_MAX_AGE` | `max_age` | `900` |

```bash
mkdir -p ~/.config/cc-usage-guard
printf 'limit_5h=85\nlimit_7d=80\n' > ~/.config/cc-usage-guard/config
```

The config file is re-read on every check, so thresholds change without a restart.

## Escape hatches

Once the gate is blocking there is no way to ask Claude to lift it, so all three
work from outside the session:

- Include `[guard-bypass]` anywhere in the prompt — lets the turn *start*, and
  nothing more. Only `UserPromptSubmit` carries a prompt, so `PreToolUse` never
  sees the marker and goes on denying every tool call in that turn. For work that
  needs tools, this hatch is not enough; reach for one of the two below
- `touch ~/.config/cc-usage-guard/disabled` — off until the file is removed
- `CC_GUARD_OFF=1` — off for the process

## Fail-open behaviour

Enforcement is only as trustworthy as the reading behind it, so the gate stands
down whenever it cannot be sure:

| Situation | Result |
| --- | --- |
| No state file yet | pass |
| State older than `max_age` | pass — the status line is not running, e.g. `claude -p` |
| `rate_limits` absent from the payload | pass |
| `resets_at` already elapsed | pass — the window rolled over, the reading is void |
| At or above the threshold | **block** |

The headless case is the real hole: with no status line there is no fresh reading,
so `claude -p` runs unguarded. Measured rather than assumed — under `claude -p`
the probe writes no dump at all, so the status line command is not merely
unrendered but never invoked.

A second hole sat on the sensor side until it was found by running this. The first
render of a session happens before its first API response, so `rate_limits` is
absent there, and the sensor used to record `null` for both windows — erasing the
reading left by the previous session and standing the gate down for the opening
prompt. `jq` succeeds on a missing field, so the sensor's own junk check never saw
it; that check only covers a `jq` failure. The sensor now writes nothing unless a
render actually carries a reading, which turns the situation back into ordinary
staleness: the old reading stands and ages out through `max_age`.

Even before that, the gap was narrower than it sounds. The sensor runs on the first
API response, which lands before the turn's first tool call, so `PreToolUse` had a
real reading to act on regardless. Observed live: the opening prompt of a session
was accepted and its first `Bash` call denied.

## Concurrent sessions

Not handled at all. The state file is a single global path shared by every session
on the machine, and nothing coordinates access to it.

The readings themselves do not conflict. `rate_limits` describes the account's
window, so every session sees the same numbers and it does not matter which one
records them. The staging does: `statusline.sh` writes through a fixed
`$STATE.tmp`, so two sensors rendering at the same moment share that file, and
whichever `mv`s first can publish a half-written mix of both. The gate then fails
to parse the result and stands down silently — the safe direction, but a gap all
the same. A per-process suffix on the temp name would close it, and is not there.

Reads carry a milder version of the same thing. `used_percentage` and `resets_at`
come from separate `jq` invocations, so a file replaced between them yields two
fields from different renders. `mv` is atomic, so each invocation sees a whole
file; only the pairing slips, and for these two fields the outcome is the same
either way.

## Cost of running it

Nothing. The gate blocks before Claude processes the prompt, so a blocked turn
makes no API call. Both scripts are pure local shell.

One trap worth knowing if you modify the gate: `UserPromptSubmit`,
`UserPromptExpansion` and `SessionStart` are the events where hook **stdout is
injected into the context window**. Anything the gate prints on the pass path
would be billed on every single prompt. It prints zero bytes on every pass path,
to both stdout and stderr, and `test-gate.sh` is where that stays true.

## Testing

```bash
./test-gate.sh
```

17 cases covering the fail-open table, threshold precedence, config/env
precedence, each escape hatch, and both hook events.

The sensor has no suite. Its one non-obvious behaviour — a render arriving without
`rate_limits` must leave existing state untouched, `observed_at` included — was
checked by hand against all three cases: no state, a reading, then a render without
one.

## Status

- [x] Probe and checker
- [x] `rate_limits` confirmed present on a Max account (Claude Code 2.1.221)
- [x] Sensor, gate, and test suite
- [x] `rate_limits` confirmed on a Team premium seat (Claude Code 2.1.228) — the
      docs only promise the field to Pro/Max subscribers, and Team is where the
      motivating gap is, but it arrives in the same shape: `five_hour` and
      `seven_day`, `used_percentage` and `resets_at`, no additional windows
- [x] Gate live-fired on a Team seat against a real reading — `UserPromptSubmit`
      refused a turn at 2% of the weekly window against a 1% threshold. The first
      prompt went through, which is what fail-open requires with the state file
      freshly cleared
- [x] `PreToolUse` live-fired mid-turn against a real reading — the opening prompt
      of a session passed, then its first `Bash` call was denied. The model retried
      once, hit the same denial, and stopped to report rather than working around
      it; it did not reach for `[guard-bypass]` on its own
- [ ] Live run against a genuinely exhausted window

## Write-up

<a href="https://labee.jp/posts/claude-code-usage-rate-guard"><img src="https://labee.jp/og/posts/claude-code-usage-rate-guard.png" alt="Claude Codeを任意の使用率で止めるガードを作っている" width="600"></a>

<a href="https://labee.jp/posts/claude-code-usage-guard-live-fire"><img src="https://labee.jp/og/posts/claude-code-usage-guard-live-fire.png" alt="Claude Codeの使用率ガードをTeamシートで止める" width="600"></a>
