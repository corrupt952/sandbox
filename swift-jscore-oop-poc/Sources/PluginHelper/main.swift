import CPluginIPC
import Darwin
import Foundation
import JavaScriptCore
import PluginIPC

// One helper process hosts exactly one plugin. It is single-threaded on purpose:
// the whole point of the design is that a runaway script wedges *this* process and
// nothing else, so there is no rescue thread here to paper over that. Recovery is
// the host's job, and its only lever is SIGKILL.

let channel = FrameChannel(fd: 3)

let vm = JSVirtualMachine()!
let context = JSContext(virtualMachine: vm)!

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
try? channel.send(["op": "ready", "pid": Int(getpid())])

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
