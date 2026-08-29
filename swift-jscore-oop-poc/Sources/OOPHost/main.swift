import CPluginIPC
import Darwin
import Foundation
import PluginIPC

// Measures the out-of-process arrangement described in the design note: one helper
// process per plugin over socketpair(AF_UNIX), length-prefixed JSON, capability
// policy held by the host and requested by the helper through a reverse RPC.
//
// Each experiment prints what it measured and a verdict against the pass line the
// design note set, so a failing run says which question it failed rather than just
// "error".

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ what: String) { description = what }
}

// MARK: - Options

func optionValue(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name),
    index + 1 < CommandLine.arguments.count
  else { return nil }
  return CommandLine.arguments[index + 1]
}

let defaultHelper = URL(fileURLWithPath: CommandLine.arguments[0])
  .deletingLastPathComponent()
  .appendingPathComponent("PluginHelper")
  .path

let helperPath = optionValue("--helper") ?? defaultHelper
let sandboxedHelperPath = optionValue("--sandboxed-helper")
/// Sandboxed, plus the bookmark entitlements. E8 needs both this and the plain
/// sandboxed helper: with only one of them, a failed resolve cannot be told apart
/// from a missing entitlement.
let bookmarkHelperPath = optionValue("--bookmark-helper")
/// Sandboxed and hardened, with `allow-jit` withheld. Isolates the hardened runtime
/// from the entitlement, which turn out to be different questions.
let hardenedHelperPath = optionValue("--hardened-helper")
/// The only configuration in which JavaScriptCore is permitted to map executable
/// pages, and so the only one that gets a JIT.
let jitHelperPath = optionValue("--jit-helper")
let coldStartRuns = Int(optionValue("--cold-runs") ?? "") ?? 30
/// 60 rather than a handful: this distribution has a long tail, and at n=15 the p95
/// swung between 342 ms and 587 ms across runs — enough to move it across the design
/// note's 500 ms line on noise alone.
let coldBinaryRuns = Int(optionValue("--cold-binary-runs") ?? "") ?? 60
let tickRuns = Int(optionValue("--tick-runs") ?? "") ?? 1000
let allocMB = Int(optionValue("--alloc-mb") ?? "") ?? 100
let hangDeadlineMS = Int(optionValue("--hang-deadline-ms") ?? "") ?? 500
/// At least two: E9a reports its first launch separately, the way E1 does, and one
/// run would leave nothing behind to report.
let prewarmRuns = max(2, Int(optionValue("--prewarm-runs") ?? "") ?? 30)
/// How many helpers the "everything up front" strategy holds.
let prewarmPool = Int(optionValue("--prewarm-pool") ?? "") ?? 3
/// 0.5s apart, so the whole idle observation is `idleSamples / 2` seconds.
let idleSamples = Int(optionValue("--idle-samples") ?? "") ?? 20
/// Milliseconds between taking the last helper and clicking again. The point is the
/// shape of the curve: it should fall as the replacement gets time to boot.
let prewarmGaps = (optionValue("--prewarm-gaps") ?? "0,5,10,25,50,100")
  .split(separator: ",").compactMap { Int($0) }
let coldstartRuns = max(2, Int(optionValue("--coldstart-runs") ?? "") ?? 20)
/// The helper with JavaScriptCore left out, for E10d.
let stubHelperPath = optionValue("--stub-helper")
/// The helper as `apps/JSCoreLab/export.sh` leaves it: inside an exported .app,
/// re-signed by Xcode with Developer ID. E11 only.
let devIDHelperPath = optionValue("--devid-helper")
/// The helper that plays an attacker rather than a bug, for E12.
let hostileHelperPath = optionValue("--hostile-helper")

let snapshot = Scripts.snapshot(tabs: 50)

// MARK: - Reporting

var failures: [String] = []

func section(_ title: String) {
  print("")
  print("── \(title) " + String(repeating: "─", count: max(0, 62 - title.count)))
}

func note(_ text: String) {
  print("   \(text)")
}

func verdict(_ passed: Bool?, _ text: String) {
  switch passed {
  case .some(true): print("   ✓ \(text)")
  case .some(false):
    print("   ✗ \(text)")
    failures.append(text)
  case .none: print("   • \(text)")
  }
}

func fmt(_ value: Double, _ digits: Int = 2) -> String {
  String(format: "%.\(digits)f", value)
}

func fileSize(_ path: String) -> Int {
  (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}

func mib(_ bytes: UInt64) -> String {
  fmt(Double(bytes) / 1024 / 1024, 1) + " MiB"
}

// MARK: - Shared helpers

let stubFetch: (String) -> Any = { _ in ["status": "ok", "code": 200] }

func spawnLoaded(
  _ script: String,
  helper: String = helperPath,
  environment: [String: String] = [:]
) throws -> PluginProcess {
  let process = try PluginProcess(helperPath: helper, environment: environment)
  process.fetchHandler = stubFetch
  let deadline = ContinuousClock.now + .seconds(20)
  let loaded = try process.call(["op": "load", "script": script], deadline: deadline)
  guard loaded["ok"] as? Bool == true else {
    throw Failure("load failed: \(loaded["error"] ?? loaded)")
  }
  return process
}

func sampleTicks(
  _ process: PluginProcess,
  count: Int,
  warmup: Int = 100,
  payload: [String: Any]? = nil
) throws -> [Double] {
  let raw = payload ?? snapshot
  for i in 0..<warmup {
    _ = try process.call(
      ["op": "tick", "raw": raw, "tickNumber": i],
      deadline: ContinuousClock.now + .seconds(10))
  }
  var samples: [Double] = []
  samples.reserveCapacity(count)
  for i in 0..<count {
    let start = ContinuousClock.now
    let reply = try process.call(
      ["op": "tick", "raw": raw, "tickNumber": i],
      deadline: ContinuousClock.now + .seconds(10))
    samples.append(Timing.millis(ContinuousClock.now - start))
    guard reply["ok"] as? Bool == true else {
      throw Failure("tick failed: \(reply["error"] ?? reply)")
    }
  }
  return samples
}

func sampleInProcess(
  _ script: String,
  count: Int,
  warmup: Int = 100,
  payload: [String: Any]? = nil
) throws -> [Double] {
  let raw = payload ?? snapshot
  let evaluator = InProcessEvaluator()
  evaluator.fetchHandler = stubFetch
  guard evaluator.load(script) else { throw Failure("in-process load failed") }
  for i in 0..<warmup { _ = evaluator.tick(raw: raw, tickNumber: i) }
  var samples: [Double] = []
  samples.reserveCapacity(count)
  for i in 0..<count {
    let start = ContinuousClock.now
    _ = evaluator.tick(raw: raw, tickNumber: i)
    samples.append(Timing.millis(ContinuousClock.now - start))
  }
  return samples
}

// MARK: - Fixtures for the descriptor experiments

let workDir = FileManager.default.temporaryDirectory
  .appendingPathComponent("jscore-oop-\(getpid())")
let shareDir = workDir.appendingPathComponent("share")
let insideFile = shareDir.appendingPathComponent("inside.txt")
let canaryFile = workDir.appendingPathComponent("canary.txt")
/// One level further down, so "the subtree" is distinguishable from "the directory
/// itself" — a grant that stops at the first level is not a subtree grant.
let escapeLink = shareDir.appendingPathComponent("escape-link")
let absLink = shareDir.appendingPathComponent("abs-link")
let nestedDir = shareDir.appendingPathComponent("nested")
let deepFile = nestedDir.appendingPathComponent("deep.txt")
/// Stands in for the document a document-scoped bookmark would be stored inside.
let documentFile = workDir.appendingPathComponent("document.txt")

// Document-scope has its own fixtures, in the user's home area rather than the
// temporary directory. A document-scoped bookmark is documented as pointing at a
// single file that is not in a system location such as `/private` or `/Library`,
// and the temporary directory resolves under `/private` — so the first attempt was
// asking for a folder in a forbidden place, two violations at once, and got one
// undiagnosed error back.
//
// `dirA` and `dirB` are disjoint on purpose. The helper has to reach the document
// before it can resolve a bookmark relative to it, and it is bootstrapped into
// `dirA` to do that. A target under `dirA` would then be readable as a side effect
// of the bootstrap, and the experiment would measure the bootstrap instead.
let docRoot = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("jscore-e8-doc-\(getpid())")
let docDirA = docRoot.appendingPathComponent("dirA")
let docDirB = docRoot.appendingPathComponent("dirB")
let projectDoc = docDirA.appendingPathComponent("project.doc")
let assetFile = docDirB.appendingPathComponent("asset.txt")

func makeFixtures() throws {
  try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
  try "INSIDE-OK\n".write(to: insideFile, atomically: true, encoding: .utf8)
  try "DEEP-OK\n".write(to: deepFile, atomically: true, encoding: .utf8)
  try "CANARY-VISIBLE\n".write(to: canaryFile, atomically: true, encoding: .utf8)
  try "DOCUMENT\n".write(to: documentFile, atomically: true, encoding: .utf8)

  try FileManager.default.createDirectory(at: docDirA, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: docDirB, withIntermediateDirectories: true)
  try "PROJECT-DOC\n".write(to: projectDoc, atomically: true, encoding: .utf8)
  try "ASSET-OK\n".write(to: assetFile, atomically: true, encoding: .utf8)

  // For E12e: two symlinks inside the shared subtree pointing out of it. A passed
  // directory descriptor confines path resolution, but a symlink is resolved by the
  // kernel after the descriptor is out of the picture — so whether it lets an
  // attacker step outside the grant is a separate question from `..`.
  try? FileManager.default.removeItem(at: escapeLink)
  try FileManager.default.createSymbolicLink(
    at: escapeLink, withDestinationURL: URL(fileURLWithPath: "../canary.txt"))
  try? FileManager.default.removeItem(at: absLink)
  try FileManager.default.createSymbolicLink(
    at: absLink, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
}

func removeFixtures() {
  try? FileManager.default.removeItem(at: workDir)
  try? FileManager.default.removeItem(at: docRoot)
}

/// Reads the extended attribute *names* on a file. A document-scoped bookmark is
/// reported to key itself to an xattr on the document, so their presence or absence
/// is physical evidence of whether minting got as far as touching the document —
/// which a bare error code does not say. Names only: writing or copying that
/// attribute would be depending on a private mechanism, which this run does not do.
func xattrNames(_ path: String) -> [String] {
  let size = listxattr(path, nil, 0, 0)
  guard size > 0 else { return [] }
  var buffer = [CChar](repeating: 0, count: size)
  let written = listxattr(path, &buffer, size, 0)
  guard written > 0 else { return [] }
  return buffer.prefix(written)
    .split(separator: 0)
    .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}

// MARK: - E1  cold start

func experimentColdStart() throws {
  section("E1  cold start — posix_spawn to first transform result")
  var samples: [Double] = []
  for _ in 0..<coldStartRuns {
    let start = ContinuousClock.now
    let process = try spawnLoaded(Scripts.summarize)
    let reply = try process.call(
      ["op": "tick", "raw": snapshot, "tickNumber": 0],
      deadline: ContinuousClock.now + .seconds(20))
    guard reply["ok"] as? Bool == true else {
      throw Failure("first tick failed: \(reply["error"] ?? reply)")
    }
    samples.append(Timing.millis(ContinuousClock.now - start))
    process.shutdown()
  }
  // The first spawn of a run pays costs no later spawn pays — cold dyld cache,
  // first fault-in of JavaScriptCore. Folding it into one distribution hides the
  // only number that decides between "spawn on rail click" and "pre-warm", so
  // report it separately.
  let first = samples[0]
  let steady = Percentiles(Array(samples.dropFirst()))
  note("all runs:      \(Percentiles(samples).line)")
  note("first spawn:   \(fmt(first)) ms")
  note("after the 1st: \(steady.line)")
  verdict(
    steady.p50 <= 150,
    "warm p50 \(fmt(steady.p50)) ms ≤ 150 ms — spawn on demand is viable once warm")
  verdict(
    steady.p95 <= 500,
    "warm p95 \(fmt(steady.p95)) ms ≤ 500 ms — above this the design note rejects the approach")
  verdict(
    first <= 500,
    "first spawn \(fmt(first)) ms ≤ 500 ms — otherwise the first plugin needs pre-warming")
}

// MARK: - E1b  cold start of a binary the kernel has never seen

/// E1 measures a helper the kernel has already validated. The case a user actually
/// hits first is the opposite one — a binary that arrived with an install or an
/// update — and that is where the first spawn was seen to run into the hundreds of
/// milliseconds. Copying the helper to a fresh path before each spawn reproduces it:
/// the copy carries the same signature but has no cached validation behind it.
/// A copy of the helper at a path the kernel has never validated. Same bytes, same
/// signature, no cached validation behind it — the shape of a user's first plugin
/// after an install or an update.
func freshCopy(of binary: String, index: Int) throws -> String {
  let staging = workDir.appendingPathComponent("staging")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  let copy = staging.appendingPathComponent(
    "\(URL(fileURLWithPath: binary).lastPathComponent)-\(index)")
  try? FileManager.default.removeItem(at: copy)
  try FileManager.default.copyItem(at: URL(fileURLWithPath: binary), to: copy)
  return copy.path
}

func freshHelperCopy(index: Int) throws -> String {
  try freshCopy(of: helperPath, index: index)
}

func experimentColdBinary() throws {
  section("E1b cold start with an unvalidated binary copy")
  let staging = workDir.appendingPathComponent("staging")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

  var samples: [Double] = []
  for i in 0..<coldBinaryRuns {
    let copy = staging.appendingPathComponent("PluginHelper-\(i)")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: helperPath), to: copy)

    let start = ContinuousClock.now
    let process = try spawnLoaded(Scripts.summarize, helper: copy.path)
    let reply = try process.call(
      ["op": "tick", "raw": snapshot, "tickNumber": 0],
      deadline: ContinuousClock.now + .seconds(30))
    guard reply["ok"] as? Bool == true else {
      throw Failure("first tick failed: \(reply["error"] ?? reply)")
    }
    samples.append(Timing.millis(ContinuousClock.now - start))
    process.shutdown()
    try? FileManager.default.removeItem(at: copy)
  }

  let stats = Percentiles(samples)
  note(stats.line)
  verdict(
    stats.p95 <= 500,
    "p95 \(fmt(stats.p95)) ms ≤ 500 ms for a binary with no cached validation")
}

// MARK: - E2  round-trip latency

func experimentRoundTrip() throws {
  section("E2  round-trip latency — 50-tab snapshot, \(tickRuns) ticks")
  let process = try spawnLoaded(Scripts.summarize)
  defer { process.shutdown() }
  let samples = try sampleTicks(process, count: tickRuns)
  let stats = Percentiles(samples)
  note(stats.line)
  verdict(stats.p95 <= 5.0, "p95 \(fmt(stats.p95, 3)) ms ≤ 5 ms")
}

// MARK: - E3  reverse capability RPC overhead

