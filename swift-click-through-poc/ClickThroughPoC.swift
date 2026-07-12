// ClickThroughPoC.swift
// PoC: Transparent NSPanel with per-tab click-through via ignoresMouseEvents toggle.
//
// Build & Run:
//   swiftc -framework Cocoa -framework SwiftUI -o ClickThroughPoC ClickThroughPoC.swift && ./ClickThroughPoC

import Cocoa
import SwiftUI

// MARK: - Layout

enum Layout {
  static let tabWidth: CGFloat = 120
  static let tabHeight: CGFloat = 42
  static let tabGap: CGFloat = 8
  static let visibleCollapsed: CGFloat = 20
  static let tabCount: Int = 4
  static let verticalPadding: CGFloat = 8

  static var totalTabsHeight: CGFloat {
    CGFloat(tabCount) * tabHeight + CGFloat(tabCount - 1) * tabGap
  }

  static var panelWidth: CGFloat { tabWidth }
  static var panelHeight: CGFloat { totalTabsHeight + verticalPadding * 2 }
}

// MARK: - ClickThroughState (Single Source of Truth)

final class ClickThroughState: ObservableObject {
  @Published var hoveredTab: Int? = nil
}

// MARK: - ClickThroughController

/// Polls NSEvent.mouseLocation, determines which tab (if any) the cursor is over,
/// and toggles panel.ignoresMouseEvents accordingly.
/// No NSTrackingArea. No hitTest override. Screen-coordinate math only.
@MainActor
final class ClickThroughController {
  private let panel: NSPanel
  private let state: ClickThroughState
  private var timer: Timer?

  init(panel: NSPanel, state: ClickThroughState) {
    self.panel = panel
    self.state = state
  }

  func start() {
    panel.ignoresMouseEvents = true
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tick()
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    let mouseScreen = NSEvent.mouseLocation
    let newHovered = hitTestTabs(screenPoint: mouseScreen)

    if newHovered != state.hoveredTab {
      state.hoveredTab = newHovered
      panel.ignoresMouseEvents = (newHovered == nil)
      print(
        "[PoC] hoveredTab=\(newHovered.map(String.init) ?? "nil"), ignoresMouseEvents=\(newHovered == nil)"
      )
    }
  }

  /// Returns the tab index at the given screen point, or nil.
  private func hitTestTabs(screenPoint: NSPoint) -> Int? {
    let pf = panel.frame

    // Quick bounds check
    guard pf.contains(screenPoint) else { return nil }

    for i in 0..<Layout.tabCount {
      let isExpanded = (state.hoveredTab == i)
      let hitWidth = isExpanded ? Layout.tabWidth : Layout.visibleCollapsed

      // Screen coords: origin bottom-left, Y up.
      // Panel layout (top-down): verticalPadding, then tabs with gaps.
      let topOffset = Layout.verticalPadding + CGFloat(i) * (Layout.tabHeight + Layout.tabGap)
      let screenY = pf.maxY - topOffset - Layout.tabHeight
      let screenX = pf.maxX - hitWidth

      let tabRect = CGRect(x: screenX, y: screenY, width: hitWidth, height: Layout.tabHeight)
      if tabRect.contains(screenPoint) {
        return i
      }
    }
    return nil
  }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: NSPanel?
  var controller: ClickThroughController?
  let state = ClickThroughState()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)

    let panel = createPanel()
    panel.orderFrontRegardless()
    self.panel = panel

    let ctrl = ClickThroughController(panel: panel, state: state)
    ctrl.start()
    self.controller = ctrl

    print("[PoC] Panel frame (screen): \(panel.frame)")
  }

  private func createPanel() -> NSPanel {
    guard let screen = NSScreen.main else { fatalError("No screen") }
    let vf = screen.visibleFrame

    let panel = NSPanel(
      contentRect: NSRect(
        x: vf.maxX - Layout.panelWidth,
        y: vf.midY - Layout.panelHeight / 2,
        width: Layout.panelWidth,
        height: Layout.panelHeight
      ),
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.isMovable = false
    panel.isMovableByWindowBackground = false

    let contentView = PoCContentView()
      .environmentObject(state)
    let hostingView = NSHostingView(rootView: contentView)
    hostingView.frame = NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight)
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView

    return panel
  }
}

// MARK: - PoCContentView

struct PoCContentView: View {
  @EnvironmentObject var state: ClickThroughState

  private let tabs: [(Int, String, Color)] = [
    (0, "Clock", .blue),
    (1, "Notes", .green),
    (2, "Music", .orange),
    (3, "Tasks", .pink),
  ]

  var body: some View {
    VStack(spacing: Layout.tabGap) {
      ForEach(tabs, id: \.0) { tab in
        TabItem(
          label: tab.1,
          color: tab.2,
          isExpanded: state.hoveredTab == tab.0
        )
      }
    }
    .padding(.vertical, Layout.verticalPadding)
    .background(Color.red.opacity(0.08))
    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state.hoveredTab)
  }
}

// MARK: - TabItem

struct TabItem: View {
  let label: String
  let color: Color
  let isExpanded: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(color)

      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
    }
    .frame(width: Layout.tabWidth, height: Layout.tabHeight)
    .offset(x: isExpanded ? 0 : Layout.tabWidth - Layout.visibleCollapsed)
    .onTapGesture {
      print("[PoC] Tapped: \(label)")
    }
  }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
