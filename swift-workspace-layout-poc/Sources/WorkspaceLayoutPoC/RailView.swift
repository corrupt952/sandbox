import SwiftUI
import WorkspaceLayoutCore

struct RailView: View {
  @ObservedObject var workspace: WorkspaceModel
  let side: RailSide

  private var rail: RailState { workspace.railState(for: side) }

  var body: some View {
    VStack(spacing: 6) {
      ForEach(rail.tools) { tool in
        RailButton(
          tool: tool,
          isSelected: rail.openTool == tool,
          side: side,
          onPress: { workspace.toggleTool(tool, on: side) },
          onMove: { workspace.moveTool(tool, to: side == .left ? .right : .left) }
        )
      }

      Spacer()

      Image(systemName: "gearshape")
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
        .frame(width: 34, height: 34)
        .padding(.bottom, 4)
    }
    .padding(.top, 8)
    .frame(width: 48)
    .background(Color(red: 0.075, green: 0.078, blue: 0.084))
    .overlay(alignment: side == .left ? .trailing : .leading) {
      Rectangle()
        .fill(Color.white.opacity(0.09))
        .frame(width: 1)
    }
  }
}

private struct RailButton: View {
  let tool: ToolKind
  let isSelected: Bool
  let side: RailSide
  let onPress: () -> Void
  let onMove: () -> Void

  var body: some View {
    Button(action: onPress) {
      Image(systemName: tool.symbolName)
        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(width: 34, height: 34)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
        )
        .overlay(alignment: side == .left ? .leading : .trailing) {
          if isSelected {
            Capsule()
              .fill(Color.accentColor)
              .frame(width: 3, height: 18)
          }
        }
    }
    .buttonStyle(.plain)
    .help(tool.title)
    .contextMenu {
      Button("Move to \(side == .left ? "Right" : "Left") Rail", action: onMove)
    }
  }
}

struct PanelResizeHandle: View {
  @ObservedObject var workspace: WorkspaceModel
  let side: RailSide
  @State private var startWidth: Double?

  var body: some View {
    Rectangle()
      .fill(Color.white.opacity(0.09))
      .frame(width: 4)
      .contentShape(Rectangle())
      .onHover { hovering in
        if hovering {
          NSCursor.resizeLeftRight.push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            if startWidth == nil {
              startWidth = workspace.railState(for: side).panelWidth
            }
            let direction = side == .left ? 1.0 : -1.0
            workspace.resizePanel(
              on: side,
              to: (startWidth ?? 260) + Double(value.translation.width) * direction
            )
          }
          .onEnded { _ in startWidth = nil }
      )
  }
}
