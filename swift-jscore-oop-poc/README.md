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
| E8 | Can a bookmark hand the helper a subtree? | not a rejection criterion | yes, but only the **plain** bookmark — app-scope does not cross the process boundary, and document-scope crosses **one file at a time** |
| E9 | What does pre-warming buy? | report the split | **nothing at steady state** — a whole launch is 5 ms. It buys the 94 ms an unvalidated binary costs, and a pooled helper is single-use |

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

This is a limit of SCM_RIGHTS specifically, not of App Sandbox in general — the sanctioned way to hand a sandboxed process a subtree is a security-scoped bookmark or a sandbox extension. E8 tests the first of those, and finds a subtree can be handed over after all.

## Finding 3: a bookmark does hand over a subtree — and it is not the security-scoped one

E7 left the capability design pointed at per-file reverse RPC. E8 asks whether the documented mechanism changes that, and the answer is yes, by a route that inverts the assumption behind the question.

The control comes first, because without it nothing below means anything. With no bookmark in play, the sandboxed helper is refused every fixture by path — `share/inside.txt`, `share/nested/deep.txt`, and the canary alike, all `EPERM`. That is the state E7 measured.

Hand the helper a **plain** bookmark — `bookmarkData(options: [])`, no security scope, minted by the unsandboxed host and shipped as bytes over the existing socket — and it resolves, and the subtree opens. `open` succeeds on `inside.txt`, `openat(dirfd, "inside.txt")` succeeds where E7 measured `EPERM`, and `openat(dirfd, "nested/deep.txt")` reaches a level deeper, so this is a subtree and not one directory. `../canary.txt` stays denied through both the path and the descriptor, so the grant is bounded by what was bookmarked.

The security-scoped bookmark, which is the one the design note expected to need, does not survive the process boundary at all. The host mints it (824 bytes) and resolves its own copy without trouble — `startAccessing` returns true and the file beneath reads — but the helper cannot resolve the same bytes: `NSCocoaErrorDomain 256` in the plain sandboxed helper and `259` in one signed with `com.apple.security.files.bookmarks.app-scope` and `.document-scope`. Both variants fail, which is what rules out the entitlement as the explanation; the host-side control is what rules out the blob being invalid. What is left is that the blob is bound to the minting process or to its signing identity — this run cannot tell which, because every configuration that failed was under a sandbox and none tried resolving in a second process of the host's own binary. Either way the helper cannot use it.

Two details of the plain-bookmark grant matter for how a capability would be built on it. Access is present **before** `startAccessingSecurityScopedResource()` is called, and it is still present after `stopAccessing`, so the scope call is not what grants it — resolving is. And the grant survives the recovery path: a helper killed with SIGKILL while holding it is replaced by one that resolves the same bytes and gets the same access, so a kill costs nothing and the host does not have to re-negotiate per respawn.

What this run does not establish is the mechanism. The ordering is measured — the access appears at resolution — but nothing here shows what resolution does underneath, whether an extension is issued and consumed or something else entirely. An undocumented grant is a thin thing to build a capability on, so the practical reading is that subtree granularity is available and cheap to try, not that it is safe to depend on.

Document-scope is the variant that does cross, and finding that out took diagnosing a failure rather than reporting one. The first attempt asked for a directory inside the temporary directory and got `NSCocoaErrorDomain 256`, which was written down as "document-scope is unanswerable here". It was misuse. A document-scoped bookmark points at a single file and not a folder, and not at a file the system owns, and the temporary directory resolves under `/private` — two violations producing one error code. Moving one variable at a time separates them: with the target a file in the user's home area it mints (864 bytes), and it still mints with the document itself back in the temporary directory, spelled resolved or unresolved (816 bytes either way). Asking for a directory fails, and asking for a file in the temporary directory fails. So the constraint is on the target — a single file, outside the system's own locations — and the document's own whereabouts did not matter across the two places this tried.

Nothing in that goes through `NSOpenPanel`. The bookmark is minted from paths the process chose for itself, which answers the part of the question that mattered: for the unsandboxed host this design actually uses, a manifest-declared path can be the origin, and user selection is not a precondition for creating one. That much is measured only there — a sandboxed minter never got far enough to say, as below.

