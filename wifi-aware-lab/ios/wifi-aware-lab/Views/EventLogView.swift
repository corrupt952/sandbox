import SwiftUI
import UIKit

struct EventLogView: View {
  // MARK: - Properties

  let logs: [String]
  let onClear: () -> Void

  var body: some View {
    List {
      // Newest first: the log grows downward, but the interesting line is always the last one.
      ForEach(Array(logs.enumerated().reversed()), id: \.offset) { _, line in
        Text(line)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
      }
    }
    .listStyle(.plain)
    .navigationTitle(String(localized: "eventLog.title", defaultValue: "Event Log"))
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if logs.isEmpty {
        ContentUnavailableView(
          String(localized: "eventLog.empty.title", defaultValue: "No Events"),
          systemImage: "list.bullet.rectangle"
        )
      }
    }
    .toolbar {
      ToolbarItem(placement: .bottomBar) {
        Button(String(localized: "eventLog.action.copy", defaultValue: "Copy")) {
          UIPasteboard.general.string = logs.joined(separator: "\n")
        }
        .disabled(logs.isEmpty)
      }

      ToolbarSpacer(.flexible, placement: .bottomBar)

      ToolbarItem(placement: .bottomBar) {
        Button(
          String(localized: "eventLog.action.clear", defaultValue: "Clear"),
          role: .destructive,
          action: onClear
        )
        .disabled(logs.isEmpty)
      }
    }
  }
}

#Preview("With events") {
  NavigationStack {
    EventLogView(
      logs: [
        "09:38:40.615  Session 8F3A2C1D started",
        "09:38:41.002  Publisher is listening",
        "09:40:58.203  Connection added [3F2A11C0] Incoming (1/5)",
        "09:40:58.771  Connection [3F2A11C0] → Ready",
        "09:41:02.318  RTT [3F2A11C0] 13.75 ms",
      ],
      onClear: {}
    )
  }
}

#Preview("Empty") {
  NavigationStack {
    EventLogView(logs: [], onClear: {})
  }
}
