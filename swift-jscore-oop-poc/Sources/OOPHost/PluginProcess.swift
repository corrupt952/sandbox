import CPluginIPC
import Darwin
import Foundation
import PluginIPC

/// `posix_spawn` + `socketpair(AF_UNIX)` rather than an XPC service: an XPC service
/// is baked into the bundle at signing time, which does not fit plugins installed at
/// runtime, and launchd's automatic restart blurs the one state this design has to
/// keep sharp — "the host killed it".
final class PluginProcess {
  let pid: pid_t
  let channel: FrameChannel
  private var nextID = 0
  private var reaped = false

  /// Serves `host.fetch` on behalf of the helper. The allowlist lives here, in the
  /// process that is never the one being killed.
  var fetchHandler: (String) -> Any = { _ in ["error": "no fetch handler"] }

  private(set) var hostCallsServiced = 0

  init(helperPath: String, environment: [String: String] = [:]) throws {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw IPCError.io(errno)
    }
    let parentFD = pair[0]
    let childFD = pair[1]
    // Keep the parent's end out of the child's descriptor table.
    _ = fcntl(parentFD, F_SETFD, FD_CLOEXEC)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // dup2 clears FD_CLOEXEC on the result, so fd 3 survives the exec.
    posix_spawn_file_actions_adddup2(&actions, childFD, 3)
    if childFD != 3 {
      posix_spawn_file_actions_addclose(&actions, childFD)
    }

    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment { merged[key] = value }
    var envp: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(helperPath), nil]
    defer {
      envp.forEach { free($0) }
      argv.forEach { free($0) }
    }

    var spawned: pid_t = 0
    let rc = posix_spawn(&spawned, helperPath, &actions, nil, &argv, &envp)
    close(childFD)
    guard rc == 0 else {
      close(parentFD)
      throw IPCError.io(rc)
    }

    self.pid = spawned
    self.channel = FrameChannel(fd: parentFD)
  }

  // MARK: - Requests

  /// Consumes the `ready` frame the helper sends before entering its loop.
  ///
  /// Every other experiment lets `call` swallow it, which is fine when the only
  /// question is end-to-end latency. Pre-warming needs the boundary: what a pool can
  /// pay in advance is everything up to here, and what a click still costs is
  /// everything after.
  @discardableResult
  func waitReady(deadline: ContinuousClock.Instant? = nil) throws -> [String: Any] {
    while true {
      let envelope = try channel.receive(deadline: deadline)
      // The body carries the helper's own clock readings, which is what lets a
      // launch be split at `main` rather than only at the IPC boundary.
      if envelope.body["op"] as? String == "ready" { return envelope.body }
    }
  }

  /// Sends one request and pumps the socket until its reply arrives, servicing any
  /// reverse RPC the helper raises in the meantime.
  @discardableResult
  func call(
    _ request: [String: Any],
    deadline: ContinuousClock.Instant? = nil,
    attachingFD: Int32 = -1
  ) throws -> [String: Any] {
    nextID += 1
    let id = nextID
    var body = request
    body["id"] = id
    try channel.send(body, attachingFD: attachingFD)

    while true {
      let envelope = try channel.receive(deadline: deadline)
      switch envelope.body["op"] as? String {
      case "result":
        if envelope.body["id"] as? Int == id { return envelope.body }
      case "hostCall":
        serviceHostCall(envelope.body)
      default:
        continue
      }
    }
  }

  private func serviceHostCall(_ body: [String: Any]) {
    hostCallsServiced += 1
    let id = body["id"] as? Int ?? 0
    let method = body["method"] as? String ?? ""
    var value: Any
    switch method {
    case "fetch":
      value = fetchHandler(body["arg"] as? String ?? "")
    default:
      value = ["error": "unknown method \(method)"]
    }
    try? channel.send(["id": id, "op": "hostReply", "value": value])
  }

  // MARK: - Lifecycle

  func kill(_ signal: Int32 = SIGKILL) {
    _ = Darwin.kill(pid, signal)
  }

  @discardableResult
  func reap() -> Int32 {
    guard !reaped else { return 0 }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    reaped = true
    return status
  }

  func shutdown() {
    _ = try? call(["op": "shutdown"], deadline: ContinuousClock.now + .seconds(2))
    channel.close()
    reap()
  }

  /// nil once the process is gone (and reaped) — proc_pid_rusage fails with ESRCH.
  var footprintBytes: UInt64? {
    var bytes: UInt64 = 0
    return ipc_phys_footprint(pid, &bytes) == 0 ? bytes : nil
  }

  /// -1 once the task is gone.
  var threadCount: Int32 {
    ipc_thread_count(pid)
  }

  /// nil once the process is gone. Flat across an observation window is what says a
  /// pre-warmed helper is genuinely idle rather than quietly busy.
  var cpuMicros: UInt64? {
    var micros: UInt64 = 0
    return ipc_cpu_micros(pid, &micros) == 0 ? micros : nil
  }
}
