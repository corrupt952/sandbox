import AppKit
import KanaKanjiCore
import SwiftUI

@main
struct KKCLabApp: App {
  @StateObject private var session: InputSession

  init() {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    _session = StateObject(
      wrappedValue: InputSession(
        dataDirectory: cwd.appendingPathComponent("dict/build"),
        modeDirectory: cwd.appendingPathComponent("dict/mode"),
        userDictionaryURL: cwd.appendingPathComponent("dict/user.txt"),
        learningURL: cwd.appendingPathComponent("dict/learned.tsv"),
        segmentationURL: cwd.appendingPathComponent("dict/segmentations.tsv")))

    // Launched from the terminal there is no bundle, so the app has to ask for
    // a dock presence and keyboard focus itself.
    NSApplication.shared.setActivationPolicy(.regular)
    DispatchQueue.main.async {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  var body: some Scene {
    WindowGroup("kkc lab") {
      ContentView(session: session)
        .frame(minWidth: 760, minHeight: 560)
    }
    .windowResizability(.contentMinSize)
  }
}

struct ContentView: View {
  @ObservedObject var session: InputSession
  @State private var editorFocused = false
  @State private var caretVisible = true
  @State private var newReading = ""
  @State private var newSurface = ""

  private let caretTimer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 0) {
      editor
      Divider()
      inspector.frame(width: 260)
    }
  }

  // MARK: - Editor

  private var editor: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(
          "Romaji in. Space converts · ↑↓ candidates · ←→ segments · ⇧←→ resize · "
            + "1-9 picks · Enter commits · Esc cancels · ⌃Delete forgets"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Text(editorFocused ? "focused" : "click the box to type")
          .font(.caption2)
          .foregroundStyle(editorFocused ? Color.secondary : Color.orange)
      }

      textBox

      candidateList

      Spacer(minLength: 0)

      HStack {
        Button("Clear text") { session.clearCommitted() }
        Spacer()
        Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(16)
  }

  private var textBox: some View {
    ScrollView {
      composition
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
    }
    .frame(minHeight: 120)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          editorFocused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25),
          lineWidth: editorFocused ? 2 : 1)
    )
    .background(
      KeyCatcher(isFocused: $editorFocused) { event in session.handle(event) }
    )
    .onReceive(caretTimer) { _ in caretVisible.toggle() }
  }

  /// Committed text, then the composition.
  ///
  /// While converting, each segment is drawn separately with the active one
  /// filled in — the boundary is the thing being decided, so it has to be
  /// visible before ←→ and Shift+←→ mean anything.
  @ViewBuilder
  private var composition: some View {
    let caret = editorFocused && caretVisible ? "|" : "\u{2007}"
    if session.isSelecting, !session.composition.isEmpty {
      // One concatenated Text, not a stack of them. A stack lays out on a
      // single line and the committed paragraph wraps underneath it, which
      // puts the segment being converted in the middle of the text instead of
      // at the end. Segments have to be part of the same flow as everything
      // before them.
      session.composition.segments.enumerated().reduce(
        Text(session.committed).font(.system(size: 22))
      ) { text, pair in
        let active = pair.offset == session.composition.active
        return text
          + Text(pair.element.surface)
          .font(.system(size: 22))
          .foregroundColor(active ? Color.accentColor : Color.primary)
          .underline(true, color: active ? Color.accentColor : Color.secondary.opacity(0.5))
      }
        + Text(caret).font(.system(size: 22)).foregroundColor(.accentColor)
    } else {
      let preedit = session.kana + session.romajiPending
      Text(session.committed).font(.system(size: 22))
        + Text(preedit).font(.system(size: 22)).underline().foregroundColor(.accentColor)
        + Text(caret).font(.system(size: 22)).foregroundColor(.accentColor)
    }
  }

  private var candidateList: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Candidates").font(.caption).bold()
        if session.isSelecting, !session.composition.isEmpty {
          Text(
            "segment \(session.composition.active + 1)/\(session.composition.segments.count)  "
              + session.composition.segments[session.composition.active].reading
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(session.candidates.count) in \(session.lastLookupMicroseconds) µs")
          .font(.caption).foregroundStyle(.secondary)
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(session.candidates.enumerated()), id: \.element.id) { rank, candidate in
            row(rank: rank, candidate: candidate)
          }
        }
      }
      .frame(minHeight: 220)
    }
  }

  private func row(rank: Int, candidate: LayeredIndex.Candidate) -> some View {
    let selected = session.isSelecting && rank == session.selection
    return HStack(spacing: 8) {
      Text(rank < 9 ? "\(rank + 1)" : " ")
        .font(.system(.caption, design: .monospaced))
        .frame(width: 14, alignment: .trailing)
        .foregroundStyle(.secondary)
      Text(candidate.surface)
        .font(.system(size: 16))
      Text(candidate.reading)
        .font(.caption)
        .foregroundStyle(.secondary)
      if !candidate.isExact {
        Text("predicted").font(.caption2).foregroundStyle(.tertiary)
      }
      Spacer()
      Text(candidate.layerName)
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color(for: candidate.priority).opacity(0.25), in: Capsule())
      Text("\(candidate.cost)")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 44, alignment: .trailing)
    }
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(
      selected ? Color.accentColor.opacity(0.25) : .clear,
      in: RoundedRectangle(cornerRadius: 4))
  }

  private func color(for priority: LayeredIndex.Priority) -> Color {
    switch priority {
    case .user: return .green
    case .learned: return .blue
    case .mode: return .orange
    case .baseline: return .gray
    }
  }

  // MARK: - Inspector

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Layers").font(.caption).bold()
      ForEach(session.layerSummary, id: \.name) { layer in
        HStack {
          Circle().fill(color(for: layer.priority)).frame(width: 8, height: 8)
          Text(layer.name).font(.caption)
          Spacer()
          Text("\(layer.readings)").font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      Text("Order is absolute: user beats learned beats mode beats baseline, whatever costs say.")
        .font(.caption2).foregroundStyle(.secondary)

      Divider()

      Toggle("Learn on commit", isOn: $session.learnOnCommit).font(.caption)
      Toggle("Prediction", isOn: $session.predictionEnabled).font(.caption)

      Divider()

      Text("Learned").font(.caption).bold()
      Text(
        "\(session.learnedEntries) words, \(session.rememberedSegmentations) segmentations"
      )
      .font(.caption2).foregroundStyle(.secondary)
      Text("halving every 32 days")
        .font(.caption2).foregroundStyle(.tertiary)

      Divider()

      Text("User dictionary").font(.caption).bold()
      Text("\(session.userDictionaryEntries) entries, permanent")
        .font(.caption2).foregroundStyle(.secondary)
      TextField("reading", text: $newReading).textFieldStyle(.roundedBorder).font(.caption)
      TextField("surface", text: $newSurface).textFieldStyle(.roundedBorder).font(.caption)
      Button("Add to user layer") {
        session.addUserWord(reading: newReading, surface: newSurface)
        newReading = ""
        newSurface = ""
      }
      .font(.caption)
      Button("Forget everything learned") { session.forgetEverything() }
        .font(.caption)
      Text("⌃Delete on a green candidate forgets just that one.")
        .font(.caption2).foregroundStyle(.secondary)
      Text(session.userDictionaryPath)
        .font(.caption2).foregroundStyle(.tertiary).lineLimit(2).truncationMode(.head)

      Spacer()
    }
    .padding(16)
  }

}
