import CPluginIPC
import Darwin
import Foundation
import JavaScriptCore
import PluginIPC

// First statement in the process, so the gap between this and the host's own reading
// is everything that happened before any code here ran: the kernel's work on the
// image, and dyld's. `CLOCK_UPTIME_RAW` is the same monotonic base on both sides, so
// the two readings can be subtracted across the process boundary.
let tMain = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

// One helper process hosts exactly one plugin. It is single-threaded on purpose:
// the whole point of the design is that a runaway script wedges *this* process and
// nothing else, so there is no rescue thread here to paper over that. Recovery is
// the host's job, and its only lever is SIGKILL.

let channel = FrameChannel(fd: 3)

// `var` rather than `let` so `reset` can replace them. Nothing reassigns these
// outside that op, so every other experiment sees the same objects it always did.
var vm = JSVirtualMachine()!
var context = JSContext(virtualMachine: vm)!
/// After the engine exists. What sits between this and `tMain` is JavaScriptCore
/// coming up, which is the only part of the launch the helper's own code controls.
let tVM = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

var capturedLogs: [String] = []
var allowedHosts: Set<String> = []
var statePermission = false
var stateStore: [String: Any] = [:]
var scriptLoaded = false
var callCounter = 1_000_000
var handedFD: Int32 = -1

// MARK: - Reverse RPC

/// The policy gate stays in the host: a process that may be killed at any moment is
/// the wrong place to keep its own checkpoint. Blocks the JS thread, which is the
/// same shape as the in-process semaphore bridge it is being compared against.
func callHost(method: String, arg: Any) -> Any {
  callCounter += 1
  let id = callCounter
  do {
    try channel.send(["id": id, "op": "hostCall", "method": method, "arg": arg])
    while true {
      let envelope = try channel.receive()
      if envelope.body["op"] as? String == "hostReply",
        envelope.body["id"] as? Int == id
      {
        return envelope.body["value"] ?? NSNull()
      }
    }
  } catch {
    return ["error": "ipc: \(error)"]
  }
}

// MARK: - Host bridge

func installHostBridge() {
  context.evaluateScript("globalThis.host = {};")
  let host = context.objectForKeyedSubscript("host")!

  let log: @convention(block) (String) -> Void = { message in
    capturedLogs.append(message)
  }
  host.setObject(log, forKeyedSubscript: "log" as NSString)

  let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
  host.setObject(now, forKeyedSubscript: "now" as NSString)

  let locale: @convention(block) () -> String = { Locale.current.identifier }
  host.setObject(locale, forKeyedSubscript: "locale" as NSString)

  // Present unconditionally here because the host decides. The capability-by-absence
  // property is preserved by the host refusing the call, not by hiding the binding —
  // the helper's copy of the allowlist would be editable by whatever wedged it.
  let fetch: @convention(block) (String) -> Any? = { urlString in
    callHost(method: "fetch", arg: urlString)
  }
  host.setObject(fetch, forKeyedSubscript: "fetch" as NSString)

  if statePermission {
    let stateObject = JSValue(newObjectIn: context)!
    let get: @convention(block) (String) -> Any? = { key in stateStore[key] }
    let set: @convention(block) (String, Any) -> Void = { key, value in
      stateStore[key] = value
    }
    stateObject.setObject(get, forKeyedSubscript: "get" as NSString)
    stateObject.setObject(set, forKeyedSubscript: "set" as NSString)
    host.setObject(stateObject, forKeyedSubscript: "state" as NSString)
  }
}

// MARK: - Probes

func readSome(_ fd: Int32, limit: Int = 128) -> String? {
  var buffer = [UInt8](repeating: 0, count: limit)
  let n = buffer.withUnsafeMutableBytes { raw in
    read(fd, raw.baseAddress, raw.count)
  }
  guard n > 0 else { return nil }
  return String(decoding: buffer[0..<n], as: UTF8.self)
}