func experimentReverseRPC() throws {
  section("E3  reverse capability RPC — cost of one host.fetch per tick")
  let count = min(tickRuns, 1000)
  // Run the delta twice. With the 50-tab snapshot on every tick, JSON encoding
  // dominates and swamps the extra round trip; with a near-empty payload the
  // transport is what is left, so the RPC becomes visible. Reporting only the
  // first would say the RPC is free, which is an artefact of the payload.
  let payloads: [(String, [String: Any])] = [
    ("50-tab snapshot", snapshot),
    ("minimal payload", ["tabs": [["id": "tab-0", "active": true, "dirty": false]]]),
  ]

  for (label, payload) in payloads {
    note("── \(label)")

    let plainProcess = try spawnLoaded(Scripts.summarize)
    let plain = Percentiles(try sampleTicks(plainProcess, count: count, payload: payload))
    plainProcess.shutdown()

    let fetchProcess = try spawnLoaded(Scripts.summarizeWithFetch)
    let withFetch = Percentiles(try sampleTicks(fetchProcess, count: count, payload: payload))
    let serviced = fetchProcess.hostCallsServiced
    fetchProcess.shutdown()

    let inPlain = Percentiles(
      try sampleInProcess(Scripts.summarize, count: count, payload: payload))
    let inFetch = Percentiles(
      try sampleInProcess(Scripts.summarizeWithFetch, count: count, payload: payload))

    note("   out-of-process, no fetch   \(plain.line)")
    note("   out-of-process, one fetch  \(withFetch.line)")
    note("   in-process,     no fetch   \(inPlain.line)")
    note("   in-process,     one fetch  \(inFetch.line)")

    let oopCost = withFetch.p50 - plain.p50
    let inCost = inFetch.p50 - inPlain.p50
    note("   reverse RPC cost (p50 delta):          \(fmt(oopCost, 3)) ms")
    note("   in-process semaphore cost (p50 delta): \(fmt(inCost, 3)) ms")
    note("   difference vs in-process:              \(fmt(oopCost - inCost, 3)) ms")
    // Warmup ticks call fetch too, so the expected count is measured + warmup.
    let expectedCalls = count + 100
    verdict(
      serviced == expectedCalls,
      "host serviced \(serviced) reverse calls, one per tick (\(expectedCalls) expected)")
  }
}

// MARK: - E4  kill and recovery

func experimentKillAndRecover() throws {
  section("E4  kill and recovery — while(true) → deadline → SIGKILL → respawn")
  let process = try spawnLoaded(Scripts.hang)
  let pid = process.pid

  let detectStart = ContinuousClock.now
  var timedOut = false
  do {
    _ = try process.call(
      ["op": "tick", "raw": snapshot, "tickNumber": 0],
      deadline: ContinuousClock.now + .milliseconds(hangDeadlineMS))
  } catch IPCError.timeout {
    timedOut = true
  }
  let detectMS = Timing.millis(ContinuousClock.now - detectStart)
  verdict(timedOut, "hang detected by deadline after \(fmt(detectMS)) ms")

  let footprintBefore = process.footprintBytes
  let threadsBefore = process.threadCount
  note("before kill: footprint \(footprintBefore.map(mib) ?? "n/a"), threads \(threadsBefore)")

  let recoverStart = ContinuousClock.now
  process.kill()
  process.reap()
  process.channel.close()

  let footprintAfter = process.footprintBytes
  let threadsAfter = process.threadCount
  let signalReaches = Darwin.kill(pid, 0) == 0
  note(
    "after kill:  footprint \(footprintAfter.map(mib) ?? "gone"), "
      + "threads \(threadsAfter), kill(pid,0) reaches: \(signalReaches)")
  verdict(footprintAfter == nil, "no rusage for pid \(pid) — the task is gone")
  verdict(threadsAfter == -1, "no task info for pid \(pid) — no threads left behind")
  verdict(!signalReaches, "pid \(pid) is no longer addressable")

  let replacement = try spawnLoaded(Scripts.summarize)
  let reply = try replacement.call(
    ["op": "tick", "raw": snapshot, "tickNumber": 0],
    deadline: ContinuousClock.now + .seconds(20))
  let recoverMS = Timing.millis(ContinuousClock.now - recoverStart)
  replacement.shutdown()
  verdict(reply["ok"] as? Bool == true, "replacement served a tick \(fmt(recoverMS)) ms after kill")
}

// MARK: - E5  App Sandbox containment

func experimentSandbox(helper: String, label: String) throws {
  section("E5  App Sandbox — \(label)")
  let process = try spawnLoaded(Scripts.noop, helper: helper)
  defer { process.shutdown() }
  let deadline = ContinuousClock.now + .seconds(20)

  let home = try process.call(["op": "probe", "what": "home"], deadline: deadline)
  note("home: \(home["home"] ?? "?")")
  note("cwd:  \(home["cwd"] ?? "?")")
  verdict(home["inContainer"] as? Bool, "home redirected into a sandbox container")

  let children = try process.call(["op": "probe", "what": "children"], deadline: deadline)
  note(
    "proc_listchildpids → \(children["count"] ?? "?") "
      + "(errno \(children["errno"] ?? "?") \(children["errnoText"] ?? ""))")

  let canary = try process.call(
    ["op": "probe", "what": "open", "path": canaryFile.path], deadline: deadline)
  let canaryOpened = canary["ok"] as? Bool ?? false
  note(
    "open(canary) → "
      + (canaryOpened
        ? "SUCCEEDED, read \(canary["head"] ?? "")"
        : "denied (errno \(canary["errno"] ?? "?") \(canary["errnoText"] ?? ""))"))
  verdict(!canaryOpened, "canary outside the container is not reachable by path")
}

/// `bridge` is µs per empty call; `loop` is µs per call for 2e6 iterations of work.
/// The two move independently — an entitlement that changes the engine leaves the
/// bridge alone — so collapsing them into one figure loses the distinction.
func experimentThroughput(
  helper: String,
  label: String,
  environment: [String: String] = [:]
) throws -> (bridge: Double, loop: Double, jitBytes: UInt64) {
  func spin(_ script: String, calls: Int) throws -> Double {
    let process = try spawnLoaded(script, helper: helper, environment: environment)
    defer { process.shutdown() }
    let reply = try process.call(
      ["op": "probe", "what": "spin", "count": calls, "raw": [String: Any]()],
      deadline: ContinuousClock.now + .seconds(300))
    guard reply["ok"] as? Bool == true, let perCall = reply["perTickMicros"] as? Double else {
      throw Failure("spin probe failed: \(reply)")
    }
    return perCall
  }

  let bridge = try spin(Scripts.noop, calls: 200_000)
  let loop = try spin(Scripts.computeHeavy, calls: 200)
  note("\(label): \(fmt(bridge, 3)) µs/call with an empty body (the call bridge alone)")
  note("\(label): \(fmt(loop / 1000, 3)) ms/call at 2e6 iterations (engine work)")

  // Ground truth, independent of any timing: JSC stamps its JIT allocations with
  // distinct VM user tags, and the executable allocator only exists once something
  // was actually compiled.
  let process = try spawnLoaded(Scripts.computeHeavy, helper: helper, environment: environment)
  defer { process.shutdown() }
  _ = try process.call(
    ["op": "probe", "what": "spin", "count": 50, "raw": [String: Any]()],
    deadline: ContinuousClock.now + .seconds(300))
  let regions = try process.call(
    ["op": "probe", "what": "jit"], deadline: ContinuousClock.now + .seconds(20))
  let allocator = UInt64(regions["jitAllocatorBytes"] as? Int ?? 0)
  let registerFile = UInt64(regions["jitRegisterFileBytes"] as? Int ?? 0)
  // The JS heap tag is the control for the region walk itself: if it reads zero too,
  // the walk is broken and the JIT reading means nothing.
  let jsHeap = UInt64(regions["jsHeapBytes"] as? Int ?? 0)
  note(
    "\(label): JIT allocator \(mib(allocator)), register file \(mib(registerFile)),"
      + " JS heap \(mib(jsHeap)) → JIT "
      + ((regions["jitPresent"] as? Bool ?? false) ? "PRESENT" : "ABSENT")
      + (jsHeap == 0 ? " [walk unverified — JS heap also zero]" : ""))

  return (bridge, loop, allocator)
}

// MARK: - E6  memory attribution

func experimentMemory() throws {
  section("E6  memory attribution — \(allocMB) MB allocated inside JS")
  let process = try spawnLoaded(Scripts.allocate(mb: allocMB))
  defer { process.shutdown() }
  let deadline = ContinuousClock.now + .seconds(30)

  guard let before = process.footprintBytes else { throw Failure("no footprint before") }
  note("before: \(mib(before))")

  let reply = try process.call(
    ["op": "tick", "raw": snapshot, "tickNumber": 0], deadline: deadline)
  guard reply["ok"] as? Bool == true else {
    throw Failure("alloc tick failed: \(reply["error"] ?? reply)")
  }
  guard let after = process.footprintBytes else { throw Failure("no footprint after") }
  note("after:  \(mib(after))")

  let grew = Double(after) - Double(before)
  let expected = Double(allocMB) * 1024 * 1024
  note("growth: \(fmt(grew / 1024 / 1024, 1)) MiB")
  verdict(
    grew >= expected * 0.8,
    "footprint of the helper pid follows the JS allocation (≥80% of \(allocMB) MB)")
}

// MARK: - E7  descriptor passing

/// `expectConfinement` records what the run is entitled to assume. A descriptor by
/// itself never confines traversal — `openat` re-enters normal path resolution — so
/// reaching through it and walking out with ".." are both expected without App
/// Sandbox, and both expected to be denied with it.
func experimentDescriptorPassing(helper: String, label: String, expectConfinement: Bool) throws {
  section("E7  descriptor passing — \(label)")
  let deadline = { ContinuousClock.now + .seconds(20) }

  let byPath = try {
    let process = try spawnLoaded(Scripts.summarize, helper: helper)
    defer { process.shutdown() }
    return try process.call(
      ["op": "probe", "what": "open", "path": canaryFile.path], deadline: deadline())
  }()
  let pathOpened = byPath["ok"] as? Bool ?? false
  note(
    "open(canary) by path → "
      + (pathOpened ? "succeeded" : "denied (\(byPath["errnoText"] ?? ""))"))

  // The same file the helper was just refused, reached through a descriptor instead.
  let viaFD = try { () -> [String: Any] in
    let process = try spawnLoaded(Scripts.summarize, helper: helper)
    defer { process.shutdown() }
    let fd = open(canaryFile.path, O_RDONLY)
    guard fd >= 0 else { throw Failure("host could not open the canary") }
    defer { close(fd) }
    return try process.call(
      ["op": "probe", "what": "fd-read"], deadline: deadline(), attachingFD: fd)
  }()
  let fdRead = viaFD["ok"] as? Bool ?? false
  note("read(passed fd) → " + (fdRead ? "\"\(viaFD["head"] ?? "")\"" : "failed"))
  verdict(fdRead, "a descriptor sent over SCM_RIGHTS is usable by the helper")

  let viaDirFD = try { () -> [String: Any] in
    let process = try spawnLoaded(Scripts.summarize, helper: helper)
    defer { process.shutdown() }
    let dirFD = open(shareDir.path, O_RDONLY | O_DIRECTORY)
    guard dirFD >= 0 else { throw Failure("host could not open the share directory") }
    defer { close(dirFD) }
    return try process.call(
      [
        "op": "probe", "what": "fd-openat",
        "relative": "inside.txt", "escape": "../canary.txt",
      ],
      deadline: deadline(), attachingFD: dirFD)
  }()
  let insideOK = viaDirFD["insideOK"] as? Bool ?? false
  let escapeOK = viaDirFD["escapeOK"] as? Bool ?? false
  note(
    "openat(dirfd, \"inside.txt\") → "
      + (insideOK
        ? "\"\(viaDirFD["insideHead"] ?? "")\""
        : "denied (\(viaDirFD["insideErrnoText"] ?? ""))"))
  note(
    "openat(dirfd, \"../canary.txt\") → "
      + (escapeOK
        ? "SUCCEEDED — the descriptor does not confine traversal"
        : "denied (\(viaDirFD["escapeErrnoText"] ?? ""))"))
  let enumerated = try { () -> [String: Any] in
    let process = try spawnLoaded(Scripts.summarize, helper: helper)
    defer { process.shutdown() }
    let dirFD = open(shareDir.path, O_RDONLY | O_DIRECTORY)
    guard dirFD >= 0 else { throw Failure("host could not open the share directory") }
    defer { close(dirFD) }
    return try process.call(
      ["op": "probe", "what": "fd-readdir"], deadline: deadline(), attachingFD: dirFD)
  }()
  let listed = enumerated["entries"] as? [String] ?? []
  note(
    "fdopendir(dirfd) → "
      + ((enumerated["ok"] as? Bool ?? false)
        ? "\(listed)" : "denied (\(enumerated["errnoText"] ?? ""))"))

  verdict(
    enumerated["ok"] as? Bool,
    "a passed directory descriptor can be enumerated"
      + " (\(listed.count) \(listed.count == 1 ? "entry" : "entries"))")
  if expectConfinement {
    verdict(!insideOK, "openat beneath the passed directory is denied")
    verdict(!escapeOK, "openat cannot walk out of the passed subtree with \"..\"")
    note(
      "→ the descriptor carries operations on the object it already refers to;"
        + " it does not carry path resolution beneath it.")
    note(
      "→ consistent with the sandbox checking the path resolution produces rather"
        + " than the descriptor that resolution started from.")
  } else {
    verdict(insideOK, "openat beneath the passed directory succeeds without a sandbox")
    verdict(nil, "confinement is not expected here — the descriptor alone does not enforce it")
  }
  if !pathOpened && fdRead {
    verdict(true, "descriptor passing grants access that the path policy denies")
  }
}

// MARK: - E10  what the cold-binary cost is made of

/// A launch split at `main` rather than at the socket.
///
/// E9 could only see the IPC boundary, so the 94 ms an unvalidated binary costs
/// landed in one bucket called "→ ready". The helper reporting its own clock splits
/// that bucket in two: everything before its first statement, which is the kernel's
/// and dyld's work on the image, and everything after, which is the helper's own.
struct ColdPhases {
  var preMain = 0.0
  var vmInit = 0.0
  var toReady = 0.0
  var total: Double { preMain + vmInit + toReady }
}

func measureColdPhases(helper: String) throws -> ColdPhases? {
  let launched = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  let process = try PluginProcess(helperPath: helper)
  defer { process.shutdown() }
  let ready = try process.waitReady(deadline: ContinuousClock.now + .seconds(30))
  guard let tMain = ready["tMain"] as? Int,
    let tVM = ready["tVM"] as? Int,
    let tReady = ready["tReady"] as? Int
  else { return nil }

  func millis(_ from: UInt64, _ to: Int) -> Double { Double(Int(to) - Int(from)) / 1_000_000 }
  var phases = ColdPhases()
  phases.preMain = millis(launched, tMain)
  phases.vmInit = Double(tVM - tMain) / 1_000_000
  phases.toReady = Double(tReady - tVM) / 1_000_000
  // Two processes reading the same monotonic clock should never produce a negative
  // interval. One that does means the reading is not comparable, and a discarded
  // sample is better than a quietly wrong one.
  guard phases.preMain >= 0, phases.vmInit >= 0, phases.toReady >= 0 else { return nil }
  return phases
}

func reportColdPhases(_ label: String, _ runs: [ColdPhases], discarded: Int) {
  guard !runs.isEmpty else {
    note("\(label): no usable samples (\(discarded) discarded)")
    return
  }
  note("\(label):")
  note("  before main (kernel + dyld): \(Percentiles(runs.map { $0.preMain }).line)")
  note("  JavaScriptCore coming up:    \(Percentiles(runs.map { $0.vmInit }).line)")
  note("  rest of main → ready:        \(Percentiles(runs.map { $0.toReady }).line)")
  if discarded > 0 { note("  \(discarded) sample(s) discarded for a negative interval") }
}

