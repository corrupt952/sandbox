import SwiftUI
import WorkspaceLayoutCore

struct WorkspaceRootView: View {
  @ObservedObject var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceBar(store: store)
      Rectangle()
        .fill(Color.white.opacity(0.08))
        .frame(height: 1)
      WorkspaceShellView(workspace: store.selectedWorkspace)
        .id(store.selectedWorkspaceID)
    }
    .background(Color(red: 0.055, green: 0.058, blue: 0.062))
  }
}

private struct WorkspaceBar: View {
  @ObservedObject var store: WorkspaceStore

  var body: some View {
    HStack(spacing: 8) {
      Color.clear.frame(width: 74, height: 1)

      Image(systemName: "square.grid.2x2")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)

      Text("Layout Lab")
        .font(.system(size: 14, weight: .semibold))

      Rectangle()
        .fill(Color.white.opacity(0.12))
        .frame(width: 1, height: 20)
        .padding(.horizontal, 4)

      ForEach(store.workspaces) { workspace in
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            store.selectedWorkspaceID = workspace.id
          }
        } label: {
          HStack(spacing: 6) {
            Circle()
              .fill(workspace.id == store.selectedWorkspaceID ? Color.accentColor : Color.secondary)
              .frame(width: 6, height: 6)
            Text(workspace.name)
          }
          .font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 10)
          .frame(height: 28)
          .background(
            RoundedRectangle(cornerRadius: 7)
              .fill(
                workspace.id == store.selectedWorkspaceID
                  ? Color.white.opacity(0.10) : Color.clear
              )
          )
        }
        .buttonStyle(.plain)
      }

      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          _ = store.addWorkspace()
        }
      } label: {
        Image(systemName: "plus")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Add workspace")

      Spacer()

      Text("Each workspace owns its layout")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.trailing, 14)
    }
    .frame(height: 44)
    .background(Color.black.opacity(0.24))
  }
}

private struct WorkspaceShellView: View {
  @ObservedObject var workspace: WorkspaceModel

  var body: some View {
    HStack(spacing: 0) {
      RailView(workspace: workspace, side: .left)

      if let tool = workspace.leftRail.openTool {
        ToolPanelView(tool: tool, workspaceName: workspace.name)
          .frame(width: workspace.leftRail.panelWidth)
          .transition(.move(edge: .leading).combined(with: .opacity))
        PanelResizeHandle(workspace: workspace, side: .left)
      }

      LayoutNodeView(workspace: workspace, child: workspace.root)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .background(Color.black.opacity(0.12))

      if let tool = workspace.rightRail.openTool {
        PanelResizeHandle(workspace: workspace, side: .right)
        ToolPanelView(tool: tool, workspaceName: workspace.name)
          .frame(width: workspace.rightRail.panelWidth)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }

      RailView(workspace: workspace, side: .right)
    }
    .animation(.easeInOut(duration: 0.18), value: workspace.leftRail.openTool)
    .animation(.easeInOut(duration: 0.18), value: workspace.rightRail.openTool)
  }
}