/// The domain and code, not just the localized string: "The file couldn't be
/// opened." is the same sentence for several unrelated refusals.
func describeNS(_ error: Error) -> String {
  let ns = error as NSError
  return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
}

/// All three report the same shape, so the host can print an attempt without caring
/// whether it went through a path, a descriptor, or a directory stream.
func openReport(_ path: String) -> [String: Any] {
  let fd = open(path, O_RDONLY)
  if fd < 0 {
    let code = errno
    return ["ok": false, "errno": Int(code), "errnoText": String(cString: strerror(code))]
  }
  let head = readSome(fd)
  close(fd)
  return ["ok": true, "head": head ?? ""]
}

func openatReport(_ dirFD: Int32, _ name: String) -> [String: Any] {
  let fd = openat(dirFD, name, O_RDONLY)
  if fd < 0 {
    let code = errno
    return ["ok": false, "errno": Int(code), "errnoText": String(cString: strerror(code))]
  }
  let head = readSome(fd)
  close(fd)
  return ["ok": true, "head": head ?? ""]
}

func listReport(_ path: String) -> [String: Any] {
  guard let stream = opendir(path) else {
    let code = errno
    return ["ok": false, "errno": Int(code), "errnoText": String(cString: strerror(code))]
  }
  var names: [String] = []
  while let entry = readdir(stream) {
    var raw = entry.pointee.d_name
    let name = withUnsafePointer(to: &raw) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
        String(cString: $0)
      }
    }
    if name != "." && name != ".." { names.append(name) }
  }
  closedir(stream)
  return ["ok": true, "entries": names]
}

