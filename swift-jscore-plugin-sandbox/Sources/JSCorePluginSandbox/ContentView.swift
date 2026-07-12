import SwiftUI

struct ContentView: View {
  @State private var script: String = Self.defaultScript
  @State private var rawJSON: String = Self.defaultRawJSON
  @State private var allowedHosts: String = "api.github.com,api.coingecko.com"
  @State private var allowStateAccess: Bool = true
  @State private var allowAIAccess: Bool = true
  @State private var manifestJSON: String = Self.defaultManifest
  @State private var lastManifestError: String?
  @State private var results: [EvaluationResult] = []
  @State private var isBusy = false
  @State private var tickCount: Int = 0

  // The evaluator survives the widget instance lifetime — created on Load, destroyed on Reset.
  @State private var evaluator: JSEvaluator?

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 8) {
        Text("plugin script").font(.headline)
        Text("must assign globalThis.transform = (raw, ctx) => snapshotValue")
          .font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $script)
          .font(.system(.body, design: .monospaced))
          .border(.gray.opacity(0.3))

        Text("raw input (JSON)").font(.headline)
        TextEditor(text: $rawJSON)
          .font(.system(.body, design: .monospaced))
          .frame(maxHeight: 120)
          .border(.gray.opacity(0.3))

        GroupBox("capability grants (toggle-based; ignored when 'Load from manifest' is used)") {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("host.fetch allowed hosts:")
              TextField("comma-separated", text: $allowedHosts)
                .textFieldStyle(.roundedBorder)
            }
            Toggle("host.state.get / set", isOn: $allowStateAccess)
            Toggle("host.ai.respond (Apple Foundation Models)", isOn: $allowAIAccess)
          }
        }

        GroupBox("plugin manifest (GH Actions–style permissions)") {
          VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $manifestJSON)
              .font(.system(.caption, design: .monospaced))
              .frame(maxHeight: 140)
              .border(.gray.opacity(0.3))
            if let err = lastManifestError {
              Text(err).font(.caption2).foregroundStyle(.red)
            }
          }
        }

        HStack {
          Button(action: loadScript) {
            Label("Load (toggles)", systemImage: "tray.and.arrow.down.fill")
          }
          .disabled(isBusy)
          Button(action: loadScriptFromManifest) {
            Label("Load from manifest", systemImage: "doc.text.fill")
          }
          .disabled(isBusy)
          Button(action: resetEvaluator) {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .disabled(isBusy || evaluator == nil)
        }
        HStack {
          Button(action: tickOnce) {
            Label("tick × 1", systemImage: "play.fill")
          }
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(isBusy || evaluator == nil)
          Button(action: tickHundred) {
            Label("tick × 100", systemImage: "forward.fill")
          }
          .disabled(isBusy || evaluator == nil)
          Button(action: tickThousand) {
            Label("tick × 1000", systemImage: "forward.end.fill")
          }
          .disabled(isBusy || evaluator == nil)
        }
        HStack {
          Button(action: runIsolationTest) {
            Label("Isolation test", systemImage: "lock.shield")
          }
          .disabled(isBusy)
          if isBusy { ProgressView().controlSize(.small) }
          Spacer()
          if evaluator != nil {
            Text("evaluator alive · ticks: \(tickCount)")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Text("no evaluator").font(.caption).foregroundStyle(.secondary)
          }
          Button("clear results") { results.removeAll() }
        }
      }
      .padding()
      .frame(minWidth: 420)

      VStack(alignment: .leading, spacing: 8) {
        Text("results").font(.headline)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(results) { result in
              ResultRow(result: result)
            }
          }
          .padding(8)
        }
        .border(.gray.opacity(0.3))
      }
      .padding()
      .frame(minWidth: 380)
    }
  }

  // MARK: - Actions

  private func loadScript() {
    isBusy = true
    let hostList = Set(
      allowedHosts.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )
    let currentScript = script
    let stateOn = allowStateAccess
    let aiOn = allowAIAccess
    Task {
      let new = JSEvaluator(
        allowedHosts: hostList, statePermission: stateOn, aiPermission: aiOn)
      let result = new.loadScript(currentScript)
      await MainActor.run {
        evaluator = new
        tickCount = 0
        results.insert(result, at: 0)
        isBusy = false
      }
    }
  }

  private func loadScriptFromManifest() {
    isBusy = true
    lastManifestError = nil
    let currentScript = script
    let manifestText = manifestJSON
    Task {
      let result: EvaluationResult
      do {
        let manifest = try JSONDecoder().decode(
          PluginManifest.self, from: Data(manifestText.utf8))
        let perms = manifest.permissions ?? PluginPermissions.denyAll
        let (hosts, stateOn, aiOn) = perms.evaluatorConfig()
        let new = JSEvaluator(
          allowedHosts: hosts, statePermission: stateOn, aiPermission: aiOn)
        let loadResult = new.loadScript(currentScript)
        await MainActor.run {
          evaluator = new
          tickCount = 0
          var summary = loadResult
          let grants = """
            permissions resolved from manifest:
              network.fetch hosts: \(hosts.isEmpty ? "<denied>" : hosts.sorted().joined(separator: ", "))
              state: \(stateOn ? "granted" : "<denied>")
              ai:    \(aiOn ? "granted" : "<denied>")

            \(loadResult.value)
            """
          summary = EvaluationResult(
            timestamp: loadResult.timestamp,
            label: "load (manifest)",
            success: loadResult.success,
            value: grants,
            logs: loadResult.logs,
            elapsedMillis: loadResult.elapsedMillis
          )
          results.insert(summary, at: 0)
          isBusy = false
        }
        return
      } catch {
        result = EvaluationResult(
          timestamp: Date(),
          label: "load (manifest)",
          success: false,
          value: "manifest parse error: \(error.localizedDescription)",
          logs: [],
          elapsedMillis: 0
        )
      }
      await MainActor.run {
        lastManifestError = result.value
        results.insert(result, at: 0)
        isBusy = false
      }
    }
  }

  private func resetEvaluator() {
    evaluator = nil
    tickCount = 0
    results.insert(
      EvaluationResult(
        timestamp: Date(),
        label: "reset",
        success: true,
        value: "evaluator disposed; JSContext + JSVirtualMachine released",
        logs: [],
        elapsedMillis: 0
      ), at: 0)
  }

  private func tickOnce() {
    guard let evaluator else { return }
    isBusy = true
    let raw: Any = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8))) ?? NSNull()
    let n = tickCount + 1
    Task {
      let result = evaluator.tick(raw: raw, tickNumber: n)
      await MainActor.run {
        tickCount = n
        results.insert(result, at: 0)
        isBusy = false
      }
    }
  }

  private func tickHundred() { tickMany(100) }
  private func tickThousand() { tickMany(1000) }

  private func tickMany(_ count: Int) {
    guard let evaluator else { return }
    isBusy = true
    let raw: Any = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8))) ?? NSNull()
    let start = tickCount + 1
    Task {
      let result = evaluator.tickMany(raw: raw, count: count, startTick: start)
      await MainActor.run {
        tickCount += count
        results.insert(result, at: 0)
        isBusy = false
      }
    }
  }

  private func runIsolationTest() {
    isBusy = true
    Task {
      let result = IsolationDemo.run()
      await MainActor.run {
        results.insert(result, at: 0)
        isBusy = false
      }
    }
  }

  // MARK: - Defaults

  private static let defaultScript = """
    // Plugin contract: assign globalThis.transform = (raw, ctx) => snapshotValue
    //   raw  — JSON payload from data source
    //   ctx  — { now, locale, tickNumber } injected by host on each tick
    //   host — { log, now, locale, fetch (gated), state (gated), ai (gated) }
    //
    // The function body runs on every tick; the script-level code (this comment + the
    // assignment) is parsed only once at Load time.

    globalThis.transform = (raw, ctx) => {
      // host.state persists across ticks within one evaluator
      const seen = (host.state.get("seen") ?? 0) + 1;
      host.state.set("seen", seen);
      host.log("tick " + ctx.tickNumber + " seen=" + seen);

      const prCount = raw.total_count ?? 0;
      let tone = "neutral";
      if (prCount >= 20) tone = "danger";
      else if (prCount >= 10) tone = "warning";

      // host.ai is only available when the capability is granted AND the OS supports
      // Foundation Models. We call it only on the first tick to avoid per-tick latency.
      let summary = null;
      if (host.ai && seen === 1) {
        const ai = host.ai.respond(
          "Summarize the open PR count in one short sentence: " + prCount
        );
        summary = ai.text ?? ai.error;
        host.log("ai: " + summary);
      }

      return {
        kind: "scalar",
        value: prCount,
        label: "Open PRs",
        tone: tone,
        seen: seen,
        aiSummary: summary,
        detail: "tick #" + ctx.tickNumber + " at " + new Date(ctx.now * 1000).toISOString()
      };
    };
    """

  private static let defaultRawJSON = """
    {
      "total_count": 14,
      "items": [
        { "title": "feat: add provider scheduler", "state": "open" },
        { "title": "fix: clamp percentage", "state": "open" }
      ]
    }
    """

  private static let defaultManifest = """
    {
      "permissions": {
        "network": {
          "level": "fetch",
          "hosts": ["api.github.com", "api.coingecko.com"]
        },
        "state": "readwrite",
        "ai": "respond",
        "log": "write"
      }
    }
    """
}

private struct ResultRow: View {
  let result: EvaluationResult

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundColor(result.success ? .green : .red)
        Text(result.label).font(.caption.bold())
        Text(result.timestamp.formatted(date: .omitted, time: .standard))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer()
        Text(String(format: "%.3f ms", result.elapsedMillis))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Text(result.value)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.08))
        .cornerRadius(6)
      if !result.logs.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text("host.log").font(.caption2.bold()).foregroundStyle(.secondary)
          ForEach(result.logs, id: \.self) { line in
            Text("• " + line).font(.caption2.monospaced())
          }
        }
        .padding(.leading, 4)
      }
    }
    .padding(8)
    .background(.gray.opacity(0.04))
    .cornerRadius(8)
  }
}
