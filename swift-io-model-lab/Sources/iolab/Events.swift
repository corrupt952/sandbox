import Foundation

/// One point in a connection's lifecycle, streamed to the dashboard. `mode`
/// tags which server (blocking / threaded / nonblocking) it came from so the
/// dashboard can render one panel per model on a shared time axis.
struct ConnEvent: Codable {
  let mode: String
  let connID: Int
  let phase: String
  let t: Double
  let detail: String?

  func jsonLine() -> String {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) {
      return s
    }
    return "{}"
  }
}

/// One SSE subscriber's mailbox. `lock` doubles as the wait/signal condition.
final class Subscriber {
  let lock = NSCondition()
  var queue: [String] = []
}

/// Fan-out hub: servers `emit` connection events (tagged with a mode), the
/// monitor's SSE clients subscribe. Also mirrors events to stdout so the CLI is
/// useful on its own. One hub can be shared by several servers at once.
final class EventHub {
  private let lock = NSLock()
  private var subscribers: [Subscriber] = []
  private var history: [String] = []
  private let start = DispatchTime.now()

  private func elapsed() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
  }

  func emit(mode: String, connID: Int, phase: String, detail: String? = nil) {
    let t = elapsed()
    let event = ConnEvent(mode: mode, connID: connID, phase: phase, t: t, detail: detail)
    let line = event.jsonLine()

    lock.lock()
    history.append(line)
    if history.count > 4000 { history.removeFirst(history.count - 4000) }
    let current = subscribers
    lock.unlock()

    let modeTag = mode == "system" ? "•" : "[\(mode)]"
    let idTag = connID == 0 ? "" : "#\(connID)"
    print(String(format: "[%8.3f] %@ %@ %@ %@", t, modeTag, idTag, phase, detail ?? ""))

    for sub in current {
      sub.lock.lock()
      sub.queue.append(line)
      sub.lock.signal()
      sub.lock.unlock()
    }
  }

  /// System-level log line (rendered in the dashboard's log box, not a panel).
  func log(_ message: String) {
    emit(mode: "system", connID: 0, phase: "log", detail: message)
  }

  func subscribe() -> Subscriber {
    let sub = Subscriber()
    lock.lock()
    subscribers.append(sub)
    lock.unlock()
    return sub
  }

  func unsubscribe(_ sub: Subscriber) {
    lock.lock()
    subscribers.removeAll { $0 === sub }
    lock.unlock()
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return history
  }
}

/// A thin per-server wrapper that tags every event with a fixed `mode`, so the
/// server code can stay mode-agnostic (`hub.emit(connID, phase)`).
final class Emitter {
  private let hub: EventHub
  let mode: String

  init(_ hub: EventHub, _ mode: String) {
    self.hub = hub
    self.mode = mode
  }

  func emit(_ connID: Int, _ phase: String, _ detail: String? = nil) {
    hub.emit(mode: mode, connID: connID, phase: phase, detail: detail)
  }

  func log(_ message: String) {
    hub.emit(mode: mode, connID: 0, phase: "log", detail: message)
  }
}