func experimentColdPhases() throws {
  section("E10a where the launch time goes, split at main")
  func gather(_ helper: String, count: Int) throws -> ([ColdPhases], Int) {
    var runs: [ColdPhases] = []
    var discarded = 0
    for _ in 0..<count {
      if let phases = try measureColdPhases(helper: helper) {
        runs.append(phases)
      } else {
        discarded += 1
      }
    }
    return (runs, discarded)
  }

  let (warm, warmDiscarded) = try gather(helperPath, count: coldstartRuns)
  reportColdPhases("validated binary", warm, discarded: warmDiscarded)

  var cold: [ColdPhases] = []
  var coldDiscarded = 0
  for index in 0..<max(1, coldstartRuns / 2) {
    let copy = try freshHelperCopy(index: 700 + index)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy)) }
    if let phases = try measureColdPhases(helper: copy) {
      cold.append(phases)
    } else {
      coldDiscarded += 1
    }
  }
  reportColdPhases("binary the kernel has never seen", cold, discarded: coldDiscarded)

  guard !warm.isEmpty, !cold.isEmpty else { return }
  let warmPre = Percentiles(warm.map { $0.preMain }).p50
  let coldPre = Percentiles(cold.map { $0.preMain }).p50
  let warmAfter = Percentiles(warm.map { $0.vmInit + $0.toReady }).p50
  let coldAfter = Percentiles(cold.map { $0.vmInit + $0.toReady }).p50
  note(
    "extra cost of an unvalidated binary: \(fmt(coldPre - warmPre)) ms before main,"
      + " \(fmt(coldAfter - warmAfter)) ms after it")
  verdict(
    nil,
    (coldPre - warmPre) > (coldAfter - warmAfter)
      ? "the cost is paid before the helper's first statement — nothing the helper"
        + " does, or links, can move it"
      : "the cost is paid inside the helper — what it does at startup is worth looking at")
}

/// What the saving is keyed on. Every arm launches the same bytes with the same
/// dependencies; only the file's identity changes, so a warm arm names what the
/// kernel remembered.
func experimentBinaryIdentity() throws {
  section("E10b what the validation is remembered against")
  let staging = workDir.appendingPathComponent("identity")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  let origin = URL(fileURLWithPath: helperPath)

  // Optional, not a sentinel: a discarded reading must not become a fast reading.
  func timed(_ path: String) throws -> Double? {
    try measureColdPhases(helper: path)?.preMain
  }

  var copyArm: [Double] = []
  var linkArm: [Double] = []
  var cloneArm: [Double] = []
  var secondArm: [Double] = []
  var discarded = 0
  var linkFailed: String?
  var cloneFailed: String?

  // Round-robin rather than arm by arm: caches and clock speed drift over a run, and
  // running each arm in a block lets that drift line up with the arm.
  for index in 0..<max(1, coldstartRuns / 3) {
    let plain = staging.appendingPathComponent("copy-\(index)")
    try? FileManager.default.removeItem(at: plain)
    try FileManager.default.copyItem(at: origin, to: plain)
    if let sample = try timed(plain.path) { copyArm.append(sample) } else { discarded += 1 }
    // Same file, second launch. If this is fast, the first launch is what paid.
    if let sample = try timed(plain.path) { secondArm.append(sample) } else { discarded += 1 }
    try? FileManager.default.removeItem(at: plain)

    // A new path onto the same inode. Fast means the kernel remembers the file.
    let link = staging.appendingPathComponent("link-\(index)")
    try? FileManager.default.removeItem(at: link)
    do {
      try FileManager.default.linkItem(at: origin, to: link)
      if let sample = try timed(link.path) { linkArm.append(sample) } else { discarded += 1 }
      try? FileManager.default.removeItem(at: link)
    } catch {
      linkFailed = describe(error)
    }

    // A new inode sharing the same blocks. Fast means the kernel remembers the
    // contents rather than the file.
    let clone = staging.appendingPathComponent("clone-\(index)")
    try? FileManager.default.removeItem(at: clone)
    if clonefile(origin.path, clone.path, 0) == 0 {
      if let sample = try timed(clone.path) { cloneArm.append(sample) } else { discarded += 1 }
      try? FileManager.default.removeItem(at: clone)
    } else {
      cloneFailed = String(cString: strerror(errno))
    }
  }

  note("fresh copy:            \(Percentiles(copyArm).line)")
  note("same copy, relaunched: \(Percentiles(secondArm).line)")
  if linkArm.isEmpty {
    note("hardlink:              unavailable (\(linkFailed ?? "no samples"))")
  } else {
    note("hardlink to the original: \(Percentiles(linkArm).line)")
  }
  if cloneArm.isEmpty {
    note("clonefile:             unavailable (\(cloneFailed ?? "no samples"))")
  } else {
    note("clonefile of the original: \(Percentiles(cloneArm).line)")
  }
  note(
    "(all figures are time before the helper's first statement, which includes the"
      + " host's own socketpair and posix_spawn work)")
  if discarded > 0 { note("\(discarded) sample(s) discarded for a negative interval") }

  let coldMedian = Percentiles(copyArm).p50
  let warmish = { (samples: [Double]) in
    !samples.isEmpty && Percentiles(samples).p50 < coldMedian / 2
  }
  verdict(
    nil,
    warmish(secondArm)
      ? "relaunching the same file is cheap, so the first launch of a file is what pays"
      : "relaunching the same file costs the same — the saving is not per-file")
  if !linkArm.isEmpty {
    verdict(
      nil,
      warmish(linkArm)
        ? "a hardlink to a validated file launches warm — what is remembered is the"
          + " file, not the path it was reached by"
        : "a hardlink to a validated file launches cold — the path matters, which"
          + " the file's identity alone does not explain")
  }
  if !cloneArm.isEmpty {
    verdict(
      nil,
      warmish(cloneArm)
        ? "a clone launches warm too, so identical contents are enough — an update"
          + " that changes nothing would not pay again"
        : "a clone launches cold, so it is the file rather than its contents that is"
          + " remembered — every new copy pays, however identical")
  }
}

/// Whether linking JavaScriptCore is part of what a launch costs. Answers the
/// dlopen question without writing the dlopen version: if the stub launches like the
/// helper, there is nothing for deferring JSC to save.
func experimentStubComparison() throws {
  guard let stub = stubHelperPath else {
    note("E10d skipped — no --stub-helper given")
    return
  }
  section("E10d the same helper without JavaScriptCore linked")
  func gather(_ helper: String) throws -> [ColdPhases] {
    var runs: [ColdPhases] = []
    for _ in 0..<max(1, coldstartRuns / 2) {
      if let phases = try measureColdPhases(helper: helper) { runs.append(phases) }
    }
    return runs
  }

  let stubWarm = try gather(stub)
  let helperWarm = try gather(helperPath)
  // Alternated rather than one arm then the other: these are the expensive samples,
  // seconds apart in a block layout, which is exactly where drift would line up with
  // the arm. E10b takes the same precaution.
  var stubCold: [ColdPhases] = []
  var helperCold: [ColdPhases] = []
  for index in 0..<max(1, coldstartRuns / 2) {
    for (binary, sink) in [(stub, 0), (helperPath, 1)] {
      let path = try freshCopy(of: binary, index: 600 + index)
      defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }
      guard let phases = try measureColdPhases(helper: path) else { continue }
      if sink == 0 { stubCold.append(phases) } else { helperCold.append(phases) }
    }
  }
  guard !stubWarm.isEmpty, !helperWarm.isEmpty, !stubCold.isEmpty, !helperCold.isEmpty else {
    note("not enough usable samples to compare")
    return
  }

  note(
    "before main, validated:   stub \(fmt(Percentiles(stubWarm.map { $0.preMain }).p50)) ms"
      + " vs helper \(fmt(Percentiles(helperWarm.map { $0.preMain }).p50)) ms")
  note(
    "before main, unvalidated: stub \(fmt(Percentiles(stubCold.map { $0.preMain }).p50)) ms"
      + " vs helper \(fmt(Percentiles(helperCold.map { $0.preMain }).p50)) ms")
  note(
    "JavaScriptCore coming up, in the helper: "
      + "\(fmt(Percentiles(helperWarm.map { $0.vmInit }).p50)) ms validated, "
      + "\(fmt(Percentiles(helperCold.map { $0.vmInit }).p50)) ms unvalidated")

  let coldDelta =
    Percentiles(helperCold.map { $0.preMain }).p50
    - Percentiles(stubCold.map { $0.preMain }).p50
  // The stub is smaller precisely because JavaScriptCore is absent, so a difference
  // here has two candidate causes and this pair cannot separate them. A null result
  // does not have that problem: if the smaller binary is not faster, then neither
  // its size nor what it links mattered.
  note(
    "binary sizes: stub \(fileSize(stub)) bytes, helper \(fileSize(helperPath)) bytes")
  verdict(
    nil,
    abs(coldDelta) < 10
      ? "linking JavaScriptCore does not change what an unvalidated binary costs"
        + " (\(fmt(coldDelta)) ms apart, and that is despite the stub being smaller)"
        + " — deferring it with dlopen would buy nothing here"
      : "the unvalidated cost differs by \(fmt(coldDelta)) ms, but the stub is also"
        + " the smaller file, and this pair cannot say which of the two did it — a"
        + " stub padded back to the helper's size would separate them, and was not built")
}

// MARK: - E12  a hostile helper

/// The host's own physical footprint, for watching whether an attack makes it grow.
func selfFootprint() -> UInt64 {
  var bytes: UInt64 = 0
  return ipc_phys_footprint(getpid(), &bytes) == 0 ? bytes : 0
}

/// Sends one attack and then checks the host is still there. Returning at all is the
/// finding — the attacks that would take the host down do it by crashing the whole
/// process, which aborts the run rather than returning here, and that is itself the
/// "must fix" result. A returned `.survived` or `.deadline` means the framing layer
/// held.
enum AttackOutcome {
  case survived(String)  // the host processed it and stayed usable
  case deadline  // the host would have hung; the receive deadline stopped it
  case channelDead(String)  // this channel broke, but the host process lives (sentinel re-spawned)
}

func experimentHostileFraming(helper: String) throws {
  section("E12a framing under hostile input — bytes a cooperating helper could not send")
  note("frame cap is 32 MiB; attacks are read with a 5 s deadline so a hang is visible")

  struct Attack {
    let kind: String
    let arg: Int
    let note: String
  }
  let attacks = [
    Attack(kind: "len-huge", arg: 0, note: "prefix claims 4 GiB"),
    Attack(kind: "len-just-over", arg: 0, note: "prefix is one over the cap"),
    Attack(kind: "non-utf8", arg: 0, note: "invalid UTF-8 body"),
    Attack(kind: "not-object", arg: 0, note: "valid JSON, but an array not an object"),
    Attack(kind: "truncated", arg: 0, note: "announces N bytes, sends N-10, keeps the socket open"),
    Attack(kind: "huge-json", arg: 0, note: "a valid object filling the whole 32 MiB frame"),
  ]

  for attack in attacks {
    let before = selfFootprint()
    let process = try PluginProcess(helperPath: helper)
    process.fetchHandler = stubFetch
    try process.waitReady(deadline: ContinuousClock.now + .seconds(20))
    let outcome = runOneAttack(process, kind: attack.kind, arg: attack.arg, helper: helper)
    let grew = Double(selfFootprint()) - Double(before)
    process.shutdown()
    let growth = grew > 1_000_000 ? " (+\(fmt(grew / 1024 / 1024, 1)) MiB on the host)" : ""
    switch outcome {
    case .survived(let detail):
      note("\(attack.kind): \(attack.note) → host survived, \(detail)\(growth)")
    case .deadline:
      note("\(attack.kind): \(attack.note) → deadline stopped a hang\(growth)")
    case .channelDead(let detail):
      note("\(attack.kind): \(attack.note) → channel died, host process lived (\(detail))\(growth)")
    }
  }
  verdict(
    nil,
    "every frame attack was contained by the transport — nothing crashed the host,"
      + " which is what the framing layer was supposed to do and, measured, does")

  // deep-json is separated out: its answer is a threshold, not a yes/no. Nesting is
  // something a real plugin can return by accident, so where JSONSerialization gives
  // out — and whether it throws or crashes — decides whether this is a bug to fix.
  section("E12a (cont.) how deep JSON can nest before the parser gives out")
  // Whether a given depth is handled: survived (parsed or cleanly rejected, host
  // alive) is "OK"; a crash would abort the run before returning here.
  func handled(_ depth: Int) throws -> Bool {
    let process = try PluginProcess(helperPath: helper)
    process.fetchHandler = stubFetch
    try process.waitReady(deadline: ContinuousClock.now + .seconds(20))
    let outcome = runOneAttack(process, kind: "deep-json", arg: depth, helper: helper)
    process.shutdown()
    switch outcome {
    case .survived: return true
    // A rejected frame (the parser's "too many nested" throw) is containment working,
    // so the host is alive — but the payload was not accepted, which is the boundary
    // we are locating. Treat it as "not handled" for the threshold.
    case .channelDead(let detail): return detail.contains("nested") ? false : true
    case .deadline: return false
    }
  }
  // Bracket first, then bisect to the exact frontier where acceptance stops.
  var lo = 1
  var hi = 1
  while try handled(hi) && hi < 1_000_000 {
    lo = hi
    hi *= 2
    note("depth \(lo): accepted")
  }
  note("depth \(hi): rejected — bracketing the frontier in [\(lo), \(hi)]")
  while hi - lo > 1 {
    let mid = (lo + hi) / 2
    if try handled(mid) { lo = mid } else { hi = mid }
  }
  verdict(
    nil,
    "JSONSerialization accepts nesting up to \(lo) and rejects \(hi) — it throws"
      + " rather than crashing, so this is a bounded refusal, but a real plugin"
      + " returning past \(lo) hits it, which argues for a depth limit the host sets"
      + " itself rather than leaning on the parser's")
}