func probe(_ what: String, _ request: [String: Any]) -> [String: Any] {
  switch what {
  case "home":
    let home = NSHomeDirectory()
    return [
      "home": home,
      "envHome": String(cString: getenv("HOME") ?? strdup("")),
      "inContainer": home.contains("/Library/Containers/"),
      "cwd": FileManager.default.currentDirectoryPath,
    ]

  case "children":
    var code: Int32 = 0
    let count = ipc_child_count(getpid(), &code)
    return [
      "count": Int(count),
      "errno": Int(code),
      "errnoText": String(cString: strerror(code)),
    ]

  case "open":
    let path = request["path"] as? String ?? ""
    let fd = open(path, O_RDONLY)
    if fd < 0 {
      let code = errno
      return ["ok": false, "errno": Int(code), "errnoText": String(cString: strerror(code))]
    }
    let head = readSome(fd)
    close(fd)
    return ["ok": true, "head": head ?? ""]

  case "fd-read":
    guard handedFD >= 0 else { return ["ok": false, "why": "no descriptor received"] }
    let head = readSome(handedFD)
    close(handedFD)
    handedFD = -1
    return ["ok": head != nil, "head": head ?? ""]

  case "fd-openat":
    guard handedFD >= 0 else { return ["ok": false, "why": "no descriptor received"] }
    let relative = request["relative"] as? String ?? ""
    let escape = request["escape"] as? String ?? ""
    var result: [String: Any] = [:]

    let inner = openat(handedFD, relative, O_RDONLY)
    if inner < 0 {
      let code = errno
      result["insideOK"] = false
      result["insideErrno"] = Int(code)
      result["insideErrnoText"] = String(cString: strerror(code))
    } else {
      result["insideOK"] = true
      result["insideHead"] = readSome(inner) ?? ""
      close(inner)
    }

    if !escape.isEmpty {
      let outer = openat(handedFD, escape, O_RDONLY)
      if outer < 0 {
        let code = errno
        result["escapeOK"] = false
        result["escapeErrno"] = Int(code)
        result["escapeErrnoText"] = String(cString: strerror(code))
      } else {
        result["escapeOK"] = true
        result["escapeHead"] = readSome(outer) ?? ""
        close(outer)
      }
    }

    close(handedFD)
    handedFD = -1
    return result

  case "fd-readdir":
    // openat through the descriptor is denied, but enumeration does not re-resolve a
    // path — it reads the directory the descriptor already refers to. Whether that
    // is also denied is a separate question from whether openat is.
    guard handedFD >= 0 else { return ["ok": false, "why": "no descriptor received"] }
    let duplicate = dup(handedFD)
    close(handedFD)
    handedFD = -1
    guard duplicate >= 0, let stream = fdopendir(duplicate) else {
      let code = errno
      if duplicate >= 0 { close(duplicate) }
      return ["ok": false, "errno": Int(code), "errnoText": String(cString: strerror(code))]
    }
    var names: [String] = []
    while let entry = readdir(stream) {
      var raw = entry.pointee.d_name
      let name = withUnsafePointer(to: &raw) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    closedir(stream)
    return ["ok": true, "entries": names]

  case "bookmark":
    // The sanctioned way to hand a sandboxed process a subtree, as opposed to the
    // SCM_RIGHTS descriptor above which carries operations but not path resolution.
    // Every step is reported separately: resolving, starting the scope, and what can
    // be opened before/during/after it, because a grant that only works while the
    // scope is held is a different capability shape from one that does not.
    guard let payload = request["data"] as? String,
      let data = Data(base64Encoded: payload)
    else {
      return ["ok": false, "why": "no bookmark data"]
    }
    let scoped = request["scoped"] as? Bool ?? true
    let relative = request["relative"] as? String ?? ""
    let deep = request["deep"] as? String ?? ""
    let escape = request["escape"] as? String ?? ""

    var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    if scoped { options.insert(.withSecurityScope) }
    // A document-scoped bookmark resolves only against the document it was made
    // relative to, so the helper needs that URL as well as the bytes.
    var relativeURL: URL?
    if let document = request["document"] as? String, !document.isEmpty {
      relativeURL = URL(fileURLWithPath: document)
    }

    var stale = false
    let resolved: URL
    do {
      resolved = try URL(
        resolvingBookmarkData: data, options: options, relativeTo: relativeURL,
        bookmarkDataIsStale: &stale)
    } catch {
      return [
        "ok": false, "resolved": false,
        "error": (error as NSError).localizedDescription,
        "errorDomain": (error as NSError).domain,
        "errorCode": (error as NSError).code,
      ]
    }

    var result: [String: Any] = [
      "ok": true, "resolved": true, "stale": stale, "path": resolved.path,
    ]
    // Before starting the scope. Taken after resolving, so it cannot say what was
    // reachable beforehand — that is the host's no-bookmark control. What it does
    // separate is resolving from the scope call, and measured, resolving is what
    // grants access.
    result["beforeStart"] = openReport(resolved.appendingPathComponent(relative).path)

    let started = resolved.startAccessingSecurityScopedResource()
    result["started"] = started

    result["list"] = listReport(resolved.path)
    result["insideByPath"] = openReport(resolved.appendingPathComponent(relative).path)
    if !deep.isEmpty {
      result["deepByPath"] = openReport(resolved.appendingPathComponent(deep).path)
    }

    let dirFD = open(resolved.path, O_RDONLY | O_DIRECTORY)
    if dirFD < 0 {
      let code = errno
      result["dirOpen"] = [
        "ok": false, "errno": Int(code), "errnoText": String(cString: strerror(code)),
      ]
    } else {
      result["dirOpen"] = ["ok": true]
      result["insideByOpenat"] = openatReport(dirFD, relative)
      if !deep.isEmpty { result["deepByOpenat"] = openatReport(dirFD, deep) }
      if !escape.isEmpty { result["escapeByOpenat"] = openatReport(dirFD, escape) }
      close(dirFD)
    }
    if !escape.isEmpty {
      result["escapeByPath"] = openReport(resolved.appendingPathComponent(escape).path)
    }

    // `hold` leaves the scope open so the host can SIGKILL this process with the
    // grant still outstanding — the state a wedged plugin dies in.
    if request["hold"] as? Bool == true {
      result["held"] = true
      return result
    }
    if started { resolved.stopAccessingSecurityScopedResource() }
    result["afterStop"] = openReport(resolved.appendingPathComponent(relative).path)
    return result

  case "document-bookmark":
    // A document-scoped bookmark resolves only against its document, so the helper
    // needs the document before it can use one — and it cannot reach the document by
    // path. The bootstrap is a plain bookmark for the directory the document is in,
    // which makes the dependency explicit rather than assumed.
    //
    // The two controls are what keep the result honest. The target must be refused
    // before anything is resolved, and refused again after the bootstrap, because a
    // bootstrap that happened to cover the target would produce a success that has
    // nothing to do with document-scope.
    let target = request["target"] as? String ?? ""
    let document = request["document"] as? String ?? ""
    var result: [String: Any] = [:]

    result["controlTarget"] = openReport(target)
    result["controlDocument"] = openReport(document)

    if let payload = request["bootstrap"] as? String, let data = Data(base64Encoded: payload) {
      do {
        var stale = false
        let dir = try URL(
          resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
          relativeTo: nil, bookmarkDataIsStale: &stale)
        result["bootstrapResolved"] = true
        result["bootstrapStarted"] = dir.startAccessingSecurityScopedResource()
      } catch {
        result["bootstrapResolved"] = false
        result["bootstrapError"] = describeNS(error)
      }
    }
    result["documentAfterBootstrap"] = openReport(document)
    // The control that decides whether the last step means anything.
    result["targetAfterBootstrap"] = openReport(target)

    guard let payload = request["data"] as? String, let data = Data(base64Encoded: payload) else {
      result["ok"] = false
      result["why"] = "no document-scoped blob to try"
      return result
    }
    do {
      var stale = false
      let resolved = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope, .withoutUI, .withoutMounting],
        relativeTo: URL(fileURLWithPath: document), bookmarkDataIsStale: &stale)
      result["ok"] = true
      result["resolved"] = true
      result["stale"] = stale
      result["path"] = resolved.path
      result["started"] = resolved.startAccessingSecurityScopedResource()
      result["targetAfterResolve"] = openReport(resolved.path)
    } catch {
      result["ok"] = false
      result["resolved"] = false
      result["error"] = describeNS(error)
    }
    return result

  case "jit":
    // Asked after the spin probe has run, so JSC has had every chance to compile.
    var allocator: UInt64 = 0
    var registerFile: UInt64 = 0
    var heap: UInt64 = 0
    _ = ipc_jit_region_bytes(&allocator, &registerFile, &heap)
    return [
      "jitAllocatorBytes": Int(allocator),
      "jitRegisterFileBytes": Int(registerFile),
      "jsHeapBytes": Int(heap),
      "jitPresent": allocator > 0,
    ]

  case "footprint":
    var bytes: UInt64 = 0
    let rc = ipc_phys_footprint(getpid(), &bytes)
    return ["ok": rc == 0, "bytes": Int(bytes)]

  case "spin":
    // Runs transform in a tight loop with no IPC in the path, so the number
    // reflects the engine rather than the transport.
    let count = request["count"] as? Int ?? 100_000
    let raw = request["raw"] ?? [String: Any]()
    guard let transform = context.objectForKeyedSubscript("transform"),
      !transform.isUndefined
    else {
      return ["ok": false, "why": "no transform loaded"]
    }
    let start = ContinuousClock.now
    for i in 0..<count {
      _ = transform.call(withArguments: [raw, ["tickNumber": i]])
    }
    let elapsed = Timing.millis(ContinuousClock.now - start)
    return [
      "ok": true,
      "count": count,
      "millis": elapsed,
      "perTickMicros": elapsed * 1000 / Double(max(count, 1)),
    ]

  default:
    return ["ok": false, "why": "unknown probe \(what)"]
  }
}

