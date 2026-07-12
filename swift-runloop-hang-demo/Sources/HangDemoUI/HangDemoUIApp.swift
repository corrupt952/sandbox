import SwiftUI

// dispatchMain 版と RunLoop 版の HangDemoCore を子プロセスとして走らせ、
// 出力と生死判定をウィンドウで見比べるビューア。

@main
struct HangDemoUIApp: App {
  init() {
    // `swift run` から起動してもウィンドウが前面に出るようにする
    DispatchQueue.main.async {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 900, minHeight: 560)
    }
  }
}

enum DemoState: Equatable {
  case idle
  case running
  case alive
  case hang

  var label: String {
    switch self {
    case .idle: return "未実行"
    case .running: return "実行中…"
    case .alive: return "✅ ALIVE"
    case .hang: return "❌ HANG"
    }
  }

  var color: Color {
    switch self {
    case .idle: return .secondary
    case .running: return .blue
    case .alive: return .green
    case .hang: return .red
    }
  }
}

@MainActor
final class DemoRunner: ObservableObject {
  @Published var output = ""
  @Published var state = DemoState.idle

  let title: String
  let usesRunLoop: Bool
  private var process: Process?

  init(title: String, usesRunLoop: Bool) {
    self.title = title
    self.usesRunLoop = usesRunLoop
  }

  func run() {
    guard state != .running else { return }
    output = ""
    state = .running

    let coreURL = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent()
      .appendingPathComponent("HangDemoCore")

    let process = Process()
    process.executableURL = coreURL
    process.arguments = usesRunLoop ? ["--runloop"] : []

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async {
        self?.output += text
      }
    }

    process.terminationHandler = { [weak self] finished in
      DispatchQueue.main.async {
        pipe.fileHandleForReading.readabilityHandler = nil
        self?.state = finished.terminationStatus == 0 ? .alive : .hang
      }
    }

    do {
      try process.run()
      self.process = process
    } catch {
      output = "起動に失敗: \(error.localizedDescription)\nHangDemoCore が \(coreURL.path) に見つかるか確認してください"
      state = .idle
    }
  }
}

struct ContentView: View {
  @StateObject private var dispatchMainRunner = DemoRunner(
    title: "dispatchMain()", usesRunLoop: false)
  @StateObject private var runLoopRunner = DemoRunner(
    title: "RunLoop.main.run()", usesRunLoop: true)

  var body: some View {
    VStack(spacing: 12) {
      Text("main queue デッドロック再現デモ")
        .font(.title2)
        .fontWeight(.bold)

      Text(
        "どちらも同じ処理。+2.0s に EventKit 風の通知配送が main queue に到着した後、ハートビートが止まるかどうかを見比べてください。"
      )
      .font(.caption)
      .foregroundColor(.secondary)

      Button("両方実行") {
        dispatchMainRunner.run()
        runLoopRunner.run()
      }
      .keyboardShortcut(.defaultAction)

      HStack(spacing: 12) {
        DemoPane(runner: dispatchMainRunner)
        DemoPane(runner: runLoopRunner)
      }
    }
    .padding(16)
  }
}

struct DemoPane: View {
  @ObservedObject var runner: DemoRunner

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(runner.title)
          .font(.headline)
        Spacer()
        Text(runner.state.label)
          .font(.caption)
          .fontWeight(.semibold)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(runner.state.color.opacity(0.15))
          .foregroundColor(runner.state.color)
          .clipShape(Capsule())
        Button("実行") {
          runner.run()
        }
        .disabled(runner.state == .running)
      }

      ScrollViewReader { proxy in
        ScrollView {
          Text(runner.output.isEmpty ? "(未実行)" : runner.output)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .id("bottom")
        }
        .onChange(of: runner.output) {
          proxy.scrollTo("bottom", anchor: .bottom)
        }
      }
      .padding(8)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(runner.state.color.opacity(0.4), lineWidth: 1)
      )
    }
  }
}