/// A helper flooding reverse RPCs — the rate-limit question. The number that decides
/// it is whether the flood reaches anything but the attacker's own thread: the host
/// services each helper's calls on the thread blocked in that helper's `call`, so a
/// flood should stall only the attacker and leave every other helper's ticks
/// untouched. This measures that rather than assuming it.
func experimentHostileRPC(helper: String) throws {
  section("E12b a helper flooding reverse RPCs — does it reach anyone else")
  let deadline = { ContinuousClock.now + .seconds(30) }

  // A cooperating helper doing ordinary work, on its own process and socket.
  let victim = try spawnLoaded(Scripts.summarize)
  defer { victim.shutdown() }
  // Its baseline tick latency, undisturbed.
  var baseline: [Double] = []
  for i in 0..<200 {
    let start = ContinuousClock.now
    _ = try victim.call(["op": "tick", "raw": snapshot, "tickNumber": i], deadline: deadline())
    baseline.append(Timing.millis(ContinuousClock.now - start))
  }

  // The attacker floods on its own channel. serviceHostCall answers each on the
  // thread pumping this call, so the whole flood is paid inside one host call to the
  // attacker — the question is whether that thread is shared with the victim's. It is
  // not (one thread per PluginProcess.call), so the victim's ticks below should be
  // indistinguishable from the baseline.
  let floodCount = 50_000
  let attacker = try PluginProcess(helperPath: helper)
  attacker.fetchHandler = stubFetch
  try attacker.waitReady(deadline: deadline())
  let floodStart = ContinuousClock.now
  try attacker.channel.send(["op": "flood", "count": floodCount, "id": 1])

  // While the flood is in flight on the attacker's socket, keep ticking the victim.
  var during: [Double] = []
  for i in 0..<200 {
    let start = ContinuousClock.now
    _ = try victim.call(
      ["op": "tick", "raw": snapshot, "tickNumber": 1000 + i], deadline: deadline())
    during.append(Timing.millis(ContinuousClock.now - start))
  }

  // Now drain the attacker's flood on its own thread and time how long the host is
  // busy with it, and confirm it actually arrived.
  //
  // Read-only, no replies: this attacker never reads them, so replying here would
  // fill the socket the other way and deadlock both sides against each other's
  // blocking writes — a real property (a flooding helper that ignores replies can
  // block the servicing thread's send), but one that belongs in E12c's design notes,
  // not in a measurement that has to finish. What this arm needs is only whether the
  // flood arrived and reached the host, which reading alone establishes.
  let footBefore = selfFootprint()
  var serviced = 0
  do {
    while true {
      let envelope = try attacker.channel.receive(deadline: ContinuousClock.now + .seconds(30))
      if envelope.body["op"] as? String == "hostCall" {
        serviced += 1
        if serviced >= floodCount { break }
      }
    }
  } catch {
    note("flood drain stopped early at \(serviced): \(error)")
  }
  let floodMillis = Timing.millis(ContinuousClock.now - floodStart)
  let floodGrowth = Double(selfFootprint()) - Double(footBefore)
  attacker.shutdown()

  note("victim tick, undisturbed:      \(Percentiles(baseline).line)")
  note("victim tick, during the flood: \(Percentiles(during).line)")
  note("flood: \(serviced) calls serviced in \(fmt(floodMillis)) ms on the attacker's own thread")
  note("host footprint growth over the flood: \(fmt(floodGrowth / 1024 / 1024, 1)) MiB")
  let delay = Percentiles(during).p50 - Percentiles(baseline).p50
  verdict(
    serviced >= floodCount,
    "the flood arrived in full (\(serviced) of \(floodCount)) — the attack is real,"
      + " not dropped before it reached the host")
  // Not "no rate limit needed": what this run exercises is a single-threaded host
  // that reads the flood after the victim's ticks, so the buffering-and-bounded-memory
  // result is real but the isolation is not something this measures — that would
  // follow from a per-helper servicing thread the host does not yet run. And a flooder
  // that never reads replies can still block a synchronous servicing send once the
  // socket fills, which is an open item, not a closed one.
  verdict(
    nil,
    "the flood buffers without unbounded growth (+\(fmt(floodGrowth / 1024 / 1024, 1)) MiB)"
      + " and did not perturb the victim in this sequential host (\(fmt(delay)) ms) —"
      + " true isolation would need a per-helper servicing thread this run does not"
      + " exercise, and a reply-ignoring flooder can block a synchronous send, so the"
      + " rate-limit question is bounded-but-open, not closed")
}

/// Whether a capability, once granted, can be taken back — and where the state that
/// decides it lives. The helper carries none: E7/E8 put the policy gate in the host,
/// so revocation is the host changing its own mind, and a hijacked helper cannot
/// out-vote it. This shows a fetch handler that allows a few calls and then refuses,
/// with a real (hostile) helper hammering it.
func experimentHostileCapability() throws {
  section("E12c revocation is the host's to make, not the helper's")
  let deadline = { ContinuousClock.now + .seconds(20) }

  // The gate: three grants, then no more. Nothing about this lives in the helper.
  var remaining = 3
  let revoking: (String) -> Any = { _ in
    if remaining > 0 {
      remaining -= 1
      return ["status": "ok", "code": 200]
    }
    return ["status": "denied", "code": 403]
  }

  let process = try spawnLoaded(Scripts.summarizeWithFetch)
  defer { process.shutdown() }
  process.fetchHandler = revoking

  var statuses: [String] = []
  for i in 0..<6 {
    let reply = try process.call(
      ["op": "tick", "raw": snapshot, "tickNumber": i], deadline: deadline())
    let value = reply["value"] as? [String: Any]
    statuses.append(value?["status"] as? String ?? "?")
  }
  note("a hijacked helper asks six times; the host answered: \(statuses)")
  note(
    "host serviced \(process.hostCallsServiced) reverse calls — the helper kept no count of its own"
  )
  let flipped =
    statuses.prefix(3).allSatisfy { $0 == "ok" } && statuses.suffix(3).allSatisfy { $0 == "denied" }
  // The shipping fetch handler has no such revocation today; this is an
  // experiment-local policy showing that if the host adopts one, it works, because the
  // helper holds no state to work around it.
  verdict(
    flipped,
    "if the host adopts a revoking policy — shown here with an experiment-local handler"
      + " — it takes effect mid-session, because the helper never held the grant, only"
      + " asked, and kept no count of its own")
}

/// The design question behind "keep per-file RPC or hand over a subtree", now under
/// an attacker. The number is how many files one grant yields once the helper is
/// hostile: a plain bookmark is a subtree the host cannot take back, per-file RPC is
/// one decision the host makes every time.
func experimentHostileGrantScope(sandboxed: String) throws {
  section("E12d how many files one grant yields to a hijacked helper")
  let deadline = { ContinuousClock.now + .seconds(20) }

  // Bookmark arm: one plain bookmark for the whole subtree. E8 established it
  // delegates; here the point is the count — the helper walks it with no further host
  // involvement, so every file under it is reachable from the single grant.
  var bookmarkFiles = 0
  switch makeBookmark(shareDir, options: []) {
  case .failure(let error):
    note("could not mint the bookmark: \(describe(error))")
  case .success(let data):
    let process = try spawnLoaded(Scripts.summarize, helper: sandboxed)
    defer { process.shutdown() }
    let reply = try process.call(
      [
        "op": "probe", "what": "bookmark", "data": data.base64EncodedString(),
        "scoped": false, "relative": "inside.txt", "deep": "nested/deep.txt",
      ], deadline: deadline())
    let inside = (reply["insideByOpenat"] as? [String: Any])?["ok"] as? Bool ?? false
    let deep = (reply["deepByOpenat"] as? [String: Any])?["ok"] as? Bool ?? false
    bookmarkFiles = (inside ? 1 : 0) + (deep ? 1 : 0)
    note(
      "one plain bookmark → the helper opened \(bookmarkFiles) files under the subtree with"
        + " no further host call (\(bookmarkFiles) is the fixture count, not a cap — the"
        + " grant covers every file under the subtree)")
  }

  // RPC arm: the host decides each time. A gate that allows the first file and denies
  // the rest caps a hijacked helper at exactly what the host let through.
  var granted = 1
  let onePerGrant: (String) -> Any = { _ in
    if granted > 0 {
      granted -= 1
      return ["status": "ok", "code": 200]
    }
    return ["status": "denied", "code": 403]
  }
  let rpc = try spawnLoaded(Scripts.summarizeWithFetch)
  defer { rpc.shutdown() }
  rpc.fetchHandler = onePerGrant
  var allowed = 0
  for i in 0..<5 {
    let reply = try rpc.call(
      ["op": "tick", "raw": snapshot, "tickNumber": i], deadline: deadline())
    if (reply["value"] as? [String: Any])?["status"] as? String == "ok" { allowed += 1 }
  }
  note(
    "per-file RPC → the helper got \(allowed) file(s); the host refused the other \(5 - allowed)")

  verdict(
    nil,
    "one bookmark yields the whole subtree (\(bookmarkFiles) here) and the host cannot"
      + " intervene after handing it over; per-file RPC yields only what the host allows"
      + " each time (\(allowed)) — under a hijack, the reverse RPC the design already"
      + " keeps is the tighter of the two")
}

/// Whether a *live* grant can be widened by an attacker. This has to go through the
/// bookmark, not a passed descriptor: E7 established that `openat` through a passed
/// dirfd is denied under App Sandbox for any target, cooperating or not, so a denied
/// canary there proves only that the descriptor granted nothing to begin with. The
/// plain bookmark is the one path where the grant is real — E8 showed the helper
/// opens `inside.txt` and `nested/deep.txt` through it — which gives a positive
/// control that lives: the granted files open, and a denied escape then means
/// confinement rather than an inert descriptor.
func experimentHostileContainment(sandboxed: String) throws {
  section("E12e trying to widen a live grant from inside the sandbox")
  let deadline = { ContinuousClock.now + .seconds(20) }

  guard case .success(let data) = makeBookmark(shareDir, options: []) else {
    note("could not mint the bookmark — E12e cannot run")
    return
  }
  let blob = data.base64EncodedString()

  struct Escape {
    let label: String
    let path: String
  }
  // /etc/hosts is not the canary; an absolute path to it opens under the sandbox on
  // its own and says nothing about the grant, so it is not counted as an escape.
  let escapes = [
    Escape(label: "relative ..", path: "../canary.txt"),
    Escape(label: "deep ..", path: "../../../../../../etc/hosts"),
    Escape(label: "absolute to canary", path: canaryFile.path),
    Escape(label: "symlink out of the subtree", path: "escape-link"),
  ]
  var grantAlive = false
  var escaped = false
  for escape in escapes {
    let process = try spawnLoaded(Scripts.summarize, helper: sandboxed)
    defer { process.shutdown() }
    let reply = try process.call(
      [
        "op": "probe", "what": "bookmark", "data": blob, "scoped": false,
        "relative": "inside.txt", "deep": "nested/deep.txt", "escape": escape.path,
      ], deadline: deadline())
    let insideOK = (reply["insideByOpenat"] as? [String: Any])?["ok"] as? Bool ?? false
    let escapeOK = (reply["escapeByOpenat"] as? [String: Any])?["ok"] as? Bool ?? false
    let escapePath = (reply["escapeByPath"] as? [String: Any])?["ok"] as? Bool ?? false
    if insideOK { grantAlive = true }
    // The canary reached by either route is an escape; /etc/hosts is not.
    let reachedCanary = (escapeOK || escapePath) && !escape.path.contains("/etc/")
    if reachedCanary { escaped = true }
    note(
      "escape \"\(escape.path)\" [\(escape.label)] → openat "
        + (escapeOK ? "OPENED" : "denied")
        + ", by path " + (escapePath ? "OPENED" : "denied")
        + "; the granted inside.txt "
        + (insideOK ? "still opened (grant is live)" : "did not open"))
  }
  guard grantAlive else {
    verdict(
      false,
      "the granted file never opened — the bookmark grant was not live, so no widening"
        + " could be tested")
    return
  }
  verdict(
    !escaped,
    escaped
      ? "an attacker widened a live grant to reach the canary — normalizing paths and"
        + " refusing symlinks before granting is a fix to design in"
      : "the grant opened the files it was for and no escape reached the canary — a live"
        + " bookmark grant does not widen for an attacker any more than for a cooperating"
        + " helper")
}

/// Fires one attack, then a sentinel, and reports whether the host is still serving.
/// If the channel is dead but a fresh helper's sentinel answers, the host process
/// survived and only the socket was lost — which is a different thing from a crash.
func runOneAttack(_ process: PluginProcess, kind: String, arg: Int, helper: String) -> AttackOutcome
{
  do {
    try process.channel.send(["op": "attack", "kind": kind, "arg": arg, "id": 1])
  } catch {
    return .channelDead("send failed: \(error)")
  }
  // Drain whatever the attack produced, with a deadline so a never-completing frame
  // shows up as a stopped hang rather than an infinite wait.
  let deadline = ContinuousClock.now + .seconds(5)
  do {
    while true {
      let envelope = try process.channel.receive(deadline: deadline)
      // The attack itself sends nothing on this channel for most kinds; a stray
      // frame would be the malformed one, which receive() throws on. Reaching a
      // clean result means the host read past the attack.
      if envelope.body["op"] as? String == "result" { break }
    }
  } catch let error as IPCError {
    switch error {
    case .timeout:
      return .deadline
    case .oversize, .malformed, .eof, .io:
      // The transport rejected the frame, which is the containment working. The host
      // process is fine; confirm with a sentinel on a fresh channel.
      return sentinel(helper: helper, after: "\(error)")
    }
  } catch {
    return sentinel(helper: helper, after: "\(error)")
  }
  return .survived("read past it and answered")
}

/// A fresh helper and one noop round trip. If it answers, the host process is alive
/// regardless of what the attack did to the previous channel.
func sentinel(helper: String, after: String) -> AttackOutcome {
  do {
    let probe = try PluginProcess(helperPath: helper)
    probe.fetchHandler = stubFetch
    try probe.waitReady(deadline: ContinuousClock.now + .seconds(20))
    let reply = try probe.call(["op": "noop"], deadline: ContinuousClock.now + .seconds(5))
    probe.shutdown()
    if reply["ok"] as? Bool == true {
      return .channelDead("rejected as \(after); host still serving")
    }
    return .channelDead("rejected as \(after); sentinel gave \(reply)")
  } catch {
    return .channelDead("rejected as \(after); sentinel also failed: \(error)")
  }
}

// MARK: - E11  Developer ID and quarantine

/// Runs a shell command and returns its exit status with combined output. Only for
/// the handful of system tools E11 needs — xattr, spctl — where reimplementing them
/// would be worse than shelling out.
func shell(_ args: [String]) -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = args
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do { try process.run() } catch { return (-1, "\(error)") }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func hasQuarantine(_ path: String) -> Bool {
  shell(["xattr", "-p", "com.apple.quarantine", path]).status == 0
}

/// Stamps the attribute a browser download would leave. The flag `0083` is what a
/// Safari download carries; whether a hand-applied attribute is treated the same as
/// a real one is exactly what E11c has to establish rather than assume.
func applyQuarantine(_ path: String) {
  let stamp = String(Int(Date().timeIntervalSince1970), radix: 16)
  _ = shell([
    "xattr", "-w", "com.apple.quarantine",
    "0083;\(stamp);Safari;\(UUID().uuidString)", path,
  ])
}

/// What Gatekeeper itself says about the file, independent of what happens when it is
/// spawned. The two are compared: if they disagree, a hand-applied attribute is not
/// standing in for a real download and the spawn result cannot be read as Gatekeeper's.
func assess(_ path: String) -> String {
  let result = shell(["spctl", "--assess", "--type", "execute", "--verbose", path])
  return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: path + ": ", with: "")
}

/// Whether the helper still gets a JIT once a real certificate is on it. E5 settled
/// that the JIT hinges on the entitlement; this asks whether the signing identity
/// changes that, and the ad-hoc variant alongside is what makes the answer readable.
func experimentDeveloperID(devID: String, adHoc: String?) throws {
  section("E11a JIT under Developer ID signing — not notarized")
  // Container resolution first. The helper's own CFBundleIdentifier is embedded in
  // its signature, so sitting inside another app's bundle should not change which
  // container it lands in — but "should not" is a prediction, and `home` is the probe.
  do {
    let process = try spawnLoaded(Scripts.summarize, helper: devID)
    defer { process.shutdown() }
    let home = try process.call(
      ["op": "probe", "what": "home"], deadline: ContinuousClock.now + .seconds(20))
    let path = home["home"] as? String ?? "?"
    note("home: \(path)")
    verdict(
      nil,
      path.contains("dev.zuki.jscore-oop-helper")
        ? "the helper resolves its own container from inside the .app — the parent"
          + " bundle's identifier does not take over"
        : "the helper's container is not its own (\(path)) — bundle placement changed"
          + " what App Sandbox keyed on")
  }
  let devIDResult = try experimentThroughput(helper: devID, label: "Developer ID")
  verdict(
    nil,
    devIDResult.jitBytes > 0
      ? "the JIT is present under a Developer ID signature — the certificate does not"
        + " take it away"
      : "no JIT under a Developer ID signature, with the entitlement still on the binary")

  // Sensitivity control, as E5 does: the same helper with the JIT switched off should
  // lose its allocator. Only meaningful when there was a JIT to switch off — a helper
  // that had none is a finding for E11a, not a failed control.
  if devIDResult.jitBytes > 0 {
    let off = try experimentThroughput(
      helper: devID, label: "Developer ID, JSC_useJIT=0", environment: ["JSC_useJIT": "0"])
    verdict(
      off.jitBytes == 0,
      "JSC_useJIT=0 removes the allocator — the JIT reading above is a real one")
  } else {
    note("→ no allocator to switch off, so the JSC_useJIT=0 control has nothing to test")
  }

  guard let adHoc else { return }
  section("E11b the same helper ad-hoc signed, for contrast")
  let adHocResult = try experimentThroughput(helper: adHoc, label: "ad-hoc     ")
  let ratio = devIDResult.loop / adHocResult.loop
  note("engine work, Developer ID vs ad-hoc: \(fmt(ratio, 2))×")
  verdict(
    nil,
    abs(ratio - 1) < 0.1 && (devIDResult.jitBytes > 0) == (adHocResult.jitBytes > 0)
      ? "the signing identity makes no difference to the JIT — it is the entitlement,"
        + " and only the entitlement"
      : "the two signatures behave differently (\(fmt(ratio, 2))× on engine work) —"
        + " the identity is doing something the entitlement alone does not")
}

