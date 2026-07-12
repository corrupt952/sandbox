import Darwin
import Foundation

// MARK: - Blocking handler (shared by blocking-single and thread-per-connection)

/// Synchronously reads a full HTTP request, optionally simulates work, echoes
/// the body (or request line) back, and closes. Blocks the calling thread for
/// the whole connection — that is the point being demonstrated.
func handleBlocking(_ fd: Int32, connID: Int, hub: Emitter, workMs: Int) {
  defer { close(fd) }
  hub.emit(connID, "accepted")

  var inbuf = [UInt8]()
  var tmp = [UInt8](repeating: 0, count: 65536)
  var headerEnd: Int? = nil
  var contentLength = 0
  hub.emit(connID, "read-start")

  while true {
    if headerEnd == nil, let he = indexPastHeaderTerminator(inbuf) {
      headerEnd = he
      contentLength = parseContentLength(String(decoding: inbuf[0..<he], as: UTF8.self))
    }
    if let he = headerEnd, inbuf.count - he >= contentLength { break }

    let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if n <= 0 {
      hub.emit(connID, "closed", "peer closed before request complete")
      return
    }
    inbuf.append(contentsOf: tmp[0..<n])
    hub.emit(connID, "read", "+\(n)B (total \(inbuf.count))")
  }

  if workMs > 0 {
    hub.emit(connID, "work", "sleeping \(workMs)ms (simulated processing)")
    usleep(useconds_t(workMs * 1000))
  }

  let he = headerEnd ?? inbuf.count
  let body = contentLength > 0 ? Array(inbuf[he..<(he + contentLength)]) : []
  let echo = body.isEmpty ? Array(requestFirstLine(inbuf).utf8) : body
  hub.emit(connID, "write", "\(echo.count)B echo")
  _ = writeAll(fd, makeEchoResponse(echo: echo))
  hub.emit(connID, "closed")
}

// MARK: - Model 1: blocking, single thread

func runBlockingSingle(port: UInt16, hub: Emitter, workMs: Int) throws {
  let listenFD = try makeListeningSocket(port: port, nonBlocking: false)
  hub.log("blocking (single thread) echo server on :\(port) — one connection at a time")
  var nextID = 1
  while true {
    let client = accept(listenFD, nil, nil)
    if client < 0 { continue }
    let id = nextID
    nextID += 1
    handleBlocking(client, connID: id, hub: hub, workMs: workMs)
  }
}

// MARK: - Model 2: blocking, one thread per connection

func runThreaded(port: UInt16, hub: Emitter, workMs: Int) throws {
  let listenFD = try makeListeningSocket(port: port, nonBlocking: false)
  hub.log("threaded (one thread per connection) echo server on :\(port)")
  var nextID = 1
  while true {
    let client = accept(listenFD, nil, nil)
    if client < 0 { continue }
    let id = nextID
    nextID += 1
    Thread { handleBlocking(client, connID: id, hub: hub, workMs: workMs) }.start()
  }
}

// MARK: - Model 3: non-blocking, single thread, kqueue event loop

/// Per-connection state for the event loop.
final class Conn {
  let fd: Int32
  let id: Int
  var inbuf = [UInt8]()
  var headerEnd: Int? = nil
  var contentLength = 0
  var responseReady = false
  var outbuf = [UInt8]()
  var outOff = 0
  var wantWrite = false
  init(fd: Int32, id: Int) {
    self.fd = fd
    self.id = id
  }
}

// Disambiguates the C `struct kevent` from the C `kevent()` function of the
// same name (both imported as `kevent`).
private typealias KEvent = kevent

private func addKevent(_ kq: Int32, _ fd: Int32, _ filter: Int32) {
  var kev = KEvent(
    ident: UInt(fd), filter: Int16(filter), flags: UInt16(EV_ADD | EV_ENABLE),
    fflags: 0, data: 0, udata: nil)
  _ = kevent(kq, &kev, 1, nil, 0, nil)
}

private func delKevent(_ kq: Int32, _ fd: Int32, _ filter: Int32) {
  var kev = KEvent(
    ident: UInt(fd), filter: Int16(filter), flags: UInt16(EV_DELETE),
    fflags: 0, data: 0, udata: nil)
  _ = kevent(kq, &kev, 1, nil, 0, nil)
}

private enum FlushResult { case done, again, error }

private func flush(_ conn: Conn) -> FlushResult {
  let count = conn.outbuf.count
  while conn.outOff < count {
    let n = conn.outbuf.withUnsafeBytes { raw -> Int in
      write(conn.fd, raw.baseAddress!.advanced(by: conn.outOff), count - conn.outOff)
    }
    if n > 0 {
      conn.outOff += n
    } else if n < 0 && errno == EAGAIN {
      return .again
    } else {
      return .error
    }
  }
  return .done
}

