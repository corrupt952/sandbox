# swift-jscore-oop-poc

Runs a JavaScriptCore plugin in a separate process so a script that never returns can be killed, and measures whether that costs enough to matter.

The companion to [swift-jscore-plugin-sandbox](../swift-jscore-plugin-sandbox/), which runs the same plugin shape in-process. That one works until a plugin writes `while (true) {}`: `JSValue.call()` is a synchronous call into JSC, the calling thread never comes back, and neither an actor nor message passing reaches inside the call. The in-process options are a private API (`JSContextGroupSetExecutionTimeLimit`, exported but not declared in any public SDK header) or abandoning a thread to burn a core until the app restarts. Crashes have no in-process answer at all.

## What it measures

| # | Question | Pass line | Result |
|---|----------|-----------|--------|
| E1 | Cold start, binary already validated | p50 ≤ 150 ms | **5–6 ms** p50 |
| E1b | Cold start, binary the kernel has never seen | p95 ≤ 500 ms to avoid rejection | **164–224 ms** p50, 317–342 ms p95 — over the 150 ms budget, so pre-warm |
| E2 | Round-trip latency on a 50-tab snapshot | p95 ≤ 5 ms | **0.27 ms** p95 |
| E3 | Cost of one reverse capability RPC per tick | report the delta | **+0.020 ms**, vs +0.008 ms for the in-process semaphore |
| E4 | Detect a hang, SIGKILL, respawn, leave nothing behind | no residual CPU/threads/RSS | **8.3 ms** from kill to a serving replacement, nothing left |
| E5 | Does JSC work under App Sandbox, and at what cost? | containment holds | contained, **~1.00×** — but the JIT hinges on an entitlement, and its absence costs **11.8×** |
| E6 | Does memory land on the helper's pid? | footprint follows | **+100.9 MiB** for a 100 MB JS allocation |
| E7 | Does descriptor passing survive the sandbox? | not a rejection criterion | open files yes, directory listing yes, **`openat` beneath a directory no** |

Measured on macOS 26.6 (25G72), Apple Silicon, release build, 30 spawns and 1000 ticks per figure. Reproduce with `./run.sh`; the numbers move by a few percent between runs.

The split between those first two rows is a factor of thirty or more, which is why they are separate rows. Spawning a helper the kernel has already validated costs 5–6 ms at p50. Spawning one it has never seen — the shape of a user's first plugin after an install or an update — costs **164–224 ms at p50 and 317–342 ms at p95** across two 60-trial runs, each trial against a fresh copy of the binary carrying the same signature but no cached validation behind it. The tail is heavy and occasionally very heavy: single spawns were seen at 603 ms and, once, 3.1 s.

The helper is 131 KB, so this is not image size, and making it smaller will not buy the time back. What the cost actually consists of was not measured — it is consistent with code signature validation and first-time dyld work, both paid once per binary, but nothing here breaks that ~200 ms down into its parts.

That crosses the 150 ms budget the design note set for spawning on demand. The p95 stays under the 500 ms line that would reject the approach, but individual spawns cross it, so treating 500 ms as a guarantee here would be wrong. The approach stands; the first spawn after an update has to be pre-warmed rather than served on a click. Steady-state spawning needs nothing.

This was nearly missed. E1 as first written spawned the same validated binary thirty times and reported 5 ms, which describes every spawn except the one the user actually notices. What exposed it was an unrelated run where the first sample came back at 669 ms because the binary had just been rebuilt — an accident, not a designed measurement, which is why E1b exists.

With that split, the design note's rejection condition is not met, and nothing here rejects the out-of-process approach. Two further findings change how it should be built.

## Finding 1: the JIT hinges on an entitlement, and it is worth 12×

App Sandbox costs essentially nothing. Across runs it lands between 0.99× and 1.01× on engine work, and the call bridge sits around 1.1 µs either way — the two are indistinguishable at this resolution. That is not the interesting number.

The interesting number is that the plain helper — ad-hoc signed the way the linker leaves it, unsandboxed, no hardened runtime — has **no JIT at all**. JavaScriptCore stamps its allocations with distinct VM user tags, so the question can be answered directly rather than inferred from timings: walking the helper's own VM map finds a 4096 MiB JS heap reservation and a JIT executable allocator of zero bytes. JSC cannot map executable pages, so it runs interpreted and never allocates one. (Both figures are virtual address reservations, not resident memory — nothing here is consuming 4 GiB.)

Granting `com.apple.security.cs.allow-jit` (with the hardened runtime, alongside App Sandbox) is what changes it. A 512 MiB JIT reservation appears and the same loop runs **11.8× faster** — about 1.34 ms/call against 15.8 ms/call, stable across runs.

