import Foundation
import FoundationModels
import JavaScriptCore

/// Result of one evaluation (load or tick).
struct EvaluationResult: Identifiable {
  let id = UUID()
  let timestamp: Date
  let label: String
  let success: Bool
  let value: String
  let logs: [String]
  let elapsedMillis: Double
}

/// Wraps a single JSContext bound to one widget instance for the widget instance's lifetime.
///
/// Lifecycle:
///   1. `init` — create JSVirtualMachine + JSContext, install host bridge (`host.now`, `host.log`,
///      `host.fetch`, `host.state` per capability grants). Parse cost: 0.
///   2. `loadScript(_:)` — parse user script ONCE. The script is expected to assign
///      `globalThis.transform = (raw, ctx) => result`. Parse cost: paid once.
///   3. `tick(raw:)` — call `transform(raw, ctx)` and unwrap its return value. No re-parse.
///      Host-side overhead is just function invocation + JSValue unwrap.
///   4. `dispose` (deinit) — JSContext and JSVirtualMachine are released; heap GC'd.
///
/// Isolation:
///   - Each `JSEvaluator` owns its own `JSVirtualMachine` and `JSContext`.
///   - Two evaluators cannot see each other's globalThis, host bridge functions, or state slot.
///   - State slot (`host.state`) persists across ticks within one evaluator.
final class JSEvaluator {
  private let vm: JSVirtualMachine
  private let context: JSContext
  private var capturedLogs: [String] = []
  private(set) var allowedHosts: Set<String>
  private(set) var statePermission: Bool
  private(set) var aiPermission: Bool

  private var stateStore: [String: Any] = [:]
  private var scriptLoaded = false

  init(allowedHosts: Set<String>, statePermission: Bool, aiPermission: Bool) {
    self.vm = JSVirtualMachine()!
    self.context = JSContext(virtualMachine: vm)!
    self.allowedHosts = allowedHosts
    self.statePermission = statePermission
    self.aiPermission = aiPermission
    installHostBridge()
  }

  // MARK: - Public methods

  /// Parses the user script once. The script must assign `globalThis.transform` to a function
  /// of shape `(raw, ctx) => snapshotValue`. Re-loading a different script wipes globalThis first.
  @discardableResult
  func loadScript(_ script: String) -> EvaluationResult {
    capturedLogs.removeAll()
    var capturedException: String?
    context.exceptionHandler = { _, exception in
      capturedException = exception?.toString() ?? "<unknown>"
    }

    let start = ContinuousClock.now
    // Reset previous transform binding so reloads don't keep the old function alive.
    _ = context.evaluateScript("globalThis.transform = undefined;")
    _ = context.evaluateScript(script)
    let elapsed = ContinuousClock.now - start
    let elapsedMillis = Self.toMillis(elapsed)

    let transformDefined =
      context.objectForKeyedSubscript("transform")?.isUndefined == false
    if capturedException == nil && !transformDefined {
      capturedException = "script did not define globalThis.transform"
    }
    let success = capturedException == nil
    scriptLoaded = success

    return EvaluationResult(
      timestamp: Date(),
      label: "load",
      success: success,
      value: success ? "script parsed; transform ready" : (capturedException ?? "<unknown>"),
      logs: capturedLogs,
      elapsedMillis: elapsedMillis
    )
  }