Across processes it works, under two conditions the run can name. The helper must carry the bookmark entitlements — the plain sandboxed helper fails to resolve with `256` even holding the document — and it must be able to open the document, because a document-scoped bookmark resolves only against it. Withhold the document and the resolve fails naming the document itself; hand the helper a plain bookmark for the directory the document sits in, and the same bytes resolve and open the target. Both controls hold throughout: the target is refused before anything is resolved, and refused again after the bootstrap, so what opens it is the document-scoped bookmark and not the bootstrap that preceded it.

That makes document-scope the only security-scoped variant measured here that crosses a process boundary at all — and it delivers one file. It is not an answer to subtree granularity, which stays with the plain bookmark or with per-file RPC. What it does answer is that a per-file grant can be minted programmatically and handed over, at the cost of delivering the document first, which is a bootstrap the host has to solve by some other means.

A sandboxed minter could not mint one. Every rung fails with `256` there, and the likely reason is where its fixtures land — its home directory is its container under `~/Library/Containers`, which is inside the `Library` the rule excludes — but this run did not vary that to confirm it. One observation is worth recording and not over-reading: the document does acquire `com.apple.security.private.scoped-bookmark-key`, the attribute this mechanism is reported to key itself with. It appears on rungs that failed as well, including in the sandboxed minter where nothing minted at all, so it does not distinguish success from failure and nothing above rests on it.

