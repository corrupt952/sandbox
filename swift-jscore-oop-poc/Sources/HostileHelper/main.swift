import CPluginIPC
import Darwin
import Foundation
import PluginIPC

// A helper that has been taken over. It receives attack instructions on a proper
// frame — host → hostile is the trusted direction — and then writes whatever raw
// bytes the attack calls for straight to fd 3, underneath FrameChannel, which is the
// only way to send a frame FrameChannel.send would never produce. The point is to
// find out what the host does with input a cooperating helper could not generate.
//
// It also has the ordinary reverse-RPC and descriptor probes, played from an
// attacker's side rather than a bug's: flooding, and trying to widen a passed fd or
// bookmark past what it was granted.

let channel = FrameChannel(fd: 3)

/// Writes bytes to fd 3 with no framing, retrying short writes. This is the whole
/// reason the target exists.
func writeRaw(_ bytes: [UInt8]) {
  bytes.withUnsafeBufferPointer { buf in
    var offset = 0
    while offset < buf.count {
      let n = write(3, buf.baseAddress! + offset, buf.count - offset)
      if n < 0 {
        if errno == EINTR { continue }
        return
      }
      offset += n
    }
  }
}

func lengthPrefix(_ length: UInt32) -> [UInt8] {
  [
    UInt8(truncatingIfNeeded: length >> 24),
    UInt8(truncatingIfNeeded: length >> 16),
    UInt8(truncatingIfNeeded: length >> 8),
    UInt8(truncatingIfNeeded: length),
  ]
}

let maxFrame = 32 * 1024 * 1024

/// Runs one attack named by the host, writing its bytes to fd 3. The kinds mirror
/// the plan's table: malformed prefixes, truncation, oversize and deeply nested
/// payloads, non-UTF-8, and a non-object body.
func attack(kind: String, arg: Int) {
  switch kind {
  case "len-huge":
    // A prefix claiming 4 GiB, then a few bytes. The host must not try to hold it.
    writeRaw(lengthPrefix(0xFFFF_FFFF) + [0x7b, 0x7d])

  case "len-just-over":
    writeRaw(lengthPrefix(UInt32(maxFrame + 1)) + [0x7b, 0x7d])

  case "truncated":
    // Announces N bytes, sends N-10, and keeps the socket open — a frame that never
    // completes, which is what a plugin crashing mid-write leaves behind.
    let body = Array(#"{"op":"result","padding":"aaaaaaaaaaaaaaaaaaaa"}"#.utf8)
    writeRaw(lengthPrefix(UInt32(body.count)) + body.dropLast(10))

  case "huge-json":
    // A valid object right up against the frame cap: a string that fills it.
    let overhead = Array(#"{"op":"result","blob":""}"#.utf8).count
    let fill = [UInt8](repeating: 0x61, count: maxFrame - overhead - 8)
    let body = Array(#"{"op":"result","blob":""#.utf8) + fill + Array(#""}"#.utf8)
    writeRaw(lengthPrefix(UInt32(body.count)) + body)

  case "deep-json":
    // `arg` nested arrays inside a valid frame, to find where JSONSerialization's
    // recursion gives out — and whether it does so by throwing or by crashing.
    let depth = max(1, arg)
    var body = Array(#"{"op":"result","deep":"#.utf8)
    body += [UInt8](repeating: 0x5b, count: depth)  // [
    body += [UInt8](repeating: 0x5d, count: depth)  // ]
    body += Array("}".utf8)
    if body.count <= maxFrame {
      writeRaw(lengthPrefix(UInt32(body.count)) + body)
    }

  case "non-utf8":
    let body: [UInt8] = [0xff, 0xfe, 0xff, 0xfe]
    writeRaw(lengthPrefix(UInt32(body.count)) + body)

  case "not-object":
    let body = Array("[1,2,3]".utf8)
    writeRaw(lengthPrefix(UInt32(body.count)) + body)

  default:
    break
  }
}

/// Fires `count` reverse-RPC calls without waiting for any reply — the flood. Each
/// is a well-formed frame; the hostility is only in the rate and in never reading
/// the answers.
func flood(count: Int) {
  for i in 0..<count {
    try? channel.send(["op": "hostCall", "id": 2_000_000 + i, "method": "fetch", "arg": "x"])
  }
}

try? channel.send(["op": "ready", "pid": Int(getpid())])

while true {
  let envelope: FrameChannel.Envelope
  do {
    envelope = try channel.receive()
  } catch {
    exit(0)
  }
  let body = envelope.body
  let id = body["id"] as? Int ?? 0
  let op = body["op"] as? String ?? ""

  switch op {
  case "attack":
    attack(kind: body["kind"] as? String ?? "", arg: body["arg"] as? Int ?? 0)
  // No reply on the trusted channel: the attack already went out on fd 3 raw. A
  // reply here would just be a second frame the host was not waiting for.
  case "flood":
    flood(count: body["count"] as? Int ?? 0)
  case "noop":
    // The sentinel: proves the channel and the host survived the last attack.
    try? channel.send(["id": id, "op": "result", "ok": true])
  case "shutdown":
    try? channel.send(["id": id, "op": "result", "ok": true])
    exit(0)
  default:
    try? channel.send(["id": id, "op": "result", "ok": false, "error": "unknown op \(op)"])
  }
}
