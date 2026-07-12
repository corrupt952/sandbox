import Darwin
import Foundation

enum SocketError: Error { case failed(String, Int32) }

/// Creates a TCP listening socket bound to `port` on all interfaces.
func makeListeningSocket(port: UInt16, nonBlocking: Bool) throws -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw SocketError.failed("socket", errno) }

  var yes: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr.s_addr = 0  // INADDR_ANY

  let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindResult == 0 else {
    close(fd)
    throw SocketError.failed("bind", errno)
  }
  guard listen(fd, 128) == 0 else {
    close(fd)
    throw SocketError.failed("listen", errno)
  }
  if nonBlocking { setNonBlocking(fd) }
  return fd
}

func setNonBlocking(_ fd: Int32) {
  let flags = fcntl(fd, F_GETFL, 0)
  _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

/// Connects to `host` (dotted IPv4) : `port`, returns the socket fd or nil.
func connectTo(host: String, port: UInt16) -> Int32? {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  let pton = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
  guard pton == 1 else {
    close(fd)
    return nil
  }
  let result = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard result == 0 else {
    close(fd)
    return nil
  }
  return fd
}

/// Writes every byte of `bytes`, looping over partial writes. Blocking fd only.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
  let count = bytes.count
  return bytes.withUnsafeBytes { raw -> Bool in
    guard let base = raw.baseAddress else { return true }
    var off = 0
    while off < count {
      let n = write(fd, base + off, count - off)
      if n <= 0 { return false }
      off += n
    }
    return true
  }
}

func writeAll(_ fd: Int32, _ string: String) -> Bool {
  return writeAll(fd, Array(string.utf8))
}