None of the plain-bookmark findings change when the minting process is itself sandboxed. It mints larger blobs — 1000 bytes rather than 824 — and the relayed plain bookmark resolves stale (`stale: 1`, where the unsandboxed minter's resolves `stale: 0`) but works anyway: the control is denied, the subtree opens, `..` stays refused, and the grant survives a kill. The security-scoped blob fails exactly as before, and the error code tracks the helper rather than the minter — 256 in the plain sandboxed helper, 259 in the bookmark-entitled one, under both minters. Nothing here explains that split.

Measuring that took giving up on the obvious arrangement, and why is worth recording. A sandboxed process cannot spawn a separately-contained child at all: the entitlements of a child of a sandboxed process must be exactly `app-sandbox` plus `inherit`, and the system aborts a child carrying anything else. That abort is what the second pass records — the run sees only `could not run: peer closed the socket`, and the crash report supplies the shape: SIGTRAP inside `_libsecinit_appsandbox` before `main()`, from the same binary that runs fine under an unsandboxed host. `inherit` is not a way around it, because an inheriting child shares the parent's container, which is the variable being measured; the sanctioned route to a separately-contained child is an XPC service, which this design already rejected for runtime-installed plugins.

So the third pass stops making them parent and child. A bookmark is inert bytes, and what it means is fixed by who minted it and who resolves it, not by how it travelled — so the sandboxed minter writes its blobs into its own container and exits, and an unsandboxed orchestrator reads them out and hands them to a genuinely separately-contained helper. The two are siblings. That the no-bookmark control comes back denied in this arrangement, where the second pass's inheriting child could read everything, is what says the containment being measured is real.

Only public Foundation API is involved. `sandbox_extension_issue_file` and `sandbox_extension_consume` are not called anywhere, so nothing above depends on a private mechanism.

## Finding 4: pre-warming is for updates, and a pre-warmed helper is single-use

E1 said the first spawn after an update needs pre-warming. E9 splits a launch at the seams a pool can cut on — `posix_spawn`, waiting for the helper's `ready`, `load`, and the first `tick` — to see what pre-warming actually moves.

At steady state it moves almost nothing worth moving. Spawning costs 0.19 ms, the helper is ready 3.01 ms later, `load` is 0.12 ms and the first `tick` 1.54 ms, so a click that spawns its own helper costs 4.98 ms at the median and a click on a pre-warmed one costs 1.64 ms. Pre-warming takes 3.34 ms off. Both numbers are well inside a 16 ms frame, so at steady state this is not a user-visible difference and a pool cannot be justified by it.

Updates are not the only case pre-warming moves, though, and E9 measures only one of them. E1's first spawn of a run costs 335 ms here against 6.5 ms for every spawn after it, on a binary the kernel has already validated — the session's first launch pays for dyld and for faulting JavaScriptCore in, and that is a cost a pre-warm at app start would move exactly the same way. E9 cannot see it: it runs after E1 through E8, so everything it measures is already warm. The 6.72 ms it reports as its own first launch is a first launch of the section, not of the process.

Where it pays is the case E1b found. Against a binary the kernel has never validated, waiting for `ready` goes from 3.01 ms to 96.75 ms, and the split is 94.18 ms of the extra landing before the click against 2.06 ms on it. The click side is not quite untouched — the first `tick` itself doubles, 1.54 ms to 3.41 ms — but at that size it changes nothing. So pre-warming does not shorten the cost, it relocates it, which is the whole point: paid at app start it is invisible, paid on a click it is not.

That also decides the pool's shape, and the two strategies come apart only after an update. Holding one helper and starting its replacement the moment it is taken is enough at steady state: a second click 5 ms later costs 1.73 ms, so the replacement boots in parallel and 5 ms is already enough of a head start. Do the same with a replacement the kernel has not validated and a back-to-back second click costs 96 ms, with 100 ms of head start bringing the median back to 2.49 ms while the tail still reaches 71 ms — that last figure is one sample out of ten, so read it as "the tail is still there", not as a percentile. One in hand is enough until an update, and then it is not.

A spare also shortens recovery, though not by enough to matter. Replacing a killed helper from the pool serves 1.86 ms after the kill against the 7.02 ms E4 measured in the same run with the spawn on that path. Both disappear behind the 500 ms it takes to decide the plugin is hung, so recovery is not a reason to keep a pool.

An idle helper costs 4.0 MiB and 8 µs of CPU over ten seconds, with two threads and a flat footprint, so how many to hold is purely a memory question. What that ten-second window does not answer is what an hour looks like — whether the pages stay resident under memory pressure, or whether a process with no window becomes eligible for App Nap, is untested here.

The last question is whether a pre-warmed helper can serve any plugin or only the one it was warmed for, and the answer is neither quite. Loading a second plugin into a helper that already ran one lets the second see what the first left in `globalThis` — the probe reports the marker verbatim, which is what makes the rest of this measurable rather than assumed. Rebuilding the virtual machine and the context clears that in 0.35 ms. But the memory does not come back: after allocating 100 MB and resetting, the footprint sits at 105.6 MiB against 105.1 before, so the reset returns visibility and not pages. A pooled helper is therefore blank stock — hand it out once, and when the plugin is done, discard the process rather than recycling it. Whether JavaScriptCore would release those pages given longer than the 1.5 s settle window this waits is untested.

One number in this section is unexplained. A second click gets slower the longer the replacement has been sitting: 1.73 ms at a 5 ms gap, then 1.91, 2.35, 2.63, and 2.73 ms at 100 ms. It is monotonic across four points rather than noise-shaped, and it is about a millisecond in total, so it changes nothing here — but a pre-warmed helper being slightly slower the longer it waits is the opposite of the assumption. It is equally consistent with the measuring host idling through the gap rather than the helper aging, since the gap is a `Thread.sleep` on this side; a busy-wait in place of the sleep would separate the two, and was not run.

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

E9's cold-binary figures came in lower than E1b's. The unvalidated-binary launches here land at 96.75 ms p50 where the README's headline figure is 164–224 ms, and E1b in the same run reported 101.64 ms p95 at n=5. The E9 numbers are internally consistent and the phase split they support does not depend on the absolute value, but the headline range came from two n=60 runs and this did not reproduce it — the machine or its caches were in a different state, and which is unmeasured.

The session's very first spawn is unmeasured by E9. E1 reports it — 335 ms here against 6.5 ms warm — but E9 runs after everything else and never sees a cold process, so how much of that a pre-warm at app start would actually recover is inferred from E1's split rather than measured directly.

E9's idle observation is ten seconds. Memory pressure, page eviction and App Nap all act on longer horizons, and whether a windowless helper process is even eligible for App Nap was not checked.

E9's reset was given 1.5 s to return memory. That the footprint had not dropped by then does not establish that JavaScriptCore never returns those pages, only that it had not yet.

E8's exit code does not reflect E8. Its verdicts are recorded but never counted as failures, because neither answer rejects the design — so a configuration that could not run at all is still reported under `all checks passed`. The second pass in particular prints `could not run: peer closed the socket` for two of its three configurations and the summary stays green. Read the section, not the summary.

What E8 measured is a read grant. Every probe is `open(O_RDONLY)`, `opendir`, or `openat(O_RDONLY)` — writing, creating, and unlinking beneath the subtree were never tried, so "subtree granularity" here means reading a subtree. E7 is explicit that its granularity is per-file for reading and per-directory for listing; this is the same kind of qualifier and it has not been measured away.

The plain-bookmark grant is undocumented as far as this run knows. It was found by measurement, its mechanism is not established, and nothing here says Apple intends it or will keep it. A capability design that depends on it is depending on observed behavior.

Which bookmark entitlement the resolving helper needs is not separated. The comparison is between a helper carrying neither and one carrying both `app-scope` and `document-scope`; no variant carried only one, so "the helper must carry the bookmark entitlements" is as fine-grained as this run gets. The document-scoped grant's own lifetime is also unprobed — whether it outlives `stopAccessing` or a SIGKILL the way the plain one does was only measured for the plain one.

Why a sandboxed minter cannot mint a document-scoped bookmark is inferred, not measured. Its fixtures land in its container under `~/Library/Containers`, which the rule about system locations would cover, but no rung varied that — a temporary exception letting it write somewhere else would settle it.

A sandboxed host still cannot own the helper. The third pass measures a sandboxed *minter*, which is the variable the bookmark result depends on, but it does so by running the two as siblings. Whether a sandboxed host can hold a separately-contained plugin helper as a child is a different question, and the answer there is no by rule rather than by measurement — `inherit` shares the container, and the only sanctioned alternative is the XPC service this design rejected. A host that has to be sandboxed needs that settled before any of this transfers.

The helper trusts the host's framing. Nothing here hardens the host against a malicious helper beyond capping frame size — the threat model is a buggy or runaway plugin, not a hostile one that has already taken over the helper process.

The 500 ms hang deadline is a parameter, not a finding. Nothing here measures what deadline a real plugin workload needs, only that a deadline works.

E1b approximates a fresh install by copying the helper to a path the kernel has not seen. That reproduces the missing validation cache, but a real install also arrives over a download and an unpacking step, and a Developer ID binary additionally faces a notarization check on first launch. 224 ms is a floor for that case, not a full estimate of it.

E1b's tail is unstable even at n=60, and worse below it: 15-trial runs put p95 anywhere from 342 ms to 587 ms. The figures quoted are from two n=60 runs. Anything drawing a line near 500 ms off a short run is reading noise.

## Requirements

macOS 26+ on Apple Silicon. No provisioning profile — `run.sh` ad-hoc signs the sandboxed variants itself.

## How to run

```sh
./run.sh                                       # full run: 30 spawns, 1000 ticks
./run.sh --cold-runs 5 --tick-runs 100 --prewarm-runs 5 --idle-samples 4   # quick pass
./run.sh --cold-binary-runs 30                 # more samples for the cold-binary case
```

`run.sh` builds, produces five copies of the helper (plain; sandboxed; hardened without `allow-jit`; sandboxed and hardened with `allow-jit`; sandboxed with the two bookmark entitlements), and runs every experiment. It exits non-zero when a check fails and prints which one. E8's verdicts are the exception: none of them counts as a failure. An error inside E8 still aborts the run, so this is about its judgements, not its immunity.

It then signs a sandboxed copy of the host and runs E8 through it twice more, because minting a bookmark is an App Sandbox facility and a host that is not contained cannot answer whether a contained one behaves differently. The second pass has it spawn helpers directly, which is where the abort above shows up; the third splits minting from probing so the sandboxed minter and the sandboxed helper are siblings rather than parent and child, and that is the pass that actually measures a contained minter.

Both take absolute helper paths: App Sandbox redirects the host's working directory into its container, so a relative path fails with `ENOENT` before the sandbox has an opinion. The sandboxed copy's entitlements are generated at signing time rather than committed — spawning a helper outside its container needs a read-only temporary exception for the build directory, and that path is machine-specific. The minter writes its blobs inside its own container, since that exception is read-only and its container is the one place it can write.

`swift build` spawns its own `sandbox-exec`, which fails inside another sandbox — `sandbox-exec: sandbox_apply: Operation not permitted` is what that nesting looks like. Building from an already-sandboxed shell needs that shell to allow it.
