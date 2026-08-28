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
func freshHelperCopy(index: Int) throws -> String {
  let staging = workDir.appendingPathComponent("staging")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  let copy = staging.appendingPathComponent("PluginHelper-\(index)")
  try? FileManager.default.removeItem(at: copy)
  try FileManager.default.copyItem(at: URL(fileURLWithPath: helperPath), to: copy)
  return copy.path
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
) throws -> (bridge: Double, loop: Double) {
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

  return (bridge, loop)
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
