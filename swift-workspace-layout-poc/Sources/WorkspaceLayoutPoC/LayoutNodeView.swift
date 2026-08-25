import AppKit
import SwiftUI
import WorkspaceLayoutCore

struct LayoutNodeView: View {
  @ObservedObject var workspace: WorkspaceModel
  let child: LayoutChild

  var body: some View {
    switch child {
    case .group(let groupID):
      if let group = workspace.group(groupID) {
        TabGroupView(workspace: workspace, group: group)
      }
    case .split(let splitID):
      if let split = workspace.split(splitID) {
        LayoutSplitView(workspace: workspace, split: split)
      }
    }
  }
}

private struct LayoutSplitView: View {
  @ObservedObject var workspace: WorkspaceModel
  let split: SplitNode

  var body: some View {
    GeometryReader { geometry in
      if split.axis == .horizontal {
        let available = max(geometry.size.width - 5, 0)
        HStack(spacing: 0) {
          LayoutNodeView(workspace: workspace, child: split.first)
            .frame(width: available * split.ratio)
          SplitResizeHandle(
            workspace: workspace,
            split: split,
            availableLength: available
          )
          LayoutNodeView(workspace: workspace, child: split.second)
            .frame(width: available * (1 - split.ratio))
        }
      } else {
        let available = max(geometry.size.height - 5, 0)
        VStack(spacing: 0) {
          LayoutNodeView(workspace: workspace, child: split.first)
            .frame(height: available * split.ratio)
          SplitResizeHandle(
            workspace: workspace,
            split: split,
            availableLength: available
          )
          LayoutNodeView(workspace: workspace, child: split.second)
            .frame(height: available * (1 - split.ratio))
        }
      }
    }
  }
}

private struct SplitResizeHandle: View {
  @ObservedObject var workspace: WorkspaceModel
  let split: SplitNode
  let availableLength: Double
  @State private var startingRatio: Double?

  var body: some View {
    Rectangle()
      .fill(Color.black.opacity(0.55))
      .overlay {
        Rectangle()
          .fill(Color.white.opacity(0.10))
          .frame(
            width: split.axis == .horizontal ? 1 : nil,
            height: split.axis == .vertical ? 1 : nil
          )
      }
      .frame(
        width: split.axis == .horizontal ? 5 : nil,
        height: split.axis == .vertical ? 5 : nil
      )
      .contentShape(Rectangle())
      .onHover { hovering in
        if hovering {
          (split.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            if startingRatio == nil { startingRatio = split.ratio }
            guard availableLength > 0 else { return }
            let distance = split.axis == .horizontal
              ? Double(value.translation.width)
              : Double(value.translation.height)
            workspace.setSplitRatio(
              split.id,
              ratio: (startingRatio ?? split.ratio) + distance / availableLength
            )
          }
          .onEnded { _ in startingRatio = nil }
      )
  }
}

private struct TabGroupView: View {
  @ObservedObject var workspace: WorkspaceModel
  let group: TabGroup

  private var selectedTab: ContentTab {
    group.tabs.first(where: { $0.id == group.selectedTabID }) ?? group.tabs[0]
  }

  var body: some View {
    VStack(spacing: 0) {
      TabBar(workspace: workspace, group: group)
      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)
      PlaceholderContent(tab: selectedTab, workspaceName: workspace.name)
        .overlay {
          TabDropZones(workspace: workspace, targetGroupID: group.id)
        }
    }
    .background(Color(red: 0.095, green: 0.099, blue: 0.105))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          workspace.activeGroupID == group.id
            ? Color.accentColor.opacity(0.52)
            : Color.white.opacity(0.07),
          lineWidth: 1
        )
    }
    .contentShape(Rectangle())
    .onTapGesture { workspace.activateGroup(group.id) }
  }
}

private enum TabDropAction: Equatable {
  case move
  case split(SplitPlacement)

  var label: String {
    switch self {
    case .move: "Move here"
    case .split(.left): "Split left"
    case .split(.right): "Split right"
    case .split(.top): "Split up"
    case .split(.bottom): "Split down"
    }
  }

  var symbol: String {
    switch self {
    case .move: "rectangle.on.rectangle"
    case .split(.left): "rectangle.lefthalf.inset.filled"
    case .split(.right): "rectangle.righthalf.inset.filled"
    case .split(.top): "rectangle.tophalf.inset.filled"
    case .split(.bottom): "rectangle.bottomhalf.inset.filled"
    }
  }
}

private struct TabDropZones: View {
  @ObservedObject var workspace: WorkspaceModel
  let targetGroupID: UUID

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let height = geometry.size.height