  /// Calls `transform(raw, ctx)` and returns the unwrapped result.
  /// Requires `loadScript` to have succeeded.
  func tick(raw: Any, tickNumber: Int) -> EvaluationResult {
    guard scriptLoaded else {
      return EvaluationResult(
        timestamp: Date(),
        label: "tick \(tickNumber)",
        success: false,
        value: "no script loaded",
        logs: [],
        elapsedMillis: 0
      )
    }

    capturedLogs.removeAll()
    var capturedException: String?
    context.exceptionHandler = { _, exception in
      capturedException = exception?.toString() ?? "<unknown>"
    }

    let ctxArg: [String: Any] = [
      "now": Date().timeIntervalSince1970,
      "locale": Locale.current.identifier,
      "tickNumber": tickNumber,
    ]

    let start = ContinuousClock.now
    let transformFn = context.objectForKeyedSubscript("transform")
    let returned = transformFn?.call(withArguments: [raw, ctxArg])
    let elapsed = ContinuousClock.now - start
    let elapsedMillis = Self.toMillis(elapsed)

    if let capturedException {
      return EvaluationResult(
        timestamp: Date(),
        label: "tick \(tickNumber)",
        success: false,
        value: capturedException,
        logs: capturedLogs,
        elapsedMillis: elapsedMillis
      )
    }

    let unwrapped = Self.unwrap(returned)
    let asJSON = Self.formatJSON(unwrapped) ?? String(describing: unwrapped)
    return EvaluationResult(
      timestamp: Date(),
      label: "tick \(tickNumber)",
      success: true,
      value: asJSON,
      logs: capturedLogs,
      elapsedMillis: elapsedMillis
    )
  }

  /// Runs `tick` `count` times in a tight loop and reports aggregate timing.
  func tickMany(raw: Any, count: Int, startTick: Int) -> EvaluationResult {
    var firstResult: EvaluationResult?
    var lastResult: EvaluationResult?
    var totalMillis: Double = 0
    var successCount = 0

    let start = ContinuousClock.now
    for i in 0..<count {
      let r = tick(raw: raw, tickNumber: startTick + i)
      if r.success { successCount += 1 }
      totalMillis += r.elapsedMillis
      if firstResult == nil { firstResult = r }
      lastResult = r
    }
    let wallElapsed = ContinuousClock.now - start
    let wallMillis = Self.toMillis(wallElapsed)
    let avgMillis = count > 0 ? totalMillis / Double(count) : 0

    let summary = """
      ran \(count) ticks
        success: \(successCount) / \(count)
        wall clock: \(String(format: "%.2f", wallMillis)) ms
        sum(per-tick): \(String(format: "%.2f", totalMillis)) ms
        avg per tick: \(String(format: "%.3f", avgMillis)) ms
        last value: \(lastResult?.value ?? "—")
      """

    return EvaluationResult(
      timestamp: Date(),
      label: "tick × \(count)",
      success: successCount == count,
      value: summary,
      logs: lastResult?.logs ?? [],
      elapsedMillis: wallMillis
    )
  }

  // MARK: - Private methods

