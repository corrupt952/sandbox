import Darwin
import Foundation

/// Fires concurrent HTTP clients against the server to make the model
/// differences visible. Clients can send slowly (dribble bytes with a pause
/// between chunks — a "slow client" / mini slowloris) and carry a body of a
/// given size (to exercise buffering).
func runLoadGen(
  host: String, port: UInt16, clients: Int, requests: Int, slowMs: Int, bodyBytes: Int
) {
  print(
    "loadgen → \(host):\(port)  clients=\(clients) requests=\(requests) "
      + "slow-ms=\(slowMs) body=\(bodyBytes)B")

  let group = DispatchGroup()
  let lock = NSLock()
  var latencies: [Double] = []
  var failures = 0
  let wallStart = Date()

  for clientIndex in 0..<clients {
    group.enter()
    Thread {
      for _ in 0..<requests {
        let t0 = Date()
        let ok = oneRequest(
          host: host, port: port, slowMs: slowMs, bodyBytes: bodyBytes, clientIndex: clientIndex)
        let ms = Date().timeIntervalSince(t0) * 1000
        lock.lock()
        if ok { latencies.append(ms) } else { failures += 1 }
        lock.unlock()
      }
      group.leave()
    }.start()
  }

  group.wait()
  let wallMs = Date().timeIntervalSince(wallStart) * 1000
  report(latencies: latencies, failures: failures, wallMs: wallMs)
}

/// Fires `clients` identical requests at EACH of `ports` concurrently and waits
/// for all of them. Used by the `lab` command to drive the same load into all
/// three model servers at once, so their dashboard panels are comparable.
func driveConcurrent(ports: [UInt16], clients: Int, slowMs: Int, bodyBytes: Int) {
  let group = DispatchGroup()
  for port in ports {
    for clientIndex in 0..<clients {
      group.enter()
      Thread {
        _ = oneRequest(
          host: "127.0.0.1", port: port, slowMs: slowMs, bodyBytes: bodyBytes,
          clientIndex: clientIndex)
        group.leave()
      }.start()
    }
  }
  group.wait()
}

/// Drives a head-of-line scenario into each port: one slow sender that arrives
/// first, plus `fastClients` fast clients that arrive shortly after. On a
/// blocking server the fast clients are stuck until the slow read completes; on
/// threaded/nonblocking they are served right away.
func driveHeadOfLine(ports: [UInt16], slowMs: Int, slowBody: Int, fastClients: Int) {
  let group = DispatchGroup()
  for port in ports {
    group.enter()
    Thread {
      _ = oneRequest(
        host: "127.0.0.1", port: port, slowMs: slowMs, bodyBytes: slowBody, clientIndex: 0)
      group.leave()
    }.start()
    for clientIndex in 0..<fastClients {
      group.enter()
      Thread {
        // Start just after the slow client so it is accepted first.
        Thread.sleep(forTimeInterval: 0.12)
        _ = oneRequest(
          host: "127.0.0.1", port: port, slowMs: 0, bodyBytes: 8, clientIndex: clientIndex + 1)
        group.leave()
      }.start()
    }
  }
  group.wait()
}

private func oneRequest(
  host: String, port: UInt16, slowMs: Int, bodyBytes: Int, clientIndex: Int
) -> Bool {
  guard let fd = connectTo(host: host, port: port) else { return false }
  defer { close(fd) }

  let body = String(repeating: "x", count: bodyBytes)
  let request =
    "POST /echo HTTP/1.1\r\n"
    + "Host: \(host)\r\n"
    + "X-Client: \(clientIndex)\r\n"
    + "Content-Length: \(bodyBytes)\r\n"
    + "Connection: close\r\n\r\n"
    + body
  let bytes = Array(request.utf8)

  if slowMs <= 0 {
    if !writeAll(fd, bytes) { return false }
  } else {
    // Dribble the request out in small chunks with a pause between them, so the
    // server sits in read() waiting for the rest of a request that trickles in.
    let chunk = 16
    var off = 0
    while off < bytes.count {
      let end = min(off + chunk, bytes.count)
      let n = bytes[off..<end].withUnsafeBytes { raw in
        write(fd, raw.baseAddress, raw.count)
      }
      if n <= 0 { return false }
      off = end
      if off < bytes.count { usleep(useconds_t(slowMs * 1000)) }
    }
  }

  // Read the whole response until the server closes.
  var tmp = [UInt8](repeating: 0, count: 65536)
  while true {
    let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if n <= 0 { break }
  }
  return true
}

private func report(latencies: [Double], failures: Int, wallMs: Double) {
  let sorted = latencies.sorted()
  func pct(_ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int(p / 100 * Double(sorted.count)))
    return sorted[idx]
  }
  print("")
  print("── loadgen summary ──────────────────────────────")
  print(String(format: "  completed : %d   failed: %d", sorted.count, failures))
  print(String(format: "  wall clock: %.1f ms", wallMs))
  if !sorted.isEmpty {
    print(String(format: "  latency min : %.1f ms", sorted.first!))
    print(String(format: "  latency p50 : %.1f ms", pct(50)))
    print(String(format: "  latency p95 : %.1f ms", pct(95)))
    print(String(format: "  latency max : %.1f ms", sorted.last!))
  }
  print("─────────────────────────────────────────────────")
}