/// Once enough bytes are buffered, builds the echo response into `outbuf`.
private func tryParse(_ conn: Conn) {
  if conn.headerEnd == nil {
    guard let he = indexPastHeaderTerminator(conn.inbuf) else { return }
    conn.headerEnd = he
    conn.contentLength = parseContentLength(String(decoding: conn.inbuf[0..<he], as: UTF8.self))
  }
  let he = conn.headerEnd!
  guard conn.inbuf.count - he >= conn.contentLength else { return }
  let body = conn.contentLength > 0 ? Array(conn.inbuf[he..<(he + conn.contentLength)]) : []
  let echo = body.isEmpty ? Array(requestFirstLine(conn.inbuf).utf8) : body
  conn.outbuf = makeEchoResponse(echo: echo)
  conn.responseReady = true
}

func runNonBlocking(port: UInt16, hub: Emitter, workMs: Int) throws {
  let listenFD = try makeListeningSocket(port: port, nonBlocking: true)
  let kq = kqueue()
  addKevent(kq, listenFD, EVFILT_READ)
  hub.log("non-blocking (single thread, kqueue) echo server on :\(port)")

  var conns: [Int32: Conn] = [:]
  var nextID = 1
  var evlist = [KEvent](repeating: KEvent(), count: 128)

  func drop(_ conn: Conn) {
    delKevent(kq, conn.fd, EVFILT_READ)
    if conn.wantWrite { delKevent(kq, conn.fd, EVFILT_WRITE) }
    close(conn.fd)
    conns[conn.fd] = nil
  }

  func beginWriting(_ conn: Conn) -> Bool {
    hub.emit(conn.id, "write", "\(conn.outbuf.count)B echo")
    switch flush(conn) {
    case .done:
      hub.emit(conn.id, "closed")
      return false
    case .again:
      conn.wantWrite = true
      delKevent(kq, conn.fd, EVFILT_READ)
      addKevent(kq, conn.fd, EVFILT_WRITE)
      return true
    case .error:
      hub.emit(conn.id, "closed", "write error")
      return false
    }
  }

  while true {
    let n = kevent(kq, nil, 0, &evlist, Int32(evlist.count), nil)
    if n < 0 {
      if errno == EINTR { continue }
      break
    }
    for i in 0..<Int(n) {
      let ev = evlist[i]
      let fd = Int32(ev.ident)
      let filter = Int32(ev.filter)

      if fd == listenFD {
        while true {
          let client = accept(listenFD, nil, nil)
          if client < 0 { break }  // EAGAIN: drained the accept queue
          setNonBlocking(client)
          let conn = Conn(fd: client, id: nextID)
          nextID += 1
          conns[client] = conn
          hub.emit(conn.id, "accepted")
          addKevent(kq, client, EVFILT_READ)
        }
        continue
      }

      guard let conn = conns[fd] else { continue }

      if filter == EVFILT_READ {
        var tmp = [UInt8](repeating: 0, count: 65536)
        var keep = true
        while !conn.responseReady {
          let r = tmp.withUnsafeMutableBytes { read(conn.fd, $0.baseAddress, $0.count) }
          if r == 0 {
            hub.emit(conn.id, "closed", "peer EOF")
            drop(conn)
            keep = false
            break
          }
          if r < 0 {
            if errno == EAGAIN { break }  // no more data for now; keep waiting
            hub.emit(conn.id, "closed", "read error")
            drop(conn)
            keep = false
            break
          }
          if conn.inbuf.isEmpty { hub.emit(conn.id, "read-start") }
          conn.inbuf.append(contentsOf: tmp[0..<r])
          hub.emit(conn.id, "read", "+\(r)B (total \(conn.inbuf.count))")
          tryParse(conn)
        }
        if keep, conn.responseReady {
          // Doing blocking work here stalls the WHOLE event loop — non-blocking
          // IO does not save you from a slow synchronous handler.
          if workMs > 0 {
            hub.emit(conn.id, "work", "sleeping \(workMs)ms (blocks the event loop!)")
            usleep(useconds_t(workMs * 1000))
          }
          if !beginWriting(conn) { drop(conn) }
        }
      } else if filter == EVFILT_WRITE {
        switch flush(conn) {
        case .done:
          hub.emit(conn.id, "closed")
          drop(conn)
        case .again:
          break  // stay registered for EVFILT_WRITE
        case .error:
          hub.emit(conn.id, "closed", "write error")
          drop(conn)
        }
      }
    }
  }
}
