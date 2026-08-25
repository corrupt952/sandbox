import SwiftUI
import WorkspaceLayoutCore

struct ToolPanelView: View {
  let tool: ToolKind
  let workspaceName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: tool.symbolName)
          .foregroundStyle(.secondary)
        Text(tool.title)
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Image(systemName: "ellipsis")
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .frame(height: 44)

      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)

      switch tool {
      case .project:
        OutlineRows(workspaceName: workspaceName)
      case .search:
        SearchPlaceholder()
      case .run:
        EmptyToolState(symbol: "play.circle", title: "Nothing running")
      case .changes:
        EmptyToolState(symbol: "arrow.trianglehead.branch", title: "No changes")
      case .history:
        HistoryRows()
      case .preview:
        EmptyToolState(symbol: "eye", title: "Preview")
      }
    }
    .background(Color(red: 0.082, green: 0.086, blue: 0.092))
  }
}

private struct OutlineRows: View {
  let workspaceName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(workspaceName, systemImage: "chevron.down")
        .font(.system(size: 12, weight: .medium))
      Label("Sources", systemImage: "folder.fill")
        .padding(.leading, 18)
      Label("Tests", systemImage: "folder.fill")
        .padding(.leading, 18)
      Label("README.md", systemImage: "doc.text")
        .padding(.leading, 18)
      Spacer()
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .padding(14)
  }
}

private struct SearchPlaceholder: View {
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Image(systemName: "magnifyingglass")
        Text("Search workspace")
        Spacer()
      }
      .font(.system(size: 12))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
      Spacer()
    }
    .padding(12)
  }
}

private struct HistoryRows: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Opened workspace", systemImage: "circle.fill")
      Label("Changed layout", systemImage: "circle.fill")
      Label("Created split", systemImage: "circle.fill")
      Spacer()
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .padding(16)
  }
}

private struct EmptyToolState: View {
  let symbol: String
  let title: String

  var body: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: symbol)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }
}
