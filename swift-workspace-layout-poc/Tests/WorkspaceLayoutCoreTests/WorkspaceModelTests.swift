import XCTest
@testable import WorkspaceLayoutCore

final class WorkspaceModelTests: XCTestCase {
  func testRailToggleAndResizeAreStoredPerWorkspace() {
    let first = WorkspaceModel(name: "First")
    let second = WorkspaceModel(name: "Second")

    first.toggleTool(.project, on: .left)
    first.resizePanel(on: .right, to: 390)

    XCTAssertNil(first.leftRail.openTool)
    XCTAssertEqual(first.rightRail.panelWidth, 390)
    XCTAssertEqual(second.leftRail.openTool, .project)
    XCTAssertEqual(second.rightRail.panelWidth, 280)
  }

  func testSplittingAndClosingLastTabCollapsesTheSplit() throws {
    let workspace = WorkspaceModel(name: "Test")
    let originalGroupID = workspace.activeGroupID
    let newGroupID = try XCTUnwrap(workspace.splitGroup(originalGroupID, axis: .horizontal))

    guard case .split = workspace.root else {
      return XCTFail("Expected a split root")
    }

    let onlyTab = try XCTUnwrap(workspace.group(newGroupID)?.tabs.first)
    workspace.closeTab(onlyTab.id, in: newGroupID)

    XCTAssertEqual(workspace.root, .group(originalGroupID))
    XCTAssertEqual(workspace.groups.count, 1)
    XCTAssertTrue(workspace.splits.isEmpty)
  }

  func testMovingTheOnlyTabCollapsesItsSourceGroup() throws {
    let workspace = WorkspaceModel(name: "Test")
    let sourceGroupID = workspace.activeGroupID
    let destinationGroupID = try XCTUnwrap(
      workspace.splitGroup(sourceGroupID, axis: .vertical)
    )
    let sourceTab = try XCTUnwrap(workspace.group(sourceGroupID)?.tabs.first)

    workspace.moveTab(sourceTab.id, to: destinationGroupID)

    XCTAssertEqual(workspace.root, .group(destinationGroupID))
    XCTAssertEqual(workspace.group(destinationGroupID)?.tabs.count, 2)
    XCTAssertNil(workspace.group(sourceGroupID))
  }

  func testSplitRatioIsClamped() throws {
    let workspace = WorkspaceModel(name: "Test")
    _ = workspace.splitGroup(workspace.activeGroupID, axis: .horizontal)
    guard case .split(let splitID) = workspace.root else {
      return XCTFail("Expected a split root")
    }

    workspace.setSplitRatio(splitID, ratio: 0.99)

    XCTAssertEqual(try XCTUnwrap(workspace.split(splitID)).ratio, 0.82)
  }

  func testDroppingTabOnEdgeSplitsItOutOfItsGroup() throws {
    let workspace = WorkspaceModel(name: "Test")
    let originalGroupID = workspace.activeGroupID
    let tabID = try XCTUnwrap(workspace.addTab(to: originalGroupID))

    XCTAssertTrue(workspace.splitGroup(originalGroupID, with: tabID, at: .right))

    guard case .split(let splitID) = workspace.root else {
      return XCTFail("Expected a split root")
    }
    let split = try XCTUnwrap(workspace.split(splitID))
    XCTAssertEqual(split.axis, .horizontal)
    XCTAssertEqual(split.first, .group(originalGroupID))
    guard case .group(let newGroupID) = split.second else {
      return XCTFail("Expected the new group on the right")
    }
    XCTAssertEqual(workspace.group(originalGroupID)?.tabs.count, 1)
    XCTAssertEqual(workspace.group(newGroupID)?.tabs.map(\.id), [tabID])
  }

  func testDroppingOnlyTabFromAnotherGroupRebuildsTheSplit() throws {
    let workspace = WorkspaceModel(name: "Test")
    let targetGroupID = workspace.activeGroupID
    let sourceGroupID = try XCTUnwrap(
      workspace.splitGroup(targetGroupID, axis: .vertical)
    )
    let tabID = try XCTUnwrap(workspace.group(sourceGroupID)?.tabs.first?.id)

    XCTAssertTrue(workspace.splitGroup(targetGroupID, with: tabID, at: .left))

    XCTAssertNil(workspace.group(sourceGroupID))
    guard case .split(let splitID) = workspace.root else {
      return XCTFail("Expected a rebuilt split root")
    }
    let split = try XCTUnwrap(workspace.split(splitID))
    XCTAssertEqual(split.axis, .horizontal)
    XCTAssertEqual(split.second, .group(targetGroupID))
  }
}