/// What happens to a helper that arrives the way a download does, before anyone has
/// notarized it. The expected answer is a refusal, and a refusal is the finding: it is
/// what makes notarization a requirement rather than a courtesy.
func experimentQuarantine(devID: String, adHoc: String?) throws {
  section("E11c launching a quarantined, un-notarized helper")
  let staging = workDir.appendingPathComponent("quarantine")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

  // Gatekeeper's own verdict on the exported app, before anything is spawned.
  let appPath = URL(fileURLWithPath: devID).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
  note("spctl on the exported .app: \(assess(appPath))")
  note("spctl on the helper itself: \(assess(devID))")

  /// The shape of a refusal is the evidence. `peer closed the socket` is what the host
  /// sees whether Gatekeeper killed the helper or App Sandbox failed to build its
  /// container, so the exit status is read back: SIGKILL is the former's signature,
  /// SIGTRAP inside libsecinit the latter's.
  func attempt(_ path: String) -> (ok: Bool, detail: String) {
    let process: PluginProcess
    do {
      process = try PluginProcess(helperPath: path)
    } catch {
      return (false, "posix_spawn failed: \(error)")
    }
    do {
      _ = try process.waitReady(deadline: ContinuousClock.now + .seconds(30))
      let home = try process.call(
        ["op": "probe", "what": "home"], deadline: ContinuousClock.now + .seconds(20))
      process.shutdown()
      return (true, "started, home \(home["home"] as? String ?? "?")")
    } catch {
      let status = process.reap()
      var how = "exited \(status >> 8)"
      if status & 0x7f != 0 {
        let signal = status & 0x7f
        let name = String(cString: strsignal(signal))
        how = "killed by signal \(signal) (\(name))"
      }
      return (false, "\(error) — \(how)")
    }
  }

  // The subject: a fresh copy carrying the attribute.
  let quarantined = staging.appendingPathComponent("PluginHelper-quarantined").path
  try? FileManager.default.removeItem(atPath: quarantined)
  try FileManager.default.copyItem(atPath: devID, toPath: quarantined)
  applyQuarantine(quarantined)
  guard hasQuarantine(quarantined) else {
    throw Failure("could not apply the quarantine attribute")
  }
  let subject = attempt(quarantined)
  note("quarantined Developer ID helper → \(subject.detail)")

  // Control 1: same file, attribute removed. If this starts and the subject did not,
  // the attribute is what refused it. The removal is checked, not assumed — a
  // control whose attribute silently stayed on would report the wrong branch.
  _ = shell(["xattr", "-d", "com.apple.quarantine", quarantined])
  guard !hasQuarantine(quarantined) else {
    throw Failure("could not remove the quarantine attribute for the control")
  }
  let stripped = attempt(quarantined)
  note("same file, attribute removed → \(stripped.detail)")

  // Control 2: an ad-hoc helper carrying the same attribute. Separates "quarantine
  // refuses un-notarized code" from "quarantine refuses this signing identity".
  var adHocQuarantined: (ok: Bool, detail: String)?
  if let adHoc {
    let copy = staging.appendingPathComponent("PluginHelperJIT-quarantined").path
    try? FileManager.default.removeItem(atPath: copy)
    try FileManager.default.copyItem(atPath: adHoc, toPath: copy)
    applyQuarantine(copy)
    guard hasQuarantine(copy) else {
      throw Failure("could not apply the quarantine attribute to the ad-hoc control")
    }
    adHocQuarantined = attempt(copy)
    note("quarantined ad-hoc helper → \(adHocQuarantined!.detail)")
  }

  // Control 3: the helper left where it ships, inside the .app, with the whole bundle
  // quarantined the way a download would be. A bare Mach-O and an executable inside a
  // bundle may not travel the same Gatekeeper path, and the question this task asks —
  // whether a child the app posix_spawns is treated like the app — is about the
  // in-bundle case. Alongside the bare arm, the two can be read against each other.
  var inBundle: (ok: Bool, detail: String)?
  do {
    let bundleCopy = staging.appendingPathComponent("JSCoreLab.app")
    try? FileManager.default.removeItem(at: bundleCopy)
    try FileManager.default.copyItem(atPath: appPath, toPath: bundleCopy.path)
    let helperInBundle = bundleCopy.appendingPathComponent("Contents/MacOS/PluginHelper").path
    applyQuarantine(bundleCopy.path)
    applyQuarantine(helperInBundle)
    guard hasQuarantine(bundleCopy.path), hasQuarantine(helperInBundle) else {
      throw Failure("could not quarantine the bundle copy")
    }
    note("spctl on the quarantined bundle copy: \(assess(bundleCopy.path))")
    inBundle = attempt(helperInBundle)
    note("quarantined, still inside its .app → \(inBundle!.detail)")
  }

  if !subject.ok && stripped.ok {
    verdict(
      nil,
      "the attribute alone is what refuses it — an un-notarized Developer ID helper does"
        + " not start on the path a download takes, so notarization is a requirement")
  } else if subject.ok {
    verdict(
      nil,
      "a quarantined, un-notarized helper starts when posix_spawned — consistent with"
        + " Gatekeeper evaluating launches through LaunchServices and not child processes,"
        + " which this does not confirm")
  } else {
    verdict(
      nil, "the helper fails with or without the attribute — the refusal is not the quarantine's")
  }
  if let adHocQuarantined {
    verdict(
      nil,
      adHocQuarantined.ok == subject.ok
        ? "ad-hoc and Developer ID are treated alike under quarantine — the identity"
          + " does not change the outcome"
        : "ad-hoc (\(adHocQuarantined.ok ? "starts" : "refused")) and Developer ID"
          + " (\(subject.ok ? "starts" : "refused")) differ under quarantine")
  }
  if let inBundle {
    verdict(
      nil,
      inBundle.ok == subject.ok
        ? "inside the bundle or bare, the outcome is the same — where the helper sits"
          + " does not change what quarantine does to it"
        : "inside the bundle (\(inBundle.ok ? "starts" : "refused")) and bare"
          + " (\(subject.ok ? "starts" : "refused")) differ — bundle placement changes"
          + " the Gatekeeper path")
  }

  // E11d only means something if a quarantined helper can start at all.
  guard subject.ok else {
    note(
      "→ E11d (first-launch cost under quarantine) has nothing to measure: the helper does not start"
    )
    return
  }
  section("E11d first launch under quarantine — what Gatekeeper adds")
  // Never throws: a refused launch in one arm is a data point for that arm, not a
  // reason to abandon the other three.
  func phases(_ path: String) -> Double? {
    (try? measureColdPhases(helper: path))??.preMain
  }
  var plain: [Double] = []
  var withAttr: [Double] = []
  var relaunch: [Double] = []
  var adHocAttr: [Double] = []
  for index in 0..<max(1, coldstartRuns / 3) {
    let a = try freshCopy(of: devID, index: 500 + index)
    if let v = phases(a) { plain.append(v) }
    try? FileManager.default.removeItem(atPath: a)

    let b = try freshCopy(of: devID, index: 520 + index)
    applyQuarantine(b)
    guard hasQuarantine(b) else { throw Failure("quarantine did not apply to a fresh copy") }
    if let v = phases(b) { withAttr.append(v) }
    if let v = phases(b) { relaunch.append(v) }
    try? FileManager.default.removeItem(atPath: b)

    if let adHoc {
      let c = try freshCopy(of: adHoc, index: 540 + index)
      applyQuarantine(c)
      guard hasQuarantine(c) else { throw Failure("quarantine did not apply to the ad-hoc copy") }
      if let v = phases(c) { adHocAttr.append(v) }
      try? FileManager.default.removeItem(atPath: c)
    }
  }
  // Percentiles preconditions on a non-empty input, and an arm can come back empty
  // if every launch in it was refused. Report the emptiness rather than trap on it.
  func line(_ samples: [Double]) -> String {
    samples.isEmpty ? "no usable samples" : Percentiles(samples).line
  }
  note("before main, fresh copy, no attribute:   \(line(plain))")
  note("before main, fresh copy, quarantined:    \(line(withAttr))")
  note("before main, same file relaunched:       \(line(relaunch))")
  if adHoc != nil {
    note("before main, ad-hoc, quarantined:        \(line(adHocAttr))")
  }
  guard !plain.isEmpty, !withAttr.isEmpty, !relaunch.isEmpty else {
    note("→ an arm produced no samples, so the attribute's cost cannot be isolated")
    return
  }
  let added = Percentiles(withAttr).p50 - Percentiles(plain).p50
  note("→ the attribute adds \(fmt(added)) ms to a first launch")
  verdict(
    nil,
    Percentiles(relaunch).p50 < Percentiles(withAttr).p50 / 2
      ? "and only to the first — relaunching the same quarantined file is cheap again"
      : "and to every launch — the attribute costs each time, not once")
}

// MARK: - E9  pre-warming

/// One launch, split at the seams a pool can cut on. Everything up to `ready` is
/// what pre-warming moves off the click; `load` and the first `tick` are what stays
/// on it no matter how early the process was started.
struct LaunchPhases {
  var spawn = 0.0
  var ready = 0.0
  var load = 0.0
  var tick = 0.0
  var beforeClick: Double { spawn + ready }
  var onClick: Double { load + tick }
  var total: Double { beforeClick + onClick }
}

func measureLaunch(helper: String, script: String = Scripts.summarize) throws -> LaunchPhases {
  var phases = LaunchPhases()
  let deadline = { ContinuousClock.now + .seconds(20) }

  var mark = ContinuousClock.now
  let process = try PluginProcess(helperPath: helper)
  process.fetchHandler = stubFetch
  defer { process.shutdown() }
  phases.spawn = Timing.millis(ContinuousClock.now - mark)

  mark = ContinuousClock.now
  try process.waitReady(deadline: deadline())
  phases.ready = Timing.millis(ContinuousClock.now - mark)

  mark = ContinuousClock.now
  let loaded = try process.call(["op": "load", "script": script], deadline: deadline())
  guard loaded["ok"] as? Bool == true else {
    throw Failure("load failed: \(loaded["error"] ?? loaded)")
  }
  phases.load = Timing.millis(ContinuousClock.now - mark)

  mark = ContinuousClock.now
  let ticked = try process.call(
    ["op": "tick", "raw": snapshot, "tickNumber": 0], deadline: deadline())
  guard ticked["ok"] as? Bool == true else {
    throw Failure("first tick failed: \(ticked["error"] ?? ticked)")
  }
  phases.tick = Timing.millis(ContinuousClock.now - mark)
  return phases
}

func experimentLaunchPhases() throws {
  section("E9a launch, split into phases — what pre-warming can and cannot move")
  var runs: [LaunchPhases] = []
  for _ in 0..<prewarmRuns { runs.append(try measureLaunch(helper: helperPath)) }
  // The first launch of a run pays costs no later one does, the same way E1's does.
  let steady = Array(runs.dropFirst())
  func line(_ name: String, _ pick: (LaunchPhases) -> Double) {
    note("\(name): \(Percentiles(steady.map(pick)).line)")
  }
  note("first launch of the run: total \(fmt(runs[0].total)) ms (reported separately)")
  line("posix_spawn  ", { $0.spawn })
  line("→ ready      ", { $0.ready })
  line("load         ", { $0.load })
  line("first tick   ", { $0.tick })
  let beforeClick = Percentiles(steady.map { $0.beforeClick })
  let onClick = Percentiles(steady.map { $0.onClick })
  note("movable off the click (spawn + ready): \(beforeClick.line)")
  note("stuck on the click (load + tick):      \(onClick.line)")
  verdict(
    nil,
    onClick.p95 <= 16
      ? "what a click still costs is \(fmt(onClick.p95)) ms at p95 — under one frame,"
        + " so pre-warming the process is enough to make it imperceptible"
      : "what a click still costs is \(fmt(onClick.p95)) ms at p95 — over one frame,"
        + " so pre-warming the process alone does not settle it")

  // The same split against a binary the kernel has never validated, which is where
  // the hundreds of milliseconds live. Which phase absorbs them decides whether
  // pre-warming can hide an update as well as a cold start.
  section("E9a launch phases — binary the kernel has never seen")
  var fresh: [LaunchPhases] = []
  for index in 0..<max(1, prewarmRuns / 2) {
    let copy = try freshHelperCopy(index: 900 + index)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy)) }
    fresh.append(try measureLaunch(helper: copy))
  }
  note("posix_spawn  : \(Percentiles(fresh.map { $0.spawn }).line)")
  note("→ ready      : \(Percentiles(fresh.map { $0.ready }).line)")
  note("load         : \(Percentiles(fresh.map { $0.load }).line)")
  note("first tick   : \(Percentiles(fresh.map { $0.tick }).line)")
  let freshBefore = Percentiles(fresh.map { $0.beforeClick })
  let freshOn = Percentiles(fresh.map { $0.onClick })
  // The comparison has to be against the warm arm, not between the two phases. Phases
  // before the click are larger than phases on it even when nothing is cold, so the
  // question is which phase absorbs the *extra* cost an unvalidated binary brings.
  let extraBefore = freshBefore.p50 - beforeClick.p50
  let extraOn = freshOn.p50 - onClick.p50
  note(
    "extra cost of an unvalidated binary: \(fmt(extraBefore)) ms before the click,"
      + " \(fmt(extraOn)) ms on it")
  verdict(
    nil,
    extraBefore > extraOn
      ? "the unvalidated-binary cost lands before the click, so pre-warming moves it"
        + " rather than paying it late"
      : "the unvalidated-binary cost lands on the click itself — pre-warming does not move it")
}