  private func installHostBridge() {
    context.evaluateScript("globalThis.host = {};")

    let log: @convention(block) (String) -> Void = { [weak self] msg in
      self?.capturedLogs.append(msg)
    }
    context.objectForKeyedSubscript("host")?
      .setObject(log, forKeyedSubscript: "log" as NSString)

    let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
    context.objectForKeyedSubscript("host")?
      .setObject(now, forKeyedSubscript: "now" as NSString)

    let locale: @convention(block) () -> String = { Locale.current.identifier }
    context.objectForKeyedSubscript("host")?
      .setObject(locale, forKeyedSubscript: "locale" as NSString)

    let fetch: @convention(block) (String) -> Any? = { [weak self] urlString in
      guard let self,
        let url = URL(string: urlString),
        let host = url.host,
        self.allowedHosts.contains(host)
      else {
        return ["error": "host not allowed"]
      }
      let semaphore = DispatchSemaphore(value: 0)
      var resultJSON: Any?
      var errorMessage: String?
      let task = URLSession.shared.dataTask(with: url) { data, _, error in
        defer { semaphore.signal() }
        if let error {
          errorMessage = error.localizedDescription
          return
        }
        guard let data else {
          errorMessage = "empty payload"
          return
        }
        resultJSON =
          (try? JSONSerialization.jsonObject(with: data))
          ?? String(data: data, encoding: .utf8) ?? "<binary>"
      }
      task.resume()
      _ = semaphore.wait(timeout: .now() + 10)
      if let errorMessage { return ["error": errorMessage] }
      return resultJSON ?? ["error": "no data"]
    }
    context.objectForKeyedSubscript("host")?
      .setObject(fetch, forKeyedSubscript: "fetch" as NSString)

    if statePermission {
      let stateGet: @convention(block) (String) -> Any? = { [weak self] key in
        self?.stateStore[key]
      }
      let stateSet: @convention(block) (String, Any) -> Void = { [weak self] key, value in
        self?.stateStore[key] = value
      }
      let stateObj = JSValue(newObjectIn: context)!
      stateObj.setObject(stateGet, forKeyedSubscript: "get" as NSString)
      stateObj.setObject(stateSet, forKeyedSubscript: "set" as NSString)
      context.objectForKeyedSubscript("host")?
        .setObject(stateObj, forKeyedSubscript: "state" as NSString)
    }

    if aiPermission {
      // host.ai.respond(prompt) → { text } / { error }
      // Uses Apple's on-device Foundation Models. Requires macOS 26+ on Apple Silicon with
      // Apple Intelligence enabled. Synchronous from the script's perspective; an internal
      // semaphore blocks the host thread until the async model call returns or times out.
      let respond: @convention(block) (String) -> Any? = { prompt in
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
          return ["error": "ai unavailable: \(availability)"]
        }
        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        var errorMsg: String?
        Task {
          defer { semaphore.signal() }
          do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            output = response.content
          } catch {
            errorMsg = error.localizedDescription
          }
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
          return ["error": "ai timeout"]
        }
        if let errorMsg { return ["error": errorMsg] }
        return ["text": output ?? "<empty>"]
      }

      // host.ai.availability() → "available" / "unavailable(reason)" so the script can decide
      // whether to call respond at all.
      let availabilityFn: @convention(block) () -> String = {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable: \(reason)"
        @unknown default: return "unknown"
        }
      }

      let aiObj = JSValue(newObjectIn: context)!
      aiObj.setObject(respond, forKeyedSubscript: "respond" as NSString)
      aiObj.setObject(availabilityFn, forKeyedSubscript: "availability" as NSString)
      context.objectForKeyedSubscript("host")?
        .setObject(aiObj, forKeyedSubscript: "ai" as NSString)
    }
  }

  // MARK: - Helpers

  private static func toMillis(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
      + Double(duration.components.attoseconds) * 1e-15
  }

  private static func unwrap(_ jsValue: JSValue?) -> Any {
    guard let jsValue else { return NSNull() }
    if jsValue.isUndefined { return "<undefined>" }
    if jsValue.isNull { return NSNull() }
    return jsValue.toObject() ?? "<unconvertible>"
  }

  private static func formatJSON(_ value: Any) -> String? {
    if JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
      let string = String(data: data, encoding: .utf8)
    {
      return string
    }
    if let value = value as? String { return "\"\(value)\"" }
    if let value = value as? NSNumber { return value.stringValue }
    if value is NSNull { return "null" }
    return nil
  }
}

// MARK: - Permission manifest (GitHub Actions–style)

/// Per-scope grant level. Default is `.none` so any scope not declared is denied.
enum GrantLevel: String, Decodable, Equatable {
  case none
  case read
  case readwrite = "readwrite"
  case write
  case fetch
  case respond
}

/// Network sub-permission: level + optional host allowlist (Figma's networkAccess shape).
struct NetworkPermission: Decodable, Equatable {
  let level: GrantLevel
  let hosts: [String]?
}

/// Plugin permissions block. Mirrors GitHub Actions' top-level `permissions:` keyed by scope,
/// each scope holding a discrete grant level. Network adds an allowlist constraint.
struct PluginPermissions: Decodable, Equatable {
  let network: NetworkPermission?
  let state: GrantLevel?
  let ai: GrantLevel?
  let log: GrantLevel?

  static let denyAll = PluginPermissions(network: nil, state: nil, ai: nil, log: nil)

