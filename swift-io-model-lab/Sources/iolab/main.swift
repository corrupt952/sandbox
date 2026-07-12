import Darwin
import Foundation

// Entry point:
//   iolab lab      run all three models at once, one dashboard, self-driven load
//   iolab serve    run a single model + dashboard
//   iolab loadgen  fire configurable clients at a server

// Stream events live even when stdout is redirected to a file/pipe.
setvbuf(stdout, nil, _IONBF, 0)

// Writing to a socket whose peer has already closed raises SIGPIPE, which by
// default kills the process. Ignore it and handle the write error (EPIPE) instead.
signal(SIGPIPE, SIG_IGN)

func parseOptions(_ args: [String]) -> [String: String] {
  var opts: [String: String] = [:]
  var i = 0
  while i < args.count {
    let a = args[i]
    if a.hasPrefix("--") {
      let key = String(a.dropFirst(2))
      if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
        opts[key] = args[i + 1]
        i += 2
      } else {
        opts[key] = "true"
        i += 1
      }
    } else {
      i += 1
    }
  }
  return opts
}

func printUsage() {
  print(
    """
    IO Model Lab — from-scratch echo HTTP servers to compare IO models.

    Usage:
      iolab lab     [--monitor 8081] [--work-ms 120]
                    Runs blocking (:8080), threaded (:8082) and nonblocking
                    (:8084) at once, all feeding ONE dashboard (3 panels on a
                    shared time axis), and drives identical load into all three.
                    Open the dashboard and watch them side by side.

      iolab serve   --mode <blocking|threaded|nonblocking> [--port 8080] [--monitor 8081] [--work-ms 0]
      iolab loadgen [--host 127.0.0.1] [--port 8080] [--clients 8] [--requests 1] [--slow-ms 0] [--body 0]
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
  printUsage()
  exit(1)
}
let options = parseOptions(Array(arguments.dropFirst()))

func intOption(_ key: String, _ fallback: Int) -> Int { Int(options[key] ?? "") ?? fallback }
func portOption(_ key: String, _ fallback: UInt16) -> UInt16 {
  UInt16(options[key] ?? "") ?? fallback
}

switch subcommand {
case "lab":
  let monitorPort = portOption("monitor", 8081)
  let workMs = intOption("work-ms", 120)
  let hub = EventHub()
  startMonitor(
    port: monitorPort, hub: hub,
    serverInfo:
      "3-model comparison · blocking :8080 · threaded :8082 · nonblocking :8084 · work-ms=\(workMs)"
  )

  let servers: [(mode: String, port: UInt16)] = [
    ("blocking", 8080), ("threaded", 8082), ("nonblocking", 8084),
  ]
  for (mode, port) in servers {
    Thread {
      let emitter = Emitter(hub, mode)
      do {
        switch mode {
        case "blocking": try runBlockingSingle(port: port, hub: emitter, workMs: workMs)
        case "threaded": try runThreaded(port: port, hub: emitter, workMs: workMs)
        default: try runNonBlocking(port: port, hub: emitter, workMs: workMs)
        }
      } catch {
        hub.log("\(mode) server failed: \(error)")
      }
    }.start()
  }

  // Self-driving load: give the servers a moment to bind and the browser a
  // moment to connect, then push identical load into all three, in two rounds.
  Thread {
    Thread.sleep(forTimeInterval: 2.5)
    hub.log(
      "round 1 — 6 fast clients into each model (server work serializes blocking & nonblocking)")
    driveConcurrent(ports: servers.map { $0.port }, clients: 6, slowMs: 0, bodyBytes: 8)
    Thread.sleep(forTimeInterval: 2.0)
    hub.log("round 2 — 4 slow clients into each model (non-blocking interleaves the reads)")
    driveConcurrent(ports: servers.map { $0.port }, clients: 4, slowMs: 100, bodyBytes: 48)
    Thread.sleep(forTimeInterval: 2.0)
    hub.log(
      "round 3 — head-of-line: 1 slow sender + 6 fast into each model "
        + "(blocking makes the fast ones wait for the slow read; nonblocking serves them right away)"
    )
    driveHeadOfLine(ports: servers.map { $0.port }, slowMs: 120, slowBody: 240, fastClients: 6)
    hub.log("done — compare the three panels above")
  }.start()

  // Keep the process alive; the servers and monitor run on their own threads.
  while true { Thread.sleep(forTimeInterval: 3600) }

case "serve":
  let mode = options["mode"] ?? "blocking"
  let port = portOption("port", 8080)
  let monitorPort = portOption("monitor", 8081)
  let workMs = intOption("work-ms", 0)
  let hub = EventHub()
  let emitter = Emitter(hub, mode)
  startMonitor(
    port: monitorPort, hub: hub, serverInfo: "mode=\(mode) · server :\(port) · work-ms=\(workMs)")

  do {
    switch mode {
    case "blocking":
      try runBlockingSingle(port: port, hub: emitter, workMs: workMs)
    case "threaded":
      try runThreaded(port: port, hub: emitter, workMs: workMs)
    case "nonblocking":
      try runNonBlocking(port: port, hub: emitter, workMs: workMs)
    default:
      print("unknown mode: \(mode)")
      printUsage()
      exit(1)
    }
  } catch {
    print("server error: \(error)")
    exit(1)
  }

case "loadgen":
  let host = options["host"] ?? "127.0.0.1"
  let port = portOption("port", 8080)
  let clients = intOption("clients", 8)
  let requests = intOption("requests", 1)
  let slowMs = intOption("slow-ms", 0)
  let body = intOption("body", 0)
  runLoadGen(
    host: host, port: port, clients: clients, requests: requests, slowMs: slowMs, bodyBytes: body)

case "-h", "--help", "help":
  printUsage()

default:
  print("unknown subcommand: \(subcommand)")
  printUsage()
  exit(1)
}