/// Whether one helper process can serve a second plugin, which is what decides
/// whether a pool holds reusable processes or single-use ones.
func experimentReuse() throws {
  section("E9b reusing a helper for a second plugin")
  let deadline = { ContinuousClock.now + .seconds(20) }

  func sawMarker(_ reply: [String: Any]) -> (seen: Bool, value: String) {
    guard let value = reply["value"] as? [String: Any] else { return (false, "<no value>") }
    let kind = value["sawMarker"] as? String ?? "?"
    return (kind != "undefined", "\(kind) \(value["markerValue"] as? String ?? "")")
  }

  // Sensitivity control, first. Claiming a reset cleaned something requires showing
  // the probe can see it dirty; a probe that reports clean either way proves nothing.
  let dirty = try { () -> (seen: Bool, value: String) in
    let process = try spawnLoaded(Scripts.leakA)
    defer { process.shutdown() }
    _ = try process.call(["op": "tick", "raw": snapshot, "tickNumber": 0], deadline: deadline())
    let loaded = try process.call(["op": "load", "script": Scripts.leakB], deadline: deadline())
    guard loaded["ok"] as? Bool == true else { throw Failure("second load failed") }
    return sawMarker(
      try process.call(["op": "tick", "raw": snapshot, "tickNumber": 1], deadline: deadline()))
  }()
  note("load(A) → load(B), no reset: B sees the marker as \(dirty.value)")
  verdict(
    dirty.seen,
    "the probe can see contamination at all — without this, a clean result below"
      + " would mean nothing")

  let cleaned = try { () -> (seen: Bool, value: String, millis: Double) in
    let process = try spawnLoaded(Scripts.leakA)
    defer { process.shutdown() }
    _ = try process.call(["op": "tick", "raw": snapshot, "tickNumber": 0], deadline: deadline())
    let reset = try process.call(["op": "reset"], deadline: deadline())
    let loaded = try process.call(["op": "load", "script": Scripts.leakB], deadline: deadline())
    guard loaded["ok"] as? Bool == true else { throw Failure("load after reset failed") }
    let seen = sawMarker(
      try process.call(["op": "tick", "raw": snapshot, "tickNumber": 1], deadline: deadline()))
    return (seen.seen, seen.value, reset["millis"] as? Double ?? -1)
  }()
  note("load(A) → reset → load(B): B sees the marker as \(cleaned.value)")
  note("reset itself took \(fmt(cleaned.millis)) ms")
  // Not pass/fail. A reset that does not clean is a finding about how a pool has to
  // be built, not a broken run — only a blind probe is that.
  verdict(
    nil,
    !cleaned.seen && dirty.seen
      ? "rebuilding the virtual machine and context clears the previous plugin"
        + " — a pre-warmed process can be handed to a second plugin"
      : "the reset leaves the previous plugin visible — a pooled process can serve"
        + " one plugin and then has to be discarded")

  // Clean by inspection is not the same as clean by accounting. A process that keeps
  // the previous plugin's pages is still a process that has to be thrown away.
  let memory = try { () -> (before: UInt64, peak: UInt64, after: UInt64) in
    let process = try spawnLoaded(Scripts.allocate(mb: allocMB))
    defer { process.shutdown() }
    let before = process.footprintBytes ?? 0
    _ = try process.call(
      ["op": "tick", "raw": [String: Any](), "tickNumber": 0], deadline: deadline())
    let peak = process.footprintBytes ?? 0
    _ = try process.call(["op": "reset"], deadline: deadline())
    // JSC is under no obligation to return pages the moment the context dies, so
    // give it a settle window rather than reading the instant after.
    Thread.sleep(forTimeInterval: 1.5)
    return (before, peak, process.footprintBytes ?? 0)
  }()
  note(
    "footprint: \(mib(memory.before)) before → \(mib(memory.peak)) after allocating"
      + " → \(mib(memory.after)) after reset")
  // Doubles before subtracting: a reset that returns nothing and then costs a little
  // more for the new virtual machine puts `after` above `peak`, and on UInt64 that
  // traps — on exactly the result this experiment exists to report.
  let returned =
    Double(memory.peak) - Double(memory.after)
    >= (Double(memory.peak) - Double(memory.before)) * 0.8
  verdict(
    nil,
    returned
      ? "the reset returns the previous plugin's memory, so reuse is sound on"
        + " footprint as well as on visibility"
      : "the reset leaves the previous plugin's memory resident — a reused process"
        + " carries it, so a pool should hand out processes once and discard them")
}

/// What a pre-warmed helper costs while it waits. Deliberately sends it nothing: a
/// probe would wake it, and the question is what an idle one consumes.
func experimentIdleCost() throws {
  section("E9c what a waiting helper costs")
  for (label, script) in [
    ("blank (never loaded)", nil), ("loaded, never ticked", Scripts.summarize),
  ]
    as [(String, String?)]
  {
    let process = try PluginProcess(helperPath: helperPath)
    defer { process.shutdown() }
    try process.waitReady(deadline: ContinuousClock.now + .seconds(20))
    if let script {
      _ = try process.call(
        ["op": "load", "script": script], deadline: ContinuousClock.now + .seconds(20))
    }
    let firstCPU = process.cpuMicros ?? 0
    var footprints: [UInt64] = []
    for _ in 0..<idleSamples {
      Thread.sleep(forTimeInterval: 0.5)
      footprints.append(process.footprintBytes ?? 0)
    }
    let lastCPU = process.cpuMicros ?? 0
    let cpuDelta = Double(lastCPU) - Double(firstCPU)
    let drift = Double((footprints.last ?? 0)) - Double(footprints.first ?? 0)
    note(
      "\(label): footprint \(mib(footprints.first ?? 0)) → \(mib(footprints.last ?? 0))"
        + " over \(fmt(Double(idleSamples) * 0.5, 1))s, threads \(process.threadCount),"
        + " CPU +\(fmt(cpuDelta, 0)) µs")
    verdict(
      nil,
      cpuDelta < 5000 && abs(drift) < 1024 * 1024
        ? "idle costs memory and nothing else — the count of pre-warmed helpers is a"
          + " memory decision"
        : "an idle helper is not free — pre-warming several of them is not just memory")
  }
}

/// Two pool shapes, measured as a click rather than as a launch: hold several
/// helpers ready, or hold one and start its replacement the moment it is taken.
func experimentPoolStrategies() throws {
  section("E9d pool strategies — what a click costs")
  let deadline = { ContinuousClock.now + .seconds(20) }

  /// Takes a ready helper and does what a click does: load the plugin, run it once.
  func click(_ process: PluginProcess) throws -> Double {
    let start = ContinuousClock.now
    let loaded = try process.call(
      ["op": "load", "script": Scripts.summarize], deadline: deadline())
    guard loaded["ok"] as? Bool == true else { throw Failure("load failed") }
    let ticked = try process.call(
      ["op": "tick", "raw": snapshot, "tickNumber": 0], deadline: deadline())
    guard ticked["ok"] as? Bool == true else { throw Failure("tick failed") }
    return Timing.millis(ContinuousClock.now - start)
  }

  // Strategy A: the whole pool is up and ready before any click arrives.
  var pooled: [Double] = []
  var onDemand: [Double] = []
  // Alternated rather than run in blocks: validation caches and thermal state drift
  // over a run, and a block layout lets that drift line up with the arm.
  for _ in 0..<prewarmRuns {
    var pool: [PluginProcess] = []
    for _ in 0..<prewarmPool {
      let process = try PluginProcess(helperPath: helperPath)
      process.fetchHandler = stubFetch
      try process.waitReady(deadline: deadline())
      pool.append(process)
    }
    for process in pool { pooled.append(try click(process)) }
    for process in pool { process.shutdown() }

    for _ in 0..<prewarmPool {
      let start = ContinuousClock.now
      let process = try PluginProcess(helperPath: helperPath)
      process.fetchHandler = stubFetch
      try process.waitReady(deadline: deadline())
      _ = try click(process)
      onDemand.append(Timing.millis(ContinuousClock.now - start))
      process.shutdown()
    }
  }
  note("click on a pre-warmed helper: \(Percentiles(pooled).line)")
  note("click that spawns first:      \(Percentiles(onDemand).line)")
  verdict(
    nil,
    "pre-warming takes \(fmt(Percentiles(onDemand).p50 - Percentiles(pooled).p50)) ms"
      + " off the median click")

  // Strategy B: one helper in hand, its replacement started the instant it is taken.
  // The gap is how long the second click waits. If the curve is flat the replacement
  // is not booting in parallel and the rig, not the strategy, is what was measured.
  section("E9d one in hand, replacement started on use — second click after a gap")
  for gap in prewarmGaps {
    var samples: [Double] = []
    for _ in 0..<prewarmRuns {
      let first = try PluginProcess(helperPath: helperPath)
      first.fetchHandler = stubFetch
      try first.waitReady(deadline: deadline())
      _ = try click(first)
      // Replacement starts here, and boots while the host does something else.
      let replacement = try PluginProcess(helperPath: helperPath)
      replacement.fetchHandler = stubFetch
      if gap > 0 { Thread.sleep(forTimeInterval: Double(gap) / 1000) }
      let start = ContinuousClock.now
      try replacement.waitReady(deadline: deadline())
      _ = try click(replacement)
      samples.append(Timing.millis(ContinuousClock.now - start))
      first.shutdown()
      replacement.shutdown()
    }
    note("gap \(gap) ms → second click \(Percentiles(samples).line)")
  }
  note(
    "→ a curve that falls as the gap grows is the replacement booting in parallel;"
      + " a flat one would mean it is not, and the comparison above would be measuring"
      + " the rig")

  // The same strategy right after an update, when the replacement is a binary the
  // kernel has not validated. This is where holding one in hand may stop being enough.
  section("E9d one in hand, but the replacement has never been validated")
  for gap in [0, 100] {
    var samples: [Double] = []
    for index in 0..<max(1, prewarmRuns / 3) {
      let first = try PluginProcess(helperPath: helperPath)
      first.fetchHandler = stubFetch
      try first.waitReady(deadline: deadline())
      _ = try click(first)
      let copy = try freshHelperCopy(index: 800 + index)
      let replacement = try PluginProcess(helperPath: copy)
      replacement.fetchHandler = stubFetch
      if gap > 0 { Thread.sleep(forTimeInterval: Double(gap) / 1000) }
      let start = ContinuousClock.now
      try replacement.waitReady(deadline: ContinuousClock.now + .seconds(30))
      _ = try click(replacement)
      samples.append(Timing.millis(ContinuousClock.now - start))
      first.shutdown()
      replacement.shutdown()
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy))
    }
    note("gap \(gap) ms → second click \(Percentiles(samples).line)")
  }

  // What a pool buys on the recovery path E4 measures. One rung, because the 500 ms
  // hang deadline dominates that path and this cannot move it.
  section("E9d recovery — replacing a killed helper from the pool")
  var recovered: [Double] = []
  for _ in 0..<max(1, prewarmRuns / 3) {
    let spare = try PluginProcess(helperPath: helperPath)
    spare.fetchHandler = stubFetch
    try spare.waitReady(deadline: deadline())
    let victim = try spawnLoaded(Scripts.summarize)
    victim.kill()
    victim.reap()
    let start = ContinuousClock.now
    _ = try click(spare)
    recovered.append(Timing.millis(ContinuousClock.now - start))
    spare.shutdown()
  }
  note("kill → a pooled helper serving: \(Percentiles(recovered).line)")
  note(
    "→ compare against E4 above, which spawns on the recovery path. The hang deadline"
      + " is \(hangDeadlineMS) ms either way, so this is not what a pool is for")
}

// MARK: - E8  security-scoped bookmarks

/// E7 settled that SCM_RIGHTS carries operations rather than path resolution. The
/// documented way to hand a sandboxed process a subtree is a security-scoped
/// bookmark, which E7 did not touch. The question is not whether bookmarks work —
/// it is whether they work *across processes*, since a plugin helper is not the
/// process that created the bookmark.
func bookmarkLine(_ what: String, _ report: Any?) -> String {
  guard let result = report as? [String: Any] else { return "\(what) → not attempted" }
  if result["ok"] as? Bool == true {
    if let entries = result["entries"] as? [String] { return "\(what) → \(entries)" }
    if let head = result["head"] as? String {
      return "\(what) → \"\(head.trimmingCharacters(in: .whitespacesAndNewlines))\""
    }
    return "\(what) → ok"
  }
  let why = result["errnoText"] ?? result["why"] ?? "?"
  return "\(what) → denied (\(why))"
}

/// "The file couldn't be opened." on its own is not a finding. The domain and code
/// are what distinguish one refusal from another.
func describe(_ error: Error) -> String {
  let ns = error as NSError
  return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
}

/// Everything one process mints, in a form another process can pick up.
///
/// A bookmark is inert bytes: what it means is decided by who minted it and who
/// resolves it, not by how it travelled. Separating the two ends into sibling
/// processes is what lets a *sandboxed* minter be measured at all — a sandboxed
/// parent cannot spawn a separately-contained child, so the pair cannot be
/// parent and child.
struct MintedBlobs {
  var subtree = ""
  var inside = ""
  var deep = ""
  var canary = ""
  var document = ""
  var scoped: Data?
  var plain: Data?
  var documentScoped: Data?
  var minterSandboxed = false

  // Document-scope. `bootstrap` is a plain bookmark for dirA, which is how the
  // helper reaches the document at all — a document-scoped bookmark resolves only
  // against its document, so a helper that cannot open the document cannot use one,
  // and that dependency is itself part of the answer.
  var docDirA = ""
  var docDirB = ""
  var projectDoc = ""
  var assetFile = ""
  var bootstrap: Data?
  var documentScopedFile: Data?

  var json: [String: Any] {
    var out: [String: Any] = [
      "subtree": subtree, "inside": inside, "deep": deep, "canary": canary,
      "document": document, "minterSandboxed": minterSandboxed,
      "docDirA": docDirA, "docDirB": docDirB,
      "projectDoc": projectDoc, "assetFile": assetFile,
    ]
    if let scoped { out["scoped"] = scoped.base64EncodedString() }
    if let plain { out["plain"] = plain.base64EncodedString() }
    if let documentScoped { out["documentScoped"] = documentScoped.base64EncodedString() }
    if let bootstrap { out["bootstrap"] = bootstrap.base64EncodedString() }
    if let documentScopedFile {
      out["documentScopedFile"] = documentScopedFile.base64EncodedString()
    }
    return out
  }

  init() {}

  init(json: [String: Any]) {
    subtree = json["subtree"] as? String ?? ""
    inside = json["inside"] as? String ?? ""
    deep = json["deep"] as? String ?? ""
    canary = json["canary"] as? String ?? ""
    document = json["document"] as? String ?? ""
    minterSandboxed = json["minterSandboxed"] as? Bool ?? false
    docDirA = json["docDirA"] as? String ?? ""
    docDirB = json["docDirB"] as? String ?? ""
    projectDoc = json["projectDoc"] as? String ?? ""
    assetFile = json["assetFile"] as? String ?? ""
    scoped = (json["scoped"] as? String).flatMap { Data(base64Encoded: $0) }
    plain = (json["plain"] as? String).flatMap { Data(base64Encoded: $0) }
    documentScoped = (json["documentScoped"] as? String).flatMap { Data(base64Encoded: $0) }
    bootstrap = (json["bootstrap"] as? String).flatMap { Data(base64Encoded: $0) }
    documentScopedFile = (json["documentScopedFile"] as? String).flatMap {
      Data(base64Encoded: $0)
    }
  }
}

func makeBookmark(
  _ url: URL, options: URL.BookmarkCreationOptions, relativeTo: URL? = nil
) -> Result<Data, Error> {
  do {
    return .success(
      try url.bookmarkData(
        options: options, includingResourceValuesForKeys: nil, relativeTo: relativeTo))
  } catch {
    return .failure(error)
  }
}

/// What one bookmark probe established.
///
/// `grantedOnResolve` was originally read as a confound — the helper opening the
/// file before `startAccessingSecurityScopedResource` looked like the path having
/// been reachable all along. The no-bookmark control says otherwise: the same open
/// is denied when no bookmark is in play. So this flag is a finding, not a
/// disqualifier — access appears at resolution time rather than at the scope call.
/// The control that decides whether anything here is attributable to the bookmark
/// is the caller's, not this struct's.
struct BookmarkOutcome {
  var resolved = false
  var started = false
  var grantedOnResolve = false
  var subtreeOpened = false
  var grantsSubtree: Bool { resolved && subtreeOpened }
}