The gain is entirely on the engine side. Calling into JS at all costs about 1.1 µs per call whichever way the helper is signed, `allow-jit` included. That is Swift-side bridge work, and no entitlement touches it. It also means a plugin that returns quickly barely notices the entitlement; the 11.8× only shows up for plugins that actually compute.

Measuring that bridge with an empty function body is not optional bookkeeping. Read it off a 2,000-iteration script instead — which looks small enough to be call-dominated — and the loop is still over 90% of each call, so what comes back is the engine speedup wearing a bridge label. That mistake reads as "the entitlement makes the call bridge 7× faster", which is not a thing the entitlement does.

The entitlement composes with the sandbox rather than trading against it. Measured on the `allow-jit` variant itself, not inherited from the sandbox-only one: home is still redirected into a container, `proc_listchildpids` still fails with EPERM, the canary is still unreachable by path, and `openat` through a passed directory descriptor is still denied. So a plugin host can have containment and a JIT at once — and on Apple Silicon, one that ships without `allow-jit` is shipping an interpreter. The qualifier matters: on Intel an un-hardened process could JIT without the entitlement, so this is a statement about current macOS on Apple Silicon, not a timeless one.

This also corrects the baseline for every other figure here. The in-process evaluator runs inside `OOPHost`, which is signed the same way, so the run walks that process's VM map too and finds the same thing: a 4096 MiB JS heap reservation and no JIT allocator. The in-process/out-of-process comparisons in E3 are between two interpreted engines, which is a fair comparison, but neither figure describes a JIT-enabled build.

One warning about measuring this. The first attempt used `JSC_useJIT=0` on an otherwise identical helper as a calibration, expecting the number to move and prove the benchmark could see JIT. It did not move — 1.00× — and the honest reading at that point was that the benchmark was insensitive and could not answer the question. There were two candidate explanations: no JIT to switch off, or the environment never reaching the helper. Applying the same variable to the `allow-jit` helper separates them, and it settles cleanly — the JIT region drops to zero and the loop slows by the same ~11.8×, the mirror image of what the entitlement buys. So the variable is honored and does arrive; the flat baseline meant there was no JIT there to disable. `JSC_` options are read by Apple's shipping JavaScriptCore — the environment scan in `Options::initialize` is plain release code, not a debug-only path — so a flat result means there was nothing to disable, not a dead knob. The run keeps both controls, because the flat one is what pointed at the real cause.

A second trap sits next to it. The first compute loop used `%` on doubles, which lands in `fmod` and costs about the same compiled or not, making the benchmark genuinely insensitive for an unrelated reason. Integer arithmetic with `| 0` replaced it. Both traps had to be cleared before any of the numbers above meant anything.

## Finding 2: a passed descriptor carries operations, not a subtree

The design note assumed a host could open a directory, pass the descriptor to the helper, and let the helper reach that subtree through `openat` even while the sandbox denied it everything by path — capability as a descriptor rather than as a string, enforced by the kernel. That inference was marked untested. The measured answer splits along a line the assumption did not anticipate.

What a passed descriptor carries is the operations that act on the object it already refers to. A descriptor for an open file reads fine in the helper while `open()` on that same path is denied — so descriptor passing genuinely does grant access the path policy refuses. A descriptor for a directory can be enumerated: `fdopendir` on it succeeds under App Sandbox and lists the directory's contents.

What it does not carry is path resolution. `openat(dirfd, "inside.txt")` is denied with EPERM even though the host opened `dirfd` and handed it over, which is consistent with the sandbox checking the path that resolution produces rather than the descriptor it started from. `openat(dirfd, "../canary.txt")` is denied as well, so nothing escapes — but that confinement is the sandbox's doing, not the descriptor's: without App Sandbox the same call succeeds and walks straight out.

So a plugin can be handed a directory and told what is in it, but cannot open anything it finds there. Every file it wants is a separate reverse RPC to the host, which turns one grant into an ongoing conversation rather than a subtree handed over once. Granularity is per-file for reading, per-directory for listing.

This is a limit of SCM_RIGHTS specifically, not of App Sandbox in general — the sanctioned way to hand a sandboxed process a subtree is a security-scoped bookmark or a sandbox extension, neither of which is tested here.

## How it works

Three targets. `PluginHelper` is one process per plugin holding one `JSVirtualMachine` + `JSContext`, single-threaded on purpose — the point is that a runaway script wedges only itself, so there is no rescue thread to paper over it. `OOPHost` spawns helpers and runs the experiments. `CPluginIPC` is a small C shim, because the `CMSG_*` macros needed for descriptor passing are C macros and reimplementing Darwin's cmsg alignment in Swift is a worse idea than keeping a C file.

