# swift-workspace-layout-poc

A self-contained macOS sample for fixed-width tool rails, collapsible side panels, workspace-scoped layouts, tab groups, and recursive splits. The content views are placeholders so the sample stays focused on window behavior and interaction state.

## Result

The sample opens one AppKit `NSWindow` hosting a SwiftUI interface. Each workspace owns independent left and right rail selections, panel widths, tabs, selected tabs, split topology, active group, and divider ratios; switching away and back restores the in-memory layout unchanged.

The center layout is a tree whose leaves are tab groups and whose branches are horizontal or vertical splits. Removing the last tab from a group collapses the empty branch while preserving the remaining group.

## Interactions

- Click a rail icon to open its panel, select another icon to replace the panel, or click the active icon to close it.
- Drag the divider beside an open panel to resize it.
- Right-click a rail icon to move it to the opposite rail.
- Add tabs or create right and downward splits with the controls in each tab bar.
- Drag a split divider to change its ratio.
- Drag a tab to the center of another group to move it there.
- Drag a tab to a highlighted left, right, top, or bottom drop zone to create a split in that direction.
- Switch between the sample workspaces to verify that each layout remains independent.

## Structure

`WorkspaceLayoutCore` contains the platform-independent workspace, rail, tab-group, and split-tree models. `WorkspaceLayoutPoC` contains the AppKit window host and SwiftUI views. The model target is separated so layout transitions can be tested without launching the application.

## Requirements

- macOS 14 or later
- Swift 6.2 toolchain

## Run

```sh
swift run WorkspaceLayoutPoC
```

## Test

```sh
swift test
```

The tests cover workspace-local rail state, split creation and ratio clamping, tab moves between groups, directional drop splits, and automatic split collapse.

## Scope

Layout persistence across launches, detachable windows, real document content, and production accessibility or keyboard-command coverage are intentionally outside this sample.
