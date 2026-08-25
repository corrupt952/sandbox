import Combine
import Foundation

public enum RailSide: String, CaseIterable, Sendable {
  case left
  case right
}

public enum ToolKind: String, CaseIterable, Identifiable, Sendable {
  case project
  case search
  case run
  case changes
  case history
  case preview

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .project: "Project"
    case .search: "Search"
    case .run: "Run"
    case .changes: "Changes"
    case .history: "History"
    case .preview: "Preview"
    }
  }

  public var symbolName: String {
    switch self {
    case .project: "folder"
    case .search: "magnifyingglass"
    case .run: "play"
    case .changes: "arrow.trianglehead.branch"
    case .history: "clock"
    case .preview: "rectangle.inset.filled"
    }
  }
}

public struct RailState: Equatable, Sendable {
  public var tools: [ToolKind]
  public var openTool: ToolKind?
  public var panelWidth: Double

  public init(tools: [ToolKind], openTool: ToolKind? = nil, panelWidth: Double = 260) {
    self.tools = tools
    self.openTool = openTool
    self.panelWidth = panelWidth
  }
}

public enum SplitAxis: String, Sendable {
  case horizontal
  case vertical
}

public enum SplitPlacement: String, Sendable {
  case left
  case right
  case top
  case bottom

  public var axis: SplitAxis {
    switch self {
    case .left, .right: .horizontal
    case .top, .bottom: .vertical
    }
  }
}

public struct ContentTab: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public let colorIndex: Int

  public init(id: UUID = UUID(), title: String, colorIndex: Int) {
    self.id = id
    self.title = title
    self.colorIndex = colorIndex
  }
}

public struct TabGroup: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tabs: [ContentTab]
  public var selectedTabID: UUID

  public init(id: UUID = UUID(), tabs: [ContentTab], selectedTabID: UUID? = nil) {
    precondition(!tabs.isEmpty, "A tab group must contain at least one tab")
    self.id = id
    self.tabs = tabs
    self.selectedTabID = selectedTabID ?? tabs[0].id
  }
}

public enum LayoutChild: Equatable, Sendable {
  case group(UUID)
  case split(UUID)
}

public struct SplitNode: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var axis: SplitAxis
  public var ratio: Double
  public var first: LayoutChild
  public var second: LayoutChild

  public init(
    id: UUID = UUID(),
    axis: SplitAxis,
    ratio: Double = 0.5,
    first: LayoutChild,
    second: LayoutChild
  ) {
    self.id = id
    self.axis = axis
    self.ratio = ratio
    self.first = first
    self.second = second
  }
}

public final class WorkspaceModel: ObservableObject, Identifiable {
  public let id: UUID
  @Published public var name: String
  @Published public private(set) var leftRail: RailState
  @Published public private(set) var rightRail: RailState
  @Published public private(set) var root: LayoutChild
  @Published public private(set) var groups: [UUID: TabGroup]
  @Published public private(set) var splits: [UUID: SplitNode]
  @Published public private(set) var activeGroupID: UUID

  private var nextTabNumber = 2

