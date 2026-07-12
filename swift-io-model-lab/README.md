# swift-io-model-lab

A from-scratch echo HTTP server in Swift (raw POSIX sockets, no SwiftNIO) that
implements three IO models side by side, plus a **live dashboard** that draws
each connection's lifecycle on a timeline so you can *watch* a blocking server
get stuck. A built-in load generator lets you dial in slow clients, body sizes,
and concurrency to see how each model reacts. It's meant as teaching material,
not a real server.

## The three models

| Mode | How it handles connections |
|------|----------------------------|
| `blocking` | Single thread. `accept()` one connection, handle it fully (read → echo → close), *then* accept the next. One slow client stalls everyone. |
| `threaded` | One thread per connection. Blocking IO, but connections run concurrently. Simple and effective — until thread count explodes. |
| `nonblocking` | Single thread, `kqueue` event loop multiplexing every connection. No thread-per-conn, but a slow *synchronous handler* stalls the whole loop. |

## Quick start (one command → one picture)

```sh
./demo.sh        # or ./demo.sh 200 for heavier per-request work
```

`demo.sh` runs all three models at once (blocking `:8080`, threaded `:8082`,
nonblocking `:8084`), feeds them a **single dashboard with one panel per model
on a shared time axis**, opens it in your browser, and drives identical load
into all three so you compare them side by side in one view. Ctrl-C stops it.

It drives three rounds of load:

- **Round 1 — 6 fast clients, server `--work-ms 120`.** Threaded's work blocks
  line up in a vertical column (concurrent); blocking's staircase down (one at a
  time); nonblocking *also* staircases — a synchronous handler stalls the event
  loop, so non-blocking IO doesn't help here. **Blocking and nonblocking finish
  at about the same time (~6×120ms); only threaded is fast.**
- **Round 2 — 4 slow clients (dribbled sends).** Now nonblocking interleaves the
  reads across connections while blocking reads one connection to completion
  before the next.
- **Round 3 — head-of-line: 1 slow sender + 6 fast clients.** This is where
  blocking and nonblocking finally diverge on *completion time*: blocking's
  single thread is stuck in `read()` on the slow sender, so the 6 fast clients
  can't even be accepted until it finishes (their bars jump ~2.5s to the right).
  Nonblocking (and threaded) serve the fast clients immediately.

> **The surprising takeaway:** blocking ≈ nonblocking on completion time in most
> cases. Non-blocking IO's win is *not* faster completion — a synchronous handler
> stalls its single thread just like blocking (round 1). What non-blocking buys
> you is (a) handling many connections on one thread without a thread each, and
> (b) not letting one IO-bound connection block the *progress* of others
> (round 3). Reducing the completion time of CPU/`sleep` work needs real
> concurrency — that's what threaded shows.

## Manual run

The `lab` command (what `demo.sh` uses) runs all three models under one
dashboard and self-drives load:

```sh
swift build
.build/debug/iolab lab --work-ms 120
# open http://127.0.0.1:8081
```

Or drive a single model yourself and fire your own load:

```sh
# 1) start one model — it also serves the dashboard
.build/debug/iolab serve --mode blocking --port 8080 --monitor 8081

# 2) open the dashboard
open http://127.0.0.1:8081

# 3) in another terminal, fire clients
.build/debug/iolab loadgen --clients 6 --slow-ms 80 --body 48
```

Each connection is a row, time runs left→right, colored by phase (accepted /
reading / working / writing / closed). Blocking draws a staircase (one at a
time); non-blocking draws overlapping bars.

## Recommended patterns to visualize

Run each against all three `--mode`s and compare the dashboard:

| Goal | Server | loadgen |
|------|--------|---------|
| **IO multiplexing** — blocking staircase vs non-blocking interleave | `serve --mode <m>` | `loadgen --clients 6 --slow-ms 80 --body 48` |
| **Head-of-line blocking** — fast clients stuck behind one slow client | `serve --mode <m>` | `loadgen --clients 1 --slow-ms 200 --body 400 &` then `loadgen --clients 5 --body 16` |
| **Synchronous work stalls the loop** — blocking *and* non-blocking serialize, only threaded stays parallel | `serve --mode <m> --work-ms 150` | `loadgen --clients 6` |
| **Buffering / large bodies** | `serve --mode <m>` | `loadgen --clients 4 --body 200000` |

`demo.sh` runs the first three back to back.

### serve flags

- `--mode blocking|threaded|nonblocking`
- `--port` (default 8080) — echo server
- `--monitor` (default 8081) — dashboard + SSE stream
- `--work-ms` (default 0) — simulated synchronous per-request processing time

### loadgen flags

- `--host` (default 127.0.0.1), `--port` (default 8080)
- `--clients` (default 8) — concurrent clients
- `--requests` (default 1) — requests per client
- `--slow-ms` (default 0) — pause between 16-byte chunks (a slow client / mini slowloris)
- `--body` (default 0) — request body size in bytes (exercises buffering)

## What the experiment shows

Two knobs tell two halves of the story. These numbers were measured on this
machine (`swift build` debug):

**1. Synchronous work serializes both blocking *and* non-blocking.**
Server started with `--work-ms 150`, then `loadgen --clients 6`:

| Mode | wall clock |
|------|-----------|
| `blocking` | ~925 ms (6 × 150 ms, strictly serial) |
| `threaded` | ~154 ms (all six concurrent) |
| `nonblocking` | ~927 ms (**the sleep blocks the event loop** — non-blocking IO does *not* save you from a slow synchronous handler) |

**2. Pure IO waiting is where non-blocking wins.**
Slow clients (`--slow-ms 80`), no server work — the order of `read` events
(connection id sequence) on the server:

```
blocking     : #1 #1 #1 #1 #1 #1 #2 #3      # conn #1 read to completion before #2/#3 are even accepted
nonblocking  : #1 #2 #3 #1 #2 #3 #1 #2 #3   # all three connections read, interleaved, in one event loop
```

Takeaways:

- Thread-per-connection is the simplest way to get concurrency, at the cost of a
  thread (and its stack) per connection.
- A `kqueue`/`epoll` event loop multiplexes many connections on one thread — but
  only for the *IO waiting*. Any blocking CPU or `sleep` in the handler freezes
  every connection. (In a real server you'd hand such work to a thread pool.)
- The dashboard runs on its own threads and a non-blocking-independent path, so
  it stays responsive even while the blocking demo server is stuck — which is
  itself a small lesson in keeping your control plane off the blocked path.

## Implementation notes

- `Sockets.swift` — POSIX socket/accept/connect/write helpers.
- `Http.swift` — minimal request parsing (header terminator, Content-Length) and
  echo response building.
- `Events.swift` — `EventHub` fan-out: servers emit lifecycle events, the SSE
  monitor's clients subscribe, everything is mirrored to stdout.
- `Servers.swift` — the three models, including the `kqueue` event loop.
- `Monitor.swift` / `Dashboard.swift` — the SSE server and the self-contained
  dashboard page (SVG timeline via `EventSource`).
- `LoadGen.swift` — the client generator.