// MARK: - Request handling

func handleLoad(_ request: [String: Any]) -> [String: Any] {
  let script = request["script"] as? String ?? ""
  var failure: String?
  context.exceptionHandler = { _, exception in
    failure = exception?.toString() ?? "<unknown>"
  }
  _ = context.evaluateScript("globalThis.transform = undefined;")
  _ = context.evaluateScript(script)

  let defined = context.objectForKeyedSubscript("transform")?.isUndefined == false
  if failure == nil && !defined {
    failure = "script did not define globalThis.transform"
  }
  scriptLoaded = failure == nil
  return scriptLoaded ? ["ok": true] : ["ok": false, "error": failure!]
}

func handleTick(_ request: [String: Any]) -> [String: Any] {
  guard scriptLoaded else { return ["ok": false, "error": "no script loaded"] }
  capturedLogs.removeAll()
  var failure: String?
  context.exceptionHandler = { _, exception in
    failure = exception?.toString() ?? "<unknown>"
  }

  let raw = request["raw"] ?? NSNull()
  let ctx: [String: Any] = [
    "now": Date().timeIntervalSince1970,
    "locale": Locale.current.identifier,
    "tickNumber": request["tickNumber"] as? Int ?? 0,
  ]

  let transform = context.objectForKeyedSubscript("transform")
  let returned = transform?.call(withArguments: [raw, ctx])
  if let failure { return ["ok": false, "error": failure] }

  var value: Any = NSNull()
  if let returned, !returned.isUndefined, !returned.isNull {
    value = returned.toObject() ?? NSNull()
  }
  // Only ship values JSONSerialization can encode; a plugin returning something
  // exotic must not be able to break the transport.
  if !JSONSerialization.isValidJSONObject([value]) {
    value = String(describing: value)
  }
  return ["ok": true, "value": value, "logs": capturedLogs]
}