  public init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
    let firstTab = ContentTab(title: "Welcome", colorIndex: 0)
    let firstGroup = TabGroup(tabs: [firstTab])
    leftRail = RailState(tools: [.project, .search, .run], openTool: .project, panelWidth: 224)
    rightRail = RailState(tools: [.changes, .history, .preview], openTool: .changes, panelWidth: 280)
    root = .group(firstGroup.id)
    groups = [firstGroup.id: firstGroup]
    splits = [:]
    activeGroupID = firstGroup.id
  }

  public func railState(for side: RailSide) -> RailState {
    side == .left ? leftRail : rightRail
  }

  public func toggleTool(_ tool: ToolKind, on side: RailSide) {
    var rail = railState(for: side)
    guard rail.tools.contains(tool) else { return }
    rail.openTool = rail.openTool == tool ? nil : tool
    setRail(rail, for: side)
  }

  public func moveTool(_ tool: ToolKind, to destination: RailSide) {
    var left = leftRail
    var right = rightRail
    left.tools.removeAll { $0 == tool }
    right.tools.removeAll { $0 == tool }
    if left.openTool == tool { left.openTool = nil }
    if right.openTool == tool { right.openTool = nil }
    if destination == .left {
      left.tools.append(tool)
      left.openTool = tool
    } else {
      right.tools.append(tool)
      right.openTool = tool
    }
    leftRail = left
    rightRail = right
  }

  public func resizePanel(on side: RailSide, to width: Double) {
    var rail = railState(for: side)
    rail.panelWidth = min(max(width, 180), 440)
    setRail(rail, for: side)
  }

  public func activateGroup(_ groupID: UUID) {
    guard groups[groupID] != nil else { return }
    activeGroupID = groupID
  }

  public func selectTab(_ tabID: UUID, in groupID: UUID) {
    guard var group = groups[groupID], group.tabs.contains(where: { $0.id == tabID }) else {
      return
    }
    group.selectedTabID = tabID
    groups[groupID] = group
    activeGroupID = groupID
  }

  @discardableResult
  public func addTab(to groupID: UUID) -> UUID? {
    guard var group = groups[groupID] else { return nil }
    let tab = ContentTab(title: "View \(nextTabNumber)", colorIndex: nextTabNumber - 1)
    nextTabNumber += 1
    group.tabs.append(tab)
    group.selectedTabID = tab.id
    groups[groupID] = group
    activeGroupID = groupID
    return tab.id
  }

  public func closeTab(_ tabID: UUID, in groupID: UUID) {
    guard var group = groups[groupID], let index = group.tabs.firstIndex(where: { $0.id == tabID }) else {
      return
    }
    if group.tabs.count == 1 {
      guard groups.count > 1 else { return }
      removeGroup(groupID)
      return
    }
    group.tabs.remove(at: index)
    if group.selectedTabID == tabID {
      group.selectedTabID = group.tabs[min(index, group.tabs.count - 1)].id
    }
    groups[groupID] = group
  }

  @discardableResult
  public func splitGroup(_ groupID: UUID, axis: SplitAxis) -> UUID? {
    guard groups[groupID] != nil else { return nil }
    let tab = ContentTab(title: "View \(nextTabNumber)", colorIndex: nextTabNumber - 1)
    nextTabNumber += 1
    let newGroup = TabGroup(tabs: [tab])
    let split = SplitNode(
      axis: axis,
      first: .group(groupID),
      second: .group(newGroup.id)
    )
    groups[newGroup.id] = newGroup
    splits[split.id] = split
    root = replacing(.group(groupID), with: .split(split.id), in: root)
    activeGroupID = newGroup.id
    return newGroup.id
  }

  public func setSplitRatio(_ splitID: UUID, ratio: Double) {
    guard var split = splits[splitID] else { return }
    split.ratio = min(max(ratio, 0.18), 0.82)
    splits[splitID] = split
  }

  public func moveTab(_ tabID: UUID, to destinationGroupID: UUID) {
    guard let sourceGroupID = groups.first(where: { _, group in
      group.tabs.contains(where: { $0.id == tabID })
    })?.key,
      sourceGroupID != destinationGroupID,
      var source = groups[sourceGroupID],
      var destination = groups[destinationGroupID],
      let sourceIndex = source.tabs.firstIndex(where: { $0.id == tabID })
    else { return }

    let tab = source.tabs.remove(at: sourceIndex)
    destination.tabs.append(tab)
    destination.selectedTabID = tab.id
    groups[destinationGroupID] = destination
    activeGroupID = destinationGroupID

    if source.tabs.isEmpty {
      removeGroup(sourceGroupID)
    } else {
      if source.selectedTabID == tabID {
        source.selectedTabID = source.tabs[min(sourceIndex, source.tabs.count - 1)].id
      }
      groups[sourceGroupID] = source
    }
  }

  @discardableResult
  public func splitGroup(
    _ targetGroupID: UUID,
    with tabID: UUID,
    at placement: SplitPlacement
  ) -> Bool {
    guard groups[targetGroupID] != nil,
      let sourceGroupID = groups.first(where: { _, group in
        group.tabs.contains(where: { $0.id == tabID })
      })?.key,
      var source = groups[sourceGroupID],
      let sourceIndex = source.tabs.firstIndex(where: { $0.id == tabID })
    else { return false }

    guard sourceGroupID != targetGroupID || source.tabs.count > 1 else { return false }

    let tab = source.tabs.remove(at: sourceIndex)
    if source.tabs.isEmpty {
      removeGroup(sourceGroupID)
    } else {
      if source.selectedTabID == tabID {
        source.selectedTabID = source.tabs[min(sourceIndex, source.tabs.count - 1)].id
      }
      groups[sourceGroupID] = source
    }

    guard groups[targetGroupID] != nil else { return false }
    let newGroup = TabGroup(tabs: [tab])
    groups[newGroup.id] = newGroup
    let target: LayoutChild = .group(targetGroupID)
    let newcomer: LayoutChild = .group(newGroup.id)
    let newcomerComesFirst = placement == .left || placement == .top
    let split = SplitNode(
      axis: placement.axis,
      first: newcomerComesFirst ? newcomer : target,
      second: newcomerComesFirst ? target : newcomer
    )
    splits[split.id] = split
    root = replacing(target, with: .split(split.id), in: root)
    activeGroupID = newGroup.id
    return true
  }

  public func split(_ splitID: UUID) -> SplitNode? {
    splits[splitID]
  }

  public func group(_ groupID: UUID) -> TabGroup? {
    groups[groupID]
  }

  private func setRail(_ state: RailState, for side: RailSide) {
    if side == .left {
      leftRail = state
    } else {
      rightRail = state
    }
  }

  private func replacing(
    _ target: LayoutChild,
    with replacement: LayoutChild,
    in child: LayoutChild
  ) -> LayoutChild {
    if child == target { return replacement }
    guard case .split(let splitID) = child, var split = splits[splitID] else { return child }
    split.first = replacing(target, with: replacement, in: split.first)
    split.second = replacing(target, with: replacement, in: split.second)
    splits[splitID] = split
    return child
  }

  private func removeGroup(_ groupID: UUID) {
    groups.removeValue(forKey: groupID)
    guard let collapsedRoot = removing(groupID, from: root) else {
      assertionFailure("The last group cannot be removed")
      return
    }
    root = collapsedRoot
    activeGroupID = firstGroupID(in: root) ?? groups.keys.first!
  }

  private func removing(_ groupID: UUID, from child: LayoutChild) -> LayoutChild? {
    switch child {
    case .group(let candidateID):
      return candidateID == groupID ? nil : child
    case .split(let splitID):
      guard var split = splits[splitID] else { return nil }
      let first = removing(groupID, from: split.first)
      let second = removing(groupID, from: split.second)
      switch (first, second) {
      case (.some(let first), .some(let second)):
        split.first = first
        split.second = second
        splits[splitID] = split
        return child
      case (.some(let survivor), .none), (.none, .some(let survivor)):
        splits.removeValue(forKey: splitID)
        return survivor
      case (.none, .none):
        splits.removeValue(forKey: splitID)
        return nil
      }
    }
  }

  private func firstGroupID(in child: LayoutChild) -> UUID? {
    switch child {
    case .group(let groupID):
      return groupID
    case .split(let splitID):
      guard let split = splits[splitID] else { return nil }
      return firstGroupID(in: split.first) ?? firstGroupID(in: split.second)
    }
  }
}

public final class WorkspaceStore: ObservableObject {
  @Published public private(set) var workspaces: [WorkspaceModel]
  @Published public var selectedWorkspaceID: UUID

  public init() {
    let primary = WorkspaceModel(name: "Atlas")
    let secondary = WorkspaceModel(name: "Orion")
    secondary.toggleTool(.project, on: .left)
    workspaces = [primary, secondary]
    selectedWorkspaceID = primary.id
  }

  public var selectedWorkspace: WorkspaceModel {
    workspaces.first(where: { $0.id == selectedWorkspaceID }) ?? workspaces[0]
  }

  @discardableResult
  public func addWorkspace() -> WorkspaceModel {
    let workspace = WorkspaceModel(name: "Workspace \(workspaces.count + 1)")
    workspaces.append(workspace)
    selectedWorkspaceID = workspace.id
    return workspace
  }
}