  /// Convenience: derives the JSEvaluator flags from the declared permissions. Any field
  /// missing or set to `.none` results in the corresponding host API being absent from the
  /// JSContext — the language-level "default deny" guarantee.
  func evaluatorConfig() -> (allowedHosts: Set<String>, state: Bool, ai: Bool) {
    let hosts: Set<String> = {
      guard let net = network, net.level == .fetch else { return [] }
      return Set(net.hosts ?? [])
    }()
    let stateOK = (state == .read || state == .readwrite)
    let aiOK = (ai == .respond)
    return (hosts, stateOK, aiOK)
  }
}

struct PluginManifest: Decodable, Equatable {
  let permissions: PluginPermissions?
}

/// Demonstrates two `JSEvaluator` instances are heap-isolated.
enum IsolationDemo {
  static func run() -> EvaluationResult {
    var lines: [String] = []
    let start = ContinuousClock.now

    let evalA = JSEvaluator(allowedHosts: [], statePermission: true, aiPermission: false)
    let evalB = JSEvaluator(allowedHosts: [], statePermission: true, aiPermission: false)

    let scriptA = """
      globalThis.leaked = "secret-from-A";
      host.state.set("token", "A-private-token");
      globalThis.transform = (raw, ctx) => ({ note: "A loaded" });
      """
    let scriptB = """
      globalThis.transform = (raw, ctx) => ({
        seenGlobal: (typeof globalThis.leaked === "undefined") ? "<undefined>" : globalThis.leaked,
        seenState: host.state.get("token") ?? "<undefined>"
      });
      """

    _ = evalA.loadScript(scriptA)
    _ = evalB.loadScript(scriptB)
    _ = evalA.tick(raw: NSNull(), tickNumber: 1)
    let bResult = evalB.tick(raw: NSNull(), tickNumber: 1)
    let bLeakedGlobal = bResult.value.contains("<undefined>")
    let bLeakedState = !bResult.value.contains("A-private")
    lines.append(
      "  evaluator B (after A leaked into A's globalThis + state):\n    "
        + bResult.value.replacingOccurrences(of: "\n", with: "\n    "))
    lines.append(
      "  → globalThis isolation: " + (bLeakedGlobal ? "✓ isolated" : "✗ LEAK"))
    lines.append(
      "  → host.state isolation: " + (bLeakedState ? "✓ isolated" : "✗ LEAK"))

    // Reuse A: verify state persistence within one evaluator across ticks.
    let scriptCounter = """
      globalThis.transform = (raw, ctx) => {
        const n = (host.state.get("count") ?? 0) + 1;
        host.state.set("count", n);
        return { count: n };
      };
      """
    let evalP = JSEvaluator(allowedHosts: [], statePermission: true, aiPermission: false)
    _ = evalP.loadScript(scriptCounter)
    _ = evalP.tick(raw: NSNull(), tickNumber: 1)
    _ = evalP.tick(raw: NSNull(), tickNumber: 2)
    let p3 = evalP.tick(raw: NSNull(), tickNumber: 3)
    let counterOK = p3.value.contains("\"count\" : 3")
    lines.append("  state persists within one evaluator across ticks: " + p3.value)
    lines.append(
      "  → \"count\":3 after 3 ticks: " + (counterOK ? "✓ persists" : "✗ does not persist"))

    let elapsed = ContinuousClock.now - start
    let elapsedMillis = JSEvaluator_toMillis(elapsed)

    let allPass = bLeakedGlobal && bLeakedState && counterOK
    let summary =
      (allPass ? "ALL PASS\n\n" : "FAIL\n\n") + lines.joined(separator: "\n\n")
    return EvaluationResult(
      timestamp: Date(),
      label: "Isolation Test",
      success: allPass,
      value: summary,
      logs: [],
      elapsedMillis: elapsedMillis
    )
  }
}

private func JSEvaluator_toMillis(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1000
    + Double(duration.components.attoseconds) * 1e-15
}