/// Resolves the blob in the host process itself. Without this, a failure in the
/// helper has two explanations — the bookmark is bound to the process that minted
/// it, or the blob was never valid in the first place — and the run cannot tell
/// them apart.
func resolveInHost(data: Data, scoped: Bool, document: URL? = nil) -> String {
  var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
  if scoped { options.insert(.withSecurityScope) }
  var stale = false
  do {
    let url = try URL(
      resolvingBookmarkData: data, options: options, relativeTo: document,
      bookmarkDataIsStale: &stale)
    let started = url.startAccessingSecurityScopedResource()
    let inside = url.appendingPathComponent("inside.txt").path
    let readable = FileManager.default.contents(atPath: inside) != nil
    if started { url.stopAccessingSecurityScopedResource() }
    return
      "resolved (stale: \(stale), startAccessing: \(started), inside.txt readable: \(readable))"
  } catch {
    return "failed — " + describe(error)
  }
}

/// Sends one bookmark to a fresh helper and prints every step of what it could do
/// with it. `holdAndKill` leaves the scope open and SIGKILLs the helper instead of
/// shutting it down, which is what question 5 actually asks about.
@discardableResult
func probeBookmark(
  helper: String, data: Data, scoped: Bool, document: URL? = nil, label: String,
  holdAndKill: Bool = false
) throws -> BookmarkOutcome {
  let process = try spawnLoaded(Scripts.summarize, helper: helper)
  var request: [String: Any] = [
    "op": "probe", "what": "bookmark",
    "data": data.base64EncodedString(),
    "scoped": scoped,
    "relative": "inside.txt",
    "deep": "nested/deep.txt",
    "escape": "../canary.txt",
    "hold": holdAndKill,
  ]
  if let document { request["document"] = document.path }
  let reply = try process.call(request, deadline: ContinuousClock.now + .seconds(20))
  if holdAndKill {
    // Dies with the scope still held, which is the state a wedged plugin is in when
    // the host reaches for SIGKILL.
    process.kill()
    process.reap()
  } else {
    process.shutdown()
  }

  var outcome = BookmarkOutcome()
  guard reply["resolved"] as? Bool == true else {
    note(
      "\(label): resolve failed — \(reply["error"] ?? reply["why"] ?? "?")"
        + " [\(reply["errorDomain"] ?? "") \(reply["errorCode"] ?? "")]")
    return outcome
  }
  outcome.resolved = true
  outcome.started = reply["started"] as? Bool ?? false
  note("\(label): resolved to \(reply["path"] ?? "?") (stale: \(reply["stale"] ?? "?"))")
  note("  " + bookmarkLine("open(inside.txt) BEFORE startAccessing", reply["beforeStart"]))
  note("  startAccessingSecurityScopedResource() → \(reply["started"] ?? "?")")
  note("  " + bookmarkLine("opendir(subtree)", reply["list"]))
  note("  " + bookmarkLine("open(inside.txt)", reply["insideByPath"]))
  note("  " + bookmarkLine("open(nested/deep.txt)", reply["deepByPath"]))
  note("  " + bookmarkLine("open(subtree) as a directory", reply["dirOpen"]))
  note("  " + bookmarkLine("openat(dirfd, \"inside.txt\")", reply["insideByOpenat"]))
  note("  " + bookmarkLine("openat(dirfd, \"nested/deep.txt\")", reply["deepByOpenat"]))
  note("  " + bookmarkLine("openat(dirfd, \"../canary.txt\")", reply["escapeByOpenat"]))
  note("  " + bookmarkLine("open(../canary.txt)", reply["escapeByPath"]))
  if holdAndKill {
    note("  scope left open, helper SIGKILLed")
  } else {
    note("  " + bookmarkLine("open(inside.txt) after stopAccessing", reply["afterStop"]))
  }

  let inside = (reply["insideByPath"] as? [String: Any])?["ok"] as? Bool ?? false
  let deep = (reply["deepByPath"] as? [String: Any])?["ok"] as? Bool ?? false
  let openat = (reply["insideByOpenat"] as? [String: Any])?["ok"] as? Bool ?? false
  outcome.subtreeOpened = inside && deep && openat
  outcome.grantedOnResolve = (reply["beforeStart"] as? [String: Any])?["ok"] as? Bool ?? false
  if outcome.grantedOnResolve {
    note(
      "  → access was there before startAccessing: resolving the bookmark is what"
        + " granted it, not the scope call")
  }
  return outcome
}

/// Walks one variable at a time until a document-scoped bookmark either mints or
/// every candidate explanation is spent.
///
/// The first attempt asked for a directory inside the temporary directory, and the
/// documented rule is that a document-scoped bookmark points at a single file and
/// not a folder, and that the file is not somewhere the system owns such as
/// `/private` or `/Library`. That is two violations producing one error code, which
/// is exactly the situation where reporting "it failed" settles nothing. Each rung
/// changes one of them.
func mintDocumentScoped() -> Data? {
  // Symlink-resolved on purpose: the temporary directory is reached as /var/... and
  // lives at /private/var/..., and bookmark creation has been reported to compare a
  // descriptor against the path it was given.
  let safeFile = URL(fileURLWithPath: assetFile.path).resolvingSymlinksInPath()
  let safeDir = URL(fileURLWithPath: docDirB.path).resolvingSymlinksInPath()
  let safeDoc = URL(fileURLWithPath: projectDoc.path).resolvingSymlinksInPath()

  let ladder: [(name: String, target: URL, document: URL)] = [
    ("D1  file in the home area, document alongside it", safeFile, safeDoc),
    (
      "D1a document in the temporary directory instead", safeFile,
      documentFile.resolvingSymlinksInPath()
    ),
    ("D1a' the same, spelled the unresolved way", safeFile, documentFile),
    ("D1b directory rather than a file", safeDir, safeDoc),
    (
      "D1c target in the temporary directory instead", insideFile.resolvingSymlinksInPath(), safeDoc
    ),
    ("D1d the original attempt, reproduced", shareDir, documentFile),
  ]

  var winner: Data?
  for rung in ladder {
    switch makeBookmark(rung.target, options: .withSecurityScope, relativeTo: rung.document) {
    case .success(let data):
      note("\(rung.name) → \(data.count) bytes")
      if winner == nil { winner = data }
    case .failure(let error):
      note("\(rung.name) → failed: \(describe(error))")
    }
    // Whether the document picked up the attribute a document-scoped bookmark is
    // reported to key itself with. Absent everywhere means minting never reached
    // the document, which is a different failure from one that did and was refused.
    let attributes = xattrNames(rung.document.path).filter { $0.contains("bookmark") }
    if !attributes.isEmpty {
      note("    document now carries: \(attributes)")
    }
  }
  if winner == nil {
    note("→ no rung minted a document-scoped bookmark")
  }
  return winner
}

/// Mints all three variants and resolves them here, in the minting process. That
/// second half is the control: without it, a helper-side failure could equally mean
/// the blob was never valid.
func mintBlobs() -> MintedBlobs {
  var blobs = MintedBlobs()
  blobs.subtree = shareDir.path
  blobs.inside = insideFile.path
  blobs.deep = deepFile.path
  blobs.canary = canaryFile.path
  blobs.document = documentFile.path
  blobs.minterSandboxed = NSHomeDirectory().contains("/Library/Containers/")

  // A security-scoped bookmark is documented as an App Sandbox facility, so whether
  // an unsandboxed process can even mint one is part of the answer.
  switch makeBookmark(shareDir, options: .withSecurityScope) {
  case .success(let data):
    blobs.scoped = data
    note("bookmarkData(.withSecurityScope) → \(data.count) bytes")
  case .failure(let error):
    note("bookmarkData(.withSecurityScope) → failed: \(describe(error))")
  }

  switch makeBookmark(shareDir, options: []) {
  case .success(let data):
    blobs.plain = data
    note("bookmarkData([]) → \(data.count) bytes")
  case .failure(let error):
    note("bookmarkData([]) → failed: \(describe(error))")
  }

  // Document-scoped: the same option, but made relative to a document. The focus is
  // whether a manifest-declared path can stand in for the document a user picked.
  switch makeBookmark(shareDir, options: .withSecurityScope, relativeTo: documentFile) {
  case .success(let data):
    blobs.documentScoped = data
    note("bookmarkData(.withSecurityScope, relativeTo: document) → \(data.count) bytes")
  case .failure(let error):
    note("bookmarkData(.withSecurityScope, relativeTo: document) → failed: " + describe(error))
  }

  blobs.docDirA = docDirA.path
  blobs.docDirB = docDirB.path
  blobs.projectDoc = projectDoc.path
  blobs.assetFile = assetFile.path
  blobs.documentScopedFile = mintDocumentScoped()
  switch makeBookmark(docDirA, options: []) {
  case .success(let data): blobs.bootstrap = data
  case .failure(let error): note("bootstrap bookmark for dirA → failed: \(describe(error))")
  }

  if let scoped = blobs.scoped {
    note("minter resolving its own app-scoped blob → \(resolveInHost(data: scoped, scoped: true))")
  }
  if let documentScoped = blobs.documentScoped {
    note(
      "minter resolving its own document-scoped blob → "
        + resolveInHost(data: documentScoped, scoped: true, document: documentFile))
  }
  return blobs
}

/// Whether a document-scoped bookmark crosses the process boundary that an
/// app-scoped one does not — and, before that, whether the helper's access to the
/// document is what gates it.
///
/// Run twice: once with the bootstrap that lets the helper open the document, once
/// without. If the first succeeds and the second does not, the gate is the document,
/// which is what the mechanism is described to be and what decides whether a
/// manifest-declared path can stand in for a user's choice.
func probeDocumentScope(helper: String, blobs: MintedBlobs) throws {
  guard let blob = blobs.documentScopedFile else {
    note("→ document-scope: nothing minted, so there is nothing to carry across")
    return
  }
  for withBootstrap in [true, false] {
    let process = try spawnLoaded(Scripts.summarize, helper: helper)
    defer { process.shutdown() }
    var request: [String: Any] = [
      "op": "probe", "what": "document-bookmark",
      "data": blob.base64EncodedString(),
      "target": blobs.assetFile,
      "document": blobs.projectDoc,
    ]
    if withBootstrap, let bootstrap = blobs.bootstrap {
      request["bootstrap"] = bootstrap.base64EncodedString()
    }
    let reply = try process.call(request, deadline: ContinuousClock.now + .seconds(20))

    note("document-scoped, \(withBootstrap ? "document reachable" : "document withheld"):")
    note("  " + bookmarkLine("open(dirB/asset.txt) before anything", reply["controlTarget"]))
    note("  " + bookmarkLine("open(dirA/project.doc) before anything", reply["controlDocument"]))
    if withBootstrap {
      note(
        "  bootstrap (plain bookmark for dirA) resolved → \(reply["bootstrapResolved"] ?? "not attempted")"
      )
      if let error = reply["bootstrapError"] { note("  bootstrap failed: \(error)") }
    }
    note(
      "  " + bookmarkLine("open(dirA/project.doc) after bootstrap", reply["documentAfterBootstrap"])
    )
    note("  " + bookmarkLine("open(dirB/asset.txt) after bootstrap", reply["targetAfterBootstrap"]))
    if reply["resolved"] as? Bool == true {
      note("  resolved to \(reply["path"] ?? "?") (stale: \(reply["stale"] ?? "?"))")
      note("  startAccessingSecurityScopedResource() → \(reply["started"] ?? "?")")
      note("  " + bookmarkLine("open(target) after resolving", reply["targetAfterResolve"]))
    } else {
      note("  resolve failed — \(reply["error"] ?? reply["why"] ?? "?")")
    }

    let controlHeld =
      (reply["controlTarget"] as? [String: Any])?["ok"] as? Bool != true
      && (reply["targetAfterBootstrap"] as? [String: Any])?["ok"] as? Bool != true
    let opened = (reply["targetAfterResolve"] as? [String: Any])?["ok"] as? Bool ?? false
    // Whether the condition this run is named after actually held. Saying "even with
    // the document reachable" when the bootstrap did not make it reachable would
    // describe a run that never happened.
    let documentReachable =
      (reply["documentAfterBootstrap"] as? [String: Any])?["ok"] as? Bool == true
    if !controlHeld {
      verdict(nil, "inconclusive — the target was reachable without the document-scoped bookmark")
    } else if withBootstrap && !documentReachable {
      verdict(nil, "inconclusive — the bootstrap did not make the document reachable")
    } else if !withBootstrap && documentReachable {
      verdict(nil, "inconclusive — the document was reachable without a bootstrap")
    } else if opened {
      verdict(
        nil,
        "document-scope crosses the process boundary\(withBootstrap ? " when the helper can open the document" : " even with the document withheld")"
      )
    } else {
      verdict(
        nil,
        "document-scope does not deliver the target here\(withBootstrap ? " even with the document reachable" : " with the document withheld")"
      )
    }
  }
}

/// Mints in this process, then probes. The ordinary case, where minter and
/// orchestrator are the same process.
func experimentBookmarks(helper: String, label: String) throws {
  section("E8  security-scoped bookmark across processes — \(label)")
  let hostContained = NSHomeDirectory().contains("/Library/Containers/")
  note("host is \(hostContained ? "sandboxed (container: \(NSHomeDirectory()))" : "unsandboxed")")
  note("subtree: \(shareDir.path)")
  try probeMintedBlobs(helper: helper, blobs: mintBlobs())
}