Transport is `posix_spawn` plus `socketpair(AF_UNIX, SOCK_STREAM)` with length-prefixed JSON, the child's end dup2'd onto fd 3. Not XPC: an XPC service is baked into the bundle at signing time, which does not fit plugins installed at runtime, and launchd's automatic restart blurs the one state the design needs to keep sharp — "the host killed it". The socket is a socketpair rather than a pipe because `SCM_RIGHTS` only travels over `AF_UNIX`; framing costs the same either way today, but switching later would mean rewriting the transport layer.

The capability policy gate stays in the host. `host.fetch` in the helper does not check an allowlist — it raises a reverse RPC and the host decides, because a process that may be SIGKILLed at any moment is the wrong place to keep its own checkpoint, and a wedged helper's copy of the allowlist is editable by whatever wedged it.

## Reading the other numbers

Round trips are 0.27 ms at p95 against a 5 ms budget.

E3 is reported twice on purpose. With the 50-tab snapshot re-encoded on every tick, JSON encoding dominates and the extra round trip disappears into it — the measured delta wanders between +0.019 ms and −0.001 ms across runs, which is noise. With a near-empty payload the transport is what is left and the reverse RPC shows up consistently at 0.020 ms, against 0.008 ms for the in-process semaphore. Reporting only the first would have said the reverse RPC is free, which is an artifact of the payload rather than a property of the design.

E4 detects the hang exactly at the configured deadline, and after SIGKILL and reaping, `proc_pid_rusage` and `proc_pidinfo` both fail for that pid and the pid is no longer signalable — no thread, no footprint, no corpse. A replacement helper is loaded and serving 8.3 ms later.

Under App Sandbox the helper's home becomes `~/Library/Containers/dev.zuki.jscore-oop-helper/Data`, `proc_listchildpids` fails with EPERM, and a canary file outside the container cannot be opened by path.

## A gotcha worth keeping

Signing a bare Mach-O executable with `com.apple.security.app-sandbox` makes it die with SIGTRAP inside `_libsecinit_appsandbox`, before `main()`. The crash report says why: `Unable to get bundle identifier for container id ...: Info.plist from code signature information has no value for kCFBundleIdentifierKey`. App Sandbox names the container after `CFBundleIdentifier` read out of the code signature, and a plain executable has no Info.plist to read it from.

The fix is to link one into the binary rather than wrap the helper in an `.app`: `-sectcreate __TEXT __info_plist Sources/PluginHelper/Info.plist`. This matters for the real design, where the helper wants to stay a plain executable next to the app.

## Known gaps

Everything is ad-hoc signed. The variants are genuinely confined and the flags verify (`flags=0x10002(adhoc,runtime)`), but a Developer ID signed, notarized build was not tested. Notarization requires the hardened runtime, which the `allow-jit` variant already uses, so nothing here suggests a problem — it simply was not tried.

The helper trusts the host's framing. Nothing here hardens the host against a malicious helper beyond capping frame size — the threat model is a buggy or runaway plugin, not a hostile one that has already taken over the helper process.

The 500 ms hang deadline is a parameter, not a finding. Nothing here measures what deadline a real plugin workload needs, only that a deadline works.

E1b approximates a fresh install by copying the helper to a path the kernel has not seen. That reproduces the missing validation cache, but a real install also arrives over a download and an unpacking step, and a Developer ID binary additionally faces a notarization check on first launch. 224 ms is a floor for that case, not a full estimate of it.

E1b's tail is unstable even at n=60, and worse below it: 15-trial runs put p95 anywhere from 342 ms to 587 ms. The figures quoted are from two n=60 runs. Anything drawing a line near 500 ms off a short run is reading noise.

## Requirements

macOS 26+ on Apple Silicon. No provisioning profile — `run.sh` ad-hoc signs the sandboxed variants itself.

## How to run

```sh
./run.sh                                       # full run: 30 spawns, 1000 ticks
./run.sh --cold-runs 5 --tick-runs 100         # quick pass
./run.sh --cold-binary-runs 30                 # more samples for the cold-binary case
```

`run.sh` builds, produces four copies of the helper (plain; sandboxed; hardened without `allow-jit`; sandboxed and hardened with `allow-jit`), and runs every experiment. It exits non-zero when a check fails and prints which one.

`swift build` spawns its own `sandbox-exec`, which fails inside another sandbox — `sandbox-exec: sandbox_apply: Operation not permitted` is what that nesting looks like. Building from an already-sandboxed shell needs that shell to allow it.
