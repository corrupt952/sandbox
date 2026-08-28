import CPluginIPC
import Darwin
import Foundation

/// Errors surfaced by the transport. `timeout` is the one the host acts on: it is
/// how a hung plugin becomes visible, since a stuck script never writes a reply.
public enum IPCError: Error, CustomStringConvertible {
  case eof
  case timeout
  case io(Int32)
  case malformed(String)
  case oversize(Int)

  public var description: String {
    switch self {
    case .eof: return "peer closed the socket"
    case .timeout: return "deadline expired"
    case .io(let code): return "io error \(code) (\(String(cString: strerror(code))))"
    case .malformed(let why): return "malformed frame: \(why)"
    case .oversize(let n): return "frame too large: \(n) bytes"
    }
  }
}

/// Length-prefixed JSON over one AF_UNIX SOCK_STREAM descriptor.
///
/// Reads go through `recvmsg` unconditionally so an SCM_RIGHTS descriptor attached
/// to any send is never dropped — on a stream socket the ancillary data rides along
/// with whichever byte it was sent with, so the reader has to be prepared for it on
/// every read rather than only when it expects one.
public final class FrameChannel {
  public let fd: Int32
  private var inbox = [UInt8]()
  private var pendingFDs = [Int32]()

  public init(fd: Int32) {
    self.fd = fd
  }

  public func close() {
    Darwin.close(fd)
  }

  // MARK: - Sending

  /// When `attachingFD` is >= 0 the descriptor rides on the first `sendmsg` of the frame.
  public func send(_ object: [String: Any], attachingFD: Int32 = -1) throws {
    let payload = try JSONSerialization.data(withJSONObject: object, options: [])
    guard payload.count <= Self.maxFrame else { throw IPCError.oversize(payload.count) }

    var frame = [UInt8]()
    frame.reserveCapacity(payload.count + 4)
    let length = UInt32(payload.count)
    frame.append(UInt8(truncatingIfNeeded: length >> 24))
    frame.append(UInt8(truncatingIfNeeded: length >> 16))
    frame.append(UInt8(truncatingIfNeeded: length >> 8))
    frame.append(UInt8(truncatingIfNeeded: length))
    frame.append(contentsOf: payload)

    var offset = 0
    var attach = attachingFD
    try frame.withUnsafeBufferPointer { buffer in
      let base = buffer.baseAddress!
      while offset < frame.count {
        let sent = ipc_send(fd, base + offset, frame.count - offset, attach)
        if sent < 0 {
          if errno == EINTR { continue }
          throw IPCError.io(errno)
        }
        offset += sent
        attach = -1
      }
    }
  }

  // MARK: - Receiving

  /// A `nil` deadline waits indefinitely.
  public func receive(deadline: ContinuousClock.Instant? = nil) throws -> Envelope {
    while true {
      if let frame = try takeFrame() { return frame }
      try fill(deadline: deadline)
    }
  }

  public struct Envelope {
    public let body: [String: Any]
    /// Already open in this process — the receiver owns it and must close it.
    public let fd: Int32?
  }

  private func takeFrame() throws -> Envelope? {
    guard inbox.count >= 4 else { return nil }
    let length =
      (Int(inbox[0]) << 24) | (Int(inbox[1]) << 16) | (Int(inbox[2]) << 8) | Int(inbox[3])
    guard length <= Self.maxFrame else { throw IPCError.oversize(length) }
    guard inbox.count >= 4 + length else { return nil }

    let payload = Data(inbox[4..<(4 + length)])
    inbox.removeFirst(4 + length)

    guard let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
      throw IPCError.malformed("payload is not a JSON object")
    }
    let fd: Int32? = pendingFDs.isEmpty ? nil : pendingFDs.removeFirst()
    return Envelope(body: body, fd: fd)
  }

  private func fill(deadline: ContinuousClock.Instant?) throws {
    if let deadline {
      let remaining = deadline - ContinuousClock.now
      let millis = Self.millis(remaining)
      if millis <= 0 { throw IPCError.timeout }
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, Int32(min(millis, Double(Int32.max))))
      if ready == 0 { throw IPCError.timeout }
      if ready < 0 {
        if errno == EINTR { return }
        throw IPCError.io(errno)
      }
    }

    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var receivedFD: Int32 = -1
    let count = buffer.withUnsafeMutableBytes { raw in
      ipc_recv(fd, raw.baseAddress, raw.count, &receivedFD)
    }
    if count < 0 {
      if errno == EINTR { return }
      throw IPCError.io(errno)
    }
    if count == 0 { throw IPCError.eof }
    if receivedFD >= 0 { pendingFDs.append(receivedFD) }
    inbox.append(contentsOf: buffer[0..<count])
  }

  // MARK: - Helpers

  private static let maxFrame = 32 * 1024 * 1024

  private static func millis(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
      + Double(duration.components.attoseconds) * 1e-15
  }
}