// MARK: - Main loop

installHostBridge()
try? channel.send([
  "op": "ready", "pid": Int(getpid()),
  "tMain": Int(tMain), "tVM": Int(tVM),
  "tReady": Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
])

while true {
  let envelope: FrameChannel.Envelope
  do {
    envelope = try channel.receive()
  } catch {
    // Host went away. Nothing to report to.
    exit(0)
  }

  if let fd = envelope.fd {
    if handedFD >= 0 { close(handedFD) }
    handedFD = fd
  }

  let request = envelope.body
  let id = request["id"] as? Int ?? 0
  let op = request["op"] as? String ?? ""

  var reply: [String: Any]
  switch op {
  case "configure":
    allowedHosts = Set(request["allowedHosts"] as? [String] ?? [])
    statePermission = request["state"] as? Bool ?? false
    installHostBridge()
    reply = ["ok": true]
  case "reset":
    // "Back to the state a freshly spawned helper is in" is the whole contract:
    // reusing a pre-warmed process for a second plugin is only sound if nothing of
    // the first one survives. Replacing the context alone would leave the virtual
    // machine — and whatever the previous plugin put in it — in place.
    let started = ContinuousClock.now
    vm = JSVirtualMachine()!
    context = JSContext(virtualMachine: vm)!
    capturedLogs.removeAll()
    stateStore.removeAll()
    allowedHosts.removeAll()
    statePermission = false
    scriptLoaded = false
    installHostBridge()
    reply = ["ok": true, "millis": Timing.millis(ContinuousClock.now - started)]
  case "load":
    reply = handleLoad(request)
  case "tick":
    reply = handleTick(request)
  case "probe":
    reply = probe(request["what"] as? String ?? "", request)
  case "shutdown":
    try? channel.send(["id": id, "op": "result", "ok": true])
    exit(0)
  default:
    reply = ["ok": false, "error": "unknown op \(op)"]
  }

  reply["id"] = id
  reply["op"] = "result"
  try? channel.send(reply)
}
