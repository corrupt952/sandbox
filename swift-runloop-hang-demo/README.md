# swift-runloop-hang-demo

Minimal reproduction of a real deadlock: a process that waits with
`dispatchMain()` instead of `RunLoop.main.run()` can have its main queue
deadlock the moment a Foundation notification (e.g. from EventKit) is
delivered to it. This demo reproduces the same stack without EventKit.

## The bug

```
On the main queue (serial), while running:
  someChangeNotification handler
    → NotificationCenter.post (_CFXNotificationPost)
      → NSOperation.waitUntilFinished   ← blocks forever
```

### Mechanism

1. `dispatchMain()` parks the main **thread** forever and has a **worker
   thread** run the main queue's blocks instead. The main **RunLoop** never
   spins.
2. Foundation's notification delivery takes a different path depending on
   whether it's running on the real main thread. On the real main thread,
   delivery is inline. Otherwise, it enqueues an operation on
   `OperationQueue.main` and waits on it with `waitUntilFinished`.
3. Under `dispatchMain()`, main-queue blocks run on a worker thread, so
   `Thread.isMainThread == false` inside the notification handler — which
   takes the waiting path. That queued operation is never picked up: (a) the
   parked main thread/RunLoop isn't spinning to run it, and (b) the serial
   main queue is itself blocked at the front by the handler waiting on it. The
   operation never completes, and **the entire main queue locks up**.
4. `RunLoop.main.run()` runs main-queue blocks on the real main thread, so
   delivery is inline and nothing blocks.

This was discovered in a production macOS MCP daemon: a `NetworkTransport`
that started new connections via `connection.start(queue: .main)` depended on
the main queue staying alive, and the process would deadlock — alive, but
completely unresponsive — the instant an `EKEventStore` change notification
arrived on a `dispatchMain()`-based run loop.

## Usage

### CLI (semi-automatic verdict)

```sh
swift build

# Reproduces the hang (dispatchMain). Exits 1 with ❌ HANG after ~5s.
swift run HangDemoCore

# Same wait style as the fix (RunLoop.main.run()). Exits 0 with ✅ ALIVE after ~5s.
swift run HangDemoCore --runloop
```

Timeline:

| Time | Event |
|---|---|
| +0.5s… | A heartbeat is posted to the main queue every 0.5s (visualizes liveness) |
| +2.0s | An EventKit-like notification is delivered to the main queue |
| +2.5s | Heartbeat count at this point is recorded |
| +4.5s | If the heartbeat advanced, ✅ ALIVE (exit 0); if stalled, ❌ HANG (exit 1) |

### Side-by-side SwiftUI window

```sh
swift run HangDemoUI
```

Press "Run Both" to run the `dispatchMain()` and `RunLoop.main.run()`
versions side by side and watch the log stream and verdict badges
(❌ HANG / ✅ ALIVE) diverge.

What to look for:

- Left (dispatchMain): heartbeats are tagged `worker-thread`. After the
  notification at +2.0s ("waiting on waitUntilFinished… stuck here"), the
  heartbeat stops.
- Right (RunLoop): heartbeats are tagged `main-thread`; the notification is
  delivered inline, and heartbeats keep flowing afterward.

## Sample output

`swift run HangDemoCore` (hanging side):

```
[ +0.0s][main-thread] wait style: dispatchMain() — services main queue only, RunLoop never spins
[ +0.5s][worker-thread] main queue heartbeat #1
...
[ +2.0s][worker-thread] === EventKit-like change notification arrives on the main queue ===
[ +2.0s][worker-thread] delivery context: Thread.isMainThread = false
[ +2.0s][worker-thread] → enqueuing on OperationQueue.main, waiting with waitUntilFinished… stuck here

result: ❌ HANG — main queue has been blocked since the notification (stopped at heartbeat 3)
```

`swift run HangDemoCore --runloop` (healthy side):

```
[ +0.0s][main-thread] wait style: RunLoop.main.run() — services both RunLoop sources and the main queue
[ +0.5s][main-thread] main queue heartbeat #1
...
[ +2.0s][main-thread] === EventKit-like change notification arrives on the main queue ===
[ +2.0s][main-thread] delivery context: Thread.isMainThread = true
[ +2.0s][main-thread] → real main thread, so delivery is inline. No waiting.
[ +2.0s][main-thread] === Notification delivery complete. Main queue is alive ===
[ +2.5s][main-thread] main queue heartbeat #5
...

result: ✅ ALIVE — main queue keeps flowing (heartbeat 4 → 8)
```
