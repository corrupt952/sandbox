import Darwin
import Foundation

/// Starts the dashboard/monitor HTTP server on a background thread. It serves
/// the dashboard page at `/` and a live SSE stream at `/events`. It runs
/// independently of the demo server (its own threads), so it stays responsive
/// even while a blocking demo server is stuck on a slow client.
func startMonitor(port: UInt16, hub: EventHub, serverInfo: String) {
  Thread {
    do {
      let listenFD = try makeListeningSocket(port: port, nonBlocking: false)
      hub.log("dashboard on http://127.0.0.1:\(port)  (open it in a browser)")
      while true {
        let client = accept(listenFD, nil, nil)
        if client < 0 { continue }
        Thread { serveMonitorClient(client, hub: hub, serverInfo: serverInfo) }.start()
      }
    } catch {
      hub.log("monitor failed to start: \(error)")
    }
  }.start()
}

private func serveMonitorClient(_ fd: Int32, hub: EventHub, serverInfo: String) {
  var tmp = [UInt8](repeating: 0, count: 4096)
  let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
  guard n > 0 else {
    close(fd)
    return
  }
  let path = requestPath(String(decoding: tmp[0..<n], as: UTF8.self))

  if path.hasPrefix("/events") {
    streamEvents(fd, hub: hub)
  } else {
    let html = dashboardHTML(serverInfo: serverInfo)
    let body = Array(html.utf8)
    let head =
      "HTTP/1.1 200 OK\r\n"
      + "Content-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Connection: close\r\n\r\n"
    var out = Array(head.utf8)
    out.append(contentsOf: body)
    _ = writeAll(fd, out)
    close(fd)
  }
}

private func streamEvents(_ fd: Int32, hub: EventHub) {
  let head =
    "HTTP/1.1 200 OK\r\n"
    + "Content-Type: text/event-stream\r\n"
    + "Cache-Control: no-cache\r\n"
    + "Connection: keep-alive\r\n"
    + "Access-Control-Allow-Origin: *\r\n\r\n"
  guard writeAll(fd, head) else {
    close(fd)
    return
  }

  let sub = hub.subscribe()
  defer {
    hub.unsubscribe(sub)
    close(fd)
  }

  // Replay recent history so a freshly opened dashboard shows prior activity.
  for line in hub.snapshot() {
    if !writeAll(fd, "data: \(line)\n\n") { return }
  }

  while true {
    sub.lock.lock()
    while sub.queue.isEmpty { sub.lock.wait() }
    let batch = sub.queue
    sub.queue.removeAll()
    sub.lock.unlock()
    for line in batch {
      if !writeAll(fd, "data: \(line)\n\n") { return }
    }
  }
}