      ZStack {
        TabDropZone(action: .split(.left), onDrop: handleDrop)
          .frame(width: width * 0.22, height: height)
          .position(x: width * 0.11, y: height * 0.5)
        TabDropZone(action: .split(.right), onDrop: handleDrop)
          .frame(width: width * 0.22, height: height)
          .position(x: width * 0.89, y: height * 0.5)
        TabDropZone(action: .split(.top), onDrop: handleDrop)
          .frame(width: width * 0.56, height: height * 0.28)
          .position(x: width * 0.5, y: height * 0.14)
        TabDropZone(action: .split(.bottom), onDrop: handleDrop)
          .frame(width: width * 0.56, height: height * 0.28)
          .position(x: width * 0.5, y: height * 0.86)
        TabDropZone(action: .move, onDrop: handleDrop)
          .frame(width: width * 0.56, height: height * 0.44)
          .position(x: width * 0.5, y: height * 0.5)
      }
    }
  }

  private func handleDrop(_ rawTabID: String, action: TabDropAction) -> Bool {
    guard let tabID = UUID(uuidString: rawTabID) else { return false }
    switch action {
    case .move:
      workspace.moveTab(tabID, to: targetGroupID)
      return true
    case .split(let placement):
      return workspace.splitGroup(targetGroupID, with: tabID, at: placement)
    }
  }
}

private struct TabDropZone: View {
  let action: TabDropAction
  let onDrop: (String, TabDropAction) -> Bool
  @State private var isTargeted = false

  var body: some View {
    Rectangle()
      .fill(Color.accentColor.opacity(isTargeted ? 0.20 : 0.001))
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 2)
            .padding(3)
          Label(action.label, systemImage: action.symbol)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
      }
      .dropDestination(for: String.self) { values, _ in
        guard let rawTabID = values.first else { return false }
        return onDrop(rawTabID, action)
      } isTargeted: { targeted in
        isTargeted = targeted
      }
  }
}

private struct TabBar: View {
  @ObservedObject var workspace: WorkspaceModel
  let group: TabGroup

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 3) {
          ForEach(group.tabs) { tab in
            TabButton(
              tab: tab,
              isSelected: tab.id == group.selectedTabID,
              onSelect: { workspace.selectTab(tab.id, in: group.id) },
              onClose: { workspace.closeTab(tab.id, in: group.id) }
            )
          }
        }
        .padding(.horizontal, 6)
      }

      Rectangle()
        .fill(Color.white.opacity(0.08))
        .frame(width: 1, height: 22)

      GroupControlButton(symbol: "plus", help: "Add tab") {
        _ = workspace.addTab(to: group.id)
      }
      GroupControlButton(symbol: "rectangle.split.2x1", help: "Split right") {
        _ = workspace.splitGroup(group.id, axis: .horizontal)
      }
      GroupControlButton(symbol: "rectangle.split.1x2", help: "Split down") {
        _ = workspace.splitGroup(group.id, axis: .vertical)
      }
      .padding(.trailing, 4)
    }
    .frame(height: 38)
    .background(Color.black.opacity(0.14))
  }
}

private struct TabButton: View {
  let tab: ContentTab
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(PlaceholderPalette.color(for: tab.colorIndex))
        .frame(width: 7, height: 7)
      Text(tab.title)
        .lineLimit(1)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 15, height: 15)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
    .padding(.leading, 9)
    .padding(.trailing, 5)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .draggable(tab.id.uuidString)
  }
}

private struct GroupControlButton: View {
  let symbol: String
  let help: String
  let action: () -> Void

  init(symbol: String, help: String, action: @escaping () -> Void) {
    self.symbol = symbol
    self.help = help
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12))
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
  }
}

private struct PlaceholderContent: View {
  let tab: ContentTab
  let workspaceName: String

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          PlaceholderPalette.color(for: tab.colorIndex).opacity(0.16),
          Color.clear,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 13)
          .fill(PlaceholderPalette.color(for: tab.colorIndex).opacity(0.18))
          .frame(width: 54, height: 54)
          .overlay {
            Image(systemName: "macwindow")
              .font(.system(size: 22, weight: .light))
              .foregroundStyle(PlaceholderPalette.color(for: tab.colorIndex))
          }
        Text(tab.title)
          .font(.system(size: 19, weight: .semibold))
        Text("\(workspaceName) · placeholder content")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Text("Drag tabs between groups · Split with the buttons above")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }
    }
  }
}

private enum PlaceholderPalette {
  static let colors: [Color] = [
    .cyan, .orange, .purple, .green, .pink, .yellow, .blue, .mint,
  ]

  static func color(for index: Int) -> Color {
    colors[index % colors.count]
  }
}
