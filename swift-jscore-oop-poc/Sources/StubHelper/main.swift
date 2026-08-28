import Darwin
import Foundation
import PluginIPC

// Same first statement as the real helper, for the same reason.
let tMain = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

// The helper with JavaScriptCore taken out and nothing else changed: same transport,
// same `ready` frame, same clock readings. Comparing its launch against the real
// one is what says whether linking JSC costs anything at startup — and it answers
// that without writing the dlopen version, which would mean giving up the Swift
// JavaScriptCore types for the C API throughout.
let channel = FrameChannel(fd: 3)

try? channel.send([
  "op": "ready", "pid": Int(getpid()),
  "tMain": Int(tMain), "tVM": Int(tMain),
  "tReady": Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
])

while true {
  let envelope: FrameChannel.Envelope
  do {
    envelope = try channel.receive()
  } catch {
    exit(0)
  }
  let id = envelope.body["id"] as? Int ?? 0
  if envelope.body["op"] as? String == "shutdown" {
    try? channel.send(["id": id, "op": "result", "ok": true])
    exit(0)
  }
  // Nothing else is implemented on purpose. This target exists to be launched and
  // to say when it got there, not to run plugins.
  try? channel.send(["id": id, "op": "result", "ok": false, "error": "stub helper"])
}