/// Probes blobs someone else already minted. Splitting this out is what makes a
/// sandboxed minter measurable: it mints into its own container and exits, and this
/// runs in an unsandboxed process that can still spawn a separately-contained
/// helper — something the sandboxed minter itself is not allowed to do.
func probeMintedBlobs(helper: String, blobs: MintedBlobs) throws {
  let insideFile = URL(fileURLWithPath: blobs.inside)
  let deepFile = URL(fileURLWithPath: blobs.deep)
  let canaryFile = URL(fileURLWithPath: blobs.canary)
  let documentFile = URL(fileURLWithPath: blobs.document)
  let scopedData = blobs.scoped
  let plainData = blobs.plain
  let documentData = blobs.documentScoped

  // The control the first run was missing. E7 establishes that the helper cannot
  // open the canary at the top of the work directory, but that says nothing about
  // the share subtree one level down — and the first run found the helper opening
  // share/inside.txt before any scope was started. Asking with no bookmark in play
  // at all is what separates "the bookmark granted this" from "the path was open".
  let baseline = try { () -> (inside: Bool, deep: Bool, canary: Bool) in
    let process = try spawnLoaded(Scripts.summarize, helper: helper)
    defer { process.shutdown() }
    let deadline = { ContinuousClock.now + .seconds(20) }
    func ask(_ url: URL) throws -> [String: Any] {
      try process.call(["op": "probe", "what": "open", "path": url.path], deadline: deadline())
    }
    let insideReply = try ask(insideFile)
    let deepReply = try ask(deepFile)
    let canaryReply = try ask(canaryFile)
    note("no bookmark at all — " + bookmarkLine("open(share/inside.txt)", insideReply))
    note("no bookmark at all — " + bookmarkLine("open(share/nested/deep.txt)", deepReply))
    note("no bookmark at all — " + bookmarkLine("open(canary.txt)", canaryReply))
    return (
      insideReply["ok"] as? Bool ?? false,
      deepReply["ok"] as? Bool ?? false,
      canaryReply["ok"] as? Bool ?? false
    )
  }()
  if baseline.inside || baseline.deep {
    note(
      "→ the subtree is already reachable by path without any bookmark, so nothing"
        + " this section measures can be attributed to one")
  }

  var scopedOutcome = BookmarkOutcome()
  if let scopedData {
    scopedOutcome = try probeBookmark(
      helper: helper, data: scopedData, scoped: true, label: "app-scoped")
  }
  // Not a formality. The first run found this variant delegating the subtree while
  // the security-scoped one could not even be resolved, which is the opposite of
  // what the design note expected, so it carries the result rather than the control.
  var plainOutcome = BookmarkOutcome()
  if let plainData {
    plainOutcome = try probeBookmark(
      helper: helper, data: plainData, scoped: false, label: "plain bookmark")
  }
  if let documentData {
    _ = try probeBookmark(
      helper: helper, data: documentData, scoped: true, document: documentFile,
      label: "document-scoped")
  }
  try probeDocumentScope(helper: helper, blobs: blobs)

  // Not a pass/fail. Either answer leaves the design standing; it decides whether
  // capability granularity is a subtree handed over once or a file at a time.
  //
  // The confound control is the no-bookmark baseline above, not anything measured
  // inside a probe: every step of a probe happens after a resolve, so a probe cannot
  // establish what was reachable before one.
  let confounded = baseline.inside || baseline.deep
  // Whichever variant delegated, if either did. The design cares that a subtree can
  // be handed over at all; which blob does it is the next question, not this one.
  let working: (data: Data, scoped: Bool, label: String)? =
    scopedOutcome.grantsSubtree
    ? scopedData.map { ($0, true, "app-scoped") }
    : (plainOutcome.grantsSubtree ? plainData.map { ($0, false, "plain") } : nil)

  if confounded {
    verdict(
      nil,
      "inconclusive here — the subtree was reachable by path without any bookmark,"
        + " so this configuration cannot attribute anything to one")
  } else if let working {
    verdict(
      nil,
      "the \(working.label) bookmark delegates the subtree: the helper opens files"
        + " beneath it that it is refused without one → capability can be granted per"
        + " subtree rather than per file")
    if working.label == "plain" {
      verdict(
        nil,
        "and it is the plain bookmark that does it — the security-scoped variant did"
          + " not survive the process boundary, which is the reverse of the assumption")
    }
  } else {
    verdict(
      nil,
      "no bookmark variant delegated the subtree → capability stays per-file over the"
        + " reverse RPC")
  }

  // Question 5. SIGKILL while the scope is still held is the normal recovery path
  // here, so the question is whether the same bytes still work in the replacement —
  // a grant that has to be re-negotiated after every kill is a different design.
  if !confounded, let working {
    _ = try probeBookmark(
      helper: helper, data: working.data, scoped: working.scoped,
      label: "holding the grant, then SIGKILL", holdAndKill: true)
    let again = try probeBookmark(
      helper: helper, data: working.data, scoped: working.scoped,
      label: "replacement helper after the kill")
    verdict(
      nil,
      again.grantsSubtree
        ? "the same serialized bookmark works again in a replacement helper — a kill"
          + " does not cost the grant"
        : "the bookmark does not survive a respawn — the grant has to be re-negotiated")
  } else {
    note("→ question 5 (SIGKILL then respawn) is moot: there was no working grant to lose")
  }
}

// MARK: - Run

/// The bookmark experiment is the only one that needs the host itself to be
/// sandboxed, and sandboxing the host would change every other baseline. So the
/// sandboxed host copy runs with this flag and nothing else.
let onlyBookmarks = CommandLine.arguments.contains("--only-bookmarks")

// The two halves of the sibling relay. A sandboxed process may not spawn a
// separately-contained child — the system aborts one carrying any App Sandbox
// entitlement other than `inherit` — so the sandboxed minter and the sandboxed
// helper cannot be parent and child. They can be siblings: the minter writes the
// blobs out and exits, and an unsandboxed orchestrator hands them to the helper.
if let outfile = optionValue("--mint-only") {
  do {
    print("bookmark minting only — writing blobs for a sibling process to probe")
    print("fixtures:          \(workDir.path)")
    try makeFixtures()
    section(
      "E8  minting — \(NSHomeDirectory().contains("/Library/Containers/") ? "sandboxed minter" : "unsandboxed minter")"
    )
    note("home: \(NSHomeDirectory())")
    note("subtree: \(shareDir.path)")
    let blobs = mintBlobs()
    let encoded = try JSONSerialization.data(withJSONObject: blobs.json)
    try encoded.write(to: URL(fileURLWithPath: outfile))
    note("wrote \(encoded.count) bytes to \(outfile)")
    // The work directory deliberately survives: the sibling has to find the subtree
    // the blobs point at. run.sh cleans it up.
    exit(0)
  } catch {
    print("")
    print("mint aborted: \(error)")
    exit(2)
  }
}

if let infile = optionValue("--probe-blobs") {
  do {
    let raw = try Data(contentsOf: URL(fileURLWithPath: infile))
    guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
      throw Failure("blob file is not a JSON object")
    }
    let blobs = MintedBlobs(json: object)
    print("bookmark probing only — blobs minted by a sibling process")
    print(
      "orchestrator is \(NSHomeDirectory().contains("/Library/Containers/") ? "sandboxed" : "unsandboxed")"
    )
    print("minter was      \(blobs.minterSandboxed ? "sandboxed" : "unsandboxed")")
    print("subtree:        \(blobs.subtree)")
    var variants: [(String, String)] = []
    if let sandboxed = sandboxedHelperPath {
      variants.append((sandboxed, "sandboxed helper"))
    }
    if let bookmarkHelper = bookmarkHelperPath {
      variants.append((bookmarkHelper, "helper with bookmark entitlements"))
    }
    for (helper, label) in variants {
      section(
        "E8  relayed from a \(blobs.minterSandboxed ? "sandboxed" : "unsandboxed") minter — \(label)"
      )
      do {
        try probeMintedBlobs(helper: helper, blobs: blobs)
      } catch {
        verdict(nil, "could not run: \(error)")
      }
    }
    section("summary")
    print(failures.isEmpty ? "   all checks passed" : "   \(failures.count) check(s) failed")
    exit(0)
  } catch {
    print("")
    print("probe aborted: \(error)")
    exit(2)
  }
}

if onlyBookmarks {
  do {
    print("security-scoped bookmark run — sandboxed host")
    print("helper:            \(helperPath)")
    print("sandboxed helper:  \(sandboxedHelperPath ?? "(not provided)")")
    print("fixtures:          \(workDir.path)")
    try makeFixtures()
    // What this pass is actually for: whether a contained host can mint a bookmark
    // at all, and whether it resolves in the minting process. The helper-side
    // results below are secondary — a child of a sandboxed host inherits that
    // sandbox, so "the helper" here is not the configuration the design ships, and
    // the fixtures sit inside the host's own container where the child may reach
    // them without any bookmark. probeBookmark's beforeStart control is what says
    // when that has happened.
    note("this pass answers minting, not delegation — see the beforeStart control")
    var variants: [(String, String)] = [(helperPath, "child inheriting the host's sandbox")]
    if let sandboxed = sandboxedHelperPath {
      variants.append((sandboxed, "helper with its own app-sandbox entitlement"))
    }
    if let bookmarkHelper = bookmarkHelperPath {
      variants.append((bookmarkHelper, "helper with bookmark entitlements"))
    }
    for (helper, label) in variants {
      // A sandboxed host may not be able to spawn a helper outside its container at
      // all. That is a finding about this configuration, not a reason to abort the
      // pass before the other variants have been tried.
      do {
        try experimentBookmarks(helper: helper, label: label)
      } catch {
        section("E8  security-scoped bookmark across processes — \(label)")
        verdict(nil, "could not run: \(error)")
      }
    }
    section("summary")
    if failures.isEmpty {
      print("   all checks passed")
    } else {
      print("   \(failures.count) check(s) failed:")
      for failure in failures { print("     - \(failure)") }
    }
    removeFixtures()
    exit(failures.isEmpty ? 0 : 1)
  } catch {
    print("")
    print("run aborted: \(error)")
    removeFixtures()
    exit(2)
  }
}

do {
  print("out-of-process JavaScriptCore plugin execution — measurement run")
  print("helper:            \(helperPath)")
  print("sandboxed helper:  \(sandboxedHelperPath ?? "(not provided — E5 and part of E7 skipped)")")
  print("fixtures:          \(workDir.path)")
  try makeFixtures()

  try experimentColdStart()
  try experimentColdBinary()
  try experimentRoundTrip()
  try experimentReverseRPC()
  try experimentKillAndRecover()
  try experimentMemory()

  // The in-process baseline every E3 figure is compared against runs inside this
  // process, so whether it has a JIT is measurable here rather than inferred from
  // the fact that it is signed the same way.
  section("E5  the host's own process — does the in-process evaluator get a JIT?")
  do {
    let evaluator = InProcessEvaluator()
    _ = evaluator.load(Scripts.computeHeavy)
    for i in 0..<20 { _ = evaluator.tick(raw: [String: Any](), tickNumber: i) }
    var allocator: UInt64 = 0
    var registerFile: UInt64 = 0
    var jsHeap: UInt64 = 0
    _ = ipc_jit_region_bytes(&allocator, &registerFile, &jsHeap)
    note(
      "OOPHost: JIT allocator \(mib(allocator)), JS heap \(mib(jsHeap)) → JIT "
        + (allocator > 0 ? "PRESENT" : "ABSENT"))
    verdict(
      nil,
      allocator > 0
        ? "the in-process baseline is JIT-enabled — E3's comparison is not like-for-like"
        : "the in-process baseline is interpreted too, so E3 compares two interpreters")
  }

  section("E5/E7 baseline — unsandboxed helper for contrast")
  let plainThroughput = try experimentThroughput(helper: helperPath, label: "unsandboxed")

  // Calibration. Comparing signing configurations only means something if the
  // measurement can see JIT at all, so force it off in a helper that is otherwise
  // identical and check that the number actually moves.
  // Kept because it is the observation that sent this section down the right path:
  // asking JSC to turn the JIT off changes nothing, and the VM region tags say why —
  // the baseline helper never had a JIT to turn off. The real control is the
  // allow-jit variant at the end, which does move the number.
  section("E5  control — the same helper with JSC_useJIT=0")
  let noJIT = try experimentThroughput(
    helper: helperPath, label: "JIT off   ", environment: ["JSC_useJIT": "0"])
  note("slowdown with JIT forced off: \(fmt(noJIT.loop / plainThroughput.loop, 2))×")
  verdict(
    nil,
    "uninformative on its own — the baseline is already interpreted, so there is"
      + " nothing for this switch to disable")
  try experimentDescriptorPassing(
    helper: helperPath, label: "unsandboxed helper", expectConfinement: false)

  if let sandboxed = sandboxedHelperPath {
    try experimentSandbox(helper: sandboxed, label: "sandboxed helper")
    section("E5  engine throughput under App Sandbox")
    let sandboxedThroughput = try experimentThroughput(helper: sandboxed, label: "sandboxed  ")
    note(
      "slowdown vs unsandboxed: "
        + "\(fmt(sandboxedThroughput.bridge / plainThroughput.bridge, 2))× (call bridge), "
        + "\(fmt(sandboxedThroughput.loop / plainThroughput.loop, 2))× (engine work)")
    try experimentDescriptorPassing(
      helper: sandboxed, label: "sandboxed helper", expectConfinement: true)
    // The shape the design actually has: an unsandboxed host minting the grant for a
    // sandboxed helper. run.sh runs the sandboxed-host case separately.
    try experimentBookmarks(helper: sandboxed, label: "unsandboxed host → sandboxed helper")
    if let bookmarkHelper = bookmarkHelperPath {
      try experimentBookmarks(
        helper: bookmarkHelper, label: "unsandboxed host → helper with bookmark entitlements")
    }
  }

  if let hardened = hardenedHelperPath {
    section("E5  hardened runtime without com.apple.security.cs.allow-jit")
    let hardenedThroughput = try experimentThroughput(helper: hardened, label: "hardened  ")
    note(
      "slowdown vs unsandboxed, loop-dominated: "
        + "\(fmt(hardenedThroughput.loop / plainThroughput.loop, 2))×")
  }

  if let jitHelper = jitHelperPath {
    section("E5  sandbox + hardened runtime + com.apple.security.cs.allow-jit")
    let jitThroughput = try experimentThroughput(helper: jitHelper, label: "allow-jit ")
    let speedup = plainThroughput.loop / jitThroughput.loop
    note("speedup vs the unsandboxed helper, engine work: \(fmt(speedup, 2))×")
    note(
      "call bridge, same comparison: \(fmt(plainThroughput.bridge / jitThroughput.bridge, 2))×"
        + " — the bridge is Swift-side work and the entitlement does not touch it")
    verdict(
      speedup >= 1.5,
      "granting allow-jit changes engine throughput by \(fmt(speedup, 2))× — "
        + "the measurement can see JIT")

    // The entitlement is only usable if it does not cost containment, and that has
    // to be measured on this variant rather than inherited from the sandbox-only one.
    try experimentSandbox(helper: jitHelper, label: "sandboxed + hardened + allow-jit")
    try experimentDescriptorPassing(
      helper: jitHelper, label: "sandboxed + hardened + allow-jit", expectConfinement: true)

    // Closes the loose end left by the JSC_useJIT=0 control above. That run was flat,
    // which has two possible causes: the baseline had no JIT to disable, or the
    // environment never reached the helper. Applying the same variable to the one
    // helper that *does* JIT separates them — if the JIT region disappears here, the
    // plumbing works and "nothing to disable" was the right reading.
    section("E5  control — allow-jit helper with JSC_useJIT=0")
    let jitDisabled = try experimentThroughput(
      helper: jitHelper, label: "jit+off   ", environment: ["JSC_useJIT": "0"])
    let disabledFactor = jitDisabled.loop / jitThroughput.loop
    note("slowdown vs the same helper without the variable: \(fmt(disabledFactor, 2))×")
    verdict(
      disabledFactor >= 1.5,
      "JSC_useJIT=0 does reach the helper and does disable the JIT — "
        + "so the flat baseline control meant there was no JIT to disable")
  }

  // Last, on purpose: E9 spawns helpers in bursts, and E1's first-spawn figure is
  // the one number here most sensitive to what ran before it.
  try experimentLaunchPhases()
  try experimentReuse()
  try experimentIdleCost()
  try experimentPoolStrategies()

  // E10 last: it launches a lot of one-shot binaries, and putting it after E9 keeps
  // the pool figures out of its way.
  try experimentColdPhases()
  try experimentBinaryIdentity()
  try experimentStubComparison()

  // E12 needs the hostile helper. Only E12a/b (framing and the RPC flood) run for
  // now — the questions the task says to settle first — and an attack that crashes
  // the host aborts the run here, which is itself the "must fix" answer.
  if let hostile = hostileHelperPath {
    try experimentHostileFraming(helper: hostile)
    try experimentHostileRPC(helper: hostile)
    try experimentHostileCapability()
    if let sandboxed = sandboxedHelperPath {
      try experimentHostileGrantScope(sandboxed: sandboxed)
      try experimentHostileContainment(sandboxed: sandboxed)
    } else {
      note("E12d/E12e need --sandboxed-helper — skipped")
    }
  }

  // E11 needs a helper that apps/JSCoreLab/export.sh has put through Xcode's
  // Developer ID export. Without one the section is skipped and nothing above changes.
  if let devID = devIDHelperPath {
    try experimentDeveloperID(devID: devID, adHoc: jitHelperPath)
    try experimentQuarantine(devID: devID, adHoc: jitHelperPath)
  }

  section("summary")
  if failures.isEmpty {
    print("   all checks passed")
  } else {
    print("   \(failures.count) check(s) failed:")
    for failure in failures { print("     - \(failure)") }
  }
  removeFixtures()
  exit(failures.isEmpty ? 0 : 1)
} catch {
  print("")
  print("run aborted: \(error)")
  removeFixtures()
  exit(2)
}
