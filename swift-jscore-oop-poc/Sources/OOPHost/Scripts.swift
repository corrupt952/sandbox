import Foundation

/// The plugin entry point stays the narrow one the in-process POC established:
/// `globalThis.transform = (raw, ctx) => result`.
enum Scripts {
  static let summarize = """
    globalThis.transform = (raw, ctx) => {
      const tabs = raw.tabs || [];
      let active = null;
      let dirty = 0;
      for (const t of tabs) {
        if (t.active) active = t.title;
        if (t.dirty) dirty += 1;
      }
      return { count: tabs.length, active, dirty, tick: ctx.tickNumber };
    };
    """

  /// `summarize` plus exactly one reverse capability call, so the difference between
  /// the two is the cost of that call.
  static let summarizeWithFetch = """
    globalThis.transform = (raw, ctx) => {
      const tabs = raw.tabs || [];
      const res = host.fetch("https://api.example.com/status");
      return { count: tabs.length, status: res && res.status, tick: ctx.tickNumber };
    };
    """

  /// Integer arithmetic with `| 0` rather than a float modulo. `%` on doubles lands
  /// in fmod, which costs about the same whether or not the surrounding loop was
  /// compiled, and that alone is enough to make the benchmark blind to JIT.
  static func compute(iterations: Int) -> String {
    """
    globalThis.transform = (raw, ctx) => {
      let acc = 0;
      for (let i = 0; i < \(iterations); i++) {
        acc = (acc + i * 3) | 0;
        acc = (acc ^ (acc << 5)) | 0;
      }
      return acc;
    };
    """
  }

  static let computeHeavy = compute(iterations: 2_000_000)

  /// Per-call time is the `JSValue.call` bridge and nothing else. Even a few thousand
  /// loop iterations swamp it — at 2e3 the loop is over 90% of the call — so the
  /// bridge cannot be read off a small-loop benchmark.
  static let noop = """
    globalThis.transform = (raw, ctx) => 0;
    """

  /// The case the whole design exists for.
  static let hang = """
    globalThis.transform = (raw, ctx) => { while (true) {} };
    """

  /// `fill` matters: an untouched Uint8Array would not be resident, and the point is
  /// to see the pages land on the helper's footprint.
  static func allocate(mb: Int) -> String {
    """
    globalThis.transform = (raw, ctx) => {
      globalThis.__blob = new Uint8Array(\(mb) * 1024 * 1024);
      globalThis.__blob.fill(7);
      return { bytes: globalThis.__blob.length };
    };
    """
  }

  static func snapshot(tabs count: Int = 50) -> [String: Any] {
    var tabs: [[String: Any]] = []
    tabs.reserveCapacity(count)
    for i in 0..<count {
      tabs.append([
        "id": "tab-\(i)",
        "title": "workspace \(i) — src/module\(i)/index.ts",
        "cwd": "/Users/example/Workspace/project-\(i % 7)",
        "active": i == 3,
        "dirty": i % 5 == 0,
        "pid": 40000 + i,
      ])
    }
    return ["tabs": tabs, "generatedAt": Date().timeIntervalSince1970]
  }
}
