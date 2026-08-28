import Foundation
import JavaScriptCore

/// The in-process arrangement the out-of-process one is being measured against:
/// one JSVirtualMachine + JSContext in the host, with a host bridge that blocks the
/// calling thread on a DispatchSemaphore while the work happens elsewhere.
///
/// This mirrors `swift-jscore-plugin-sandbox`'s `JSEvaluator` closely enough for the
/// comparison to mean something — same call shape, same semaphore, same blocking.
final class InProcessEvaluator {
  private let vm = JSVirtualMachine()!
  private let context: JSContext
  private let worker = DispatchQueue(label: "inprocess.fetch")
  var fetchHandler: (String) -> Any = { _ in ["error": "no fetch handler"] }

  init() {
    context = JSContext(virtualMachine: vm)!
    install()
  }

  private func install() {
    context.evaluateScript("globalThis.host = {};")
    let host = context.objectForKeyedSubscript("host")!

    let log: @convention(block) (String) -> Void = { _ in }
    host.setObject(log, forKeyedSubscript: "log" as NSString)

    let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
    host.setObject(now, forKeyedSubscript: "now" as NSString)

    let fetch: @convention(block) (String) -> Any? = { [weak self] url in
      guard let self else { return ["error": "gone"] }
      let semaphore = DispatchSemaphore(value: 0)
      var result: Any = NSNull()
      self.worker.async {
        result = self.fetchHandler(url)
        semaphore.signal()
      }
      semaphore.wait()
      return result
    }
    host.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
  }

  @discardableResult
  func load(_ script: String) -> Bool {
    var failed = false
    context.exceptionHandler = { _, _ in failed = true }
    _ = context.evaluateScript("globalThis.transform = undefined;")
    _ = context.evaluateScript(script)
    let defined = context.objectForKeyedSubscript("transform")?.isUndefined == false
    return !failed && defined
  }

  func tick(raw: Any, tickNumber: Int) -> Any {
    let transform = context.objectForKeyedSubscript("transform")
    let returned = transform?.call(withArguments: [raw, ["tickNumber": tickNumber]])
    return returned?.toObject() ?? NSNull()
  }
}
