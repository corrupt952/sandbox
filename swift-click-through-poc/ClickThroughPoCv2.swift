// ClickThroughPoCv2.swift
// PoC v2: Hybrid approach — Global Monitor + NSTrackingArea + low-freq failsafe.
// No 30fps fixed polling. Event-driven where possible.
//
// Build & Run:
//   swiftc -framework Cocoa -framework SwiftUI -o ClickThroughPoCv2 ClickThroughPoCv2.swift && ./ClickThroughPoCv2

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
  /// Margin around panel frame for proximity detection
  static let proximityMargin: CGFloat = 50

  static var totalTabsHeight: CGFloat {
    CGFloat(tabCount) * tabHeight + CGFloat(tabCount - 1) * tabGap
  }

  static var panelWidth: CGFloat { tabWidth }
  static var panelHeight: CGFloat { totalTabsHeight + verticalPadding * 2 }
}

// MARK: - ClickThroughState

final class ClickThroughState: ObservableObject {
  @Published var hoveredTab: Int? = nil
}

// MARK: - ClickThroughController

/// Hybrid mouse tracking:
/// 1. Global monitor (event-driven): detects mouse entering tab regions while ignoresMouseEvents=true
/// 2. NSTrackingArea (event-driven): per-tab hover while ignoresMouseEvents=false
/// 3. Low-freq failsafe timer (2fps): catches edge cases global monitor misses
@MainActor
final class ClickThroughController {
  private let panel: NSPanel
  private let state: ClickThroughState

  private var globalMonitor: Any?
  private var failsafeTimer: Timer?

  init(panel: NSPanel, state: ClickThroughState) {
    self.panel = panel
    self.state = state
  }

  func start() {
    panel.ignoresMouseEvents = true
    setupGlobalMonitor()
    setupFailsafeTimer()
  }

  func stop() {
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
      globalMonitor = nil
    }
    failsafeTimer?.invalidate()
    failsafeTimer = nil
  }

  // MARK: - Global Monitor (event-driven, fires when mouse moves)

  private func setupGlobalMonitor() {
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        self?.checkMousePosition()
      }
    }
  }

  // MARK: - Failsafe Timer (2fps, catches cases global monitor misses)

  private func setupFailsafeTimer() {
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.checkMousePosition()
      }
    }
    timer.tolerance = 0.2
    failsafeTimer = timer
  }

  // MARK: - Mouse Position Check

  /// Called by global monitor (event-driven) or failsafe timer.
  /// When ignoresMouseEvents=true: checks if cursor entered a tab → switches to interactive.
  /// When ignoresMouseEvents=false: NSTrackingArea handles hover, this is a no-op (early return).
  func checkMousePosition() {
    // When interactive, NSTrackingArea handles everything. Only check for "escape" via failsafe.
    if !panel.ignoresMouseEvents {
      // Failsafe: if cursor left all tabs but mouseExited didn't fire for some reason
      let mouse = NSEvent.mouseLocation
      if hitTestTabs(screenPoint: mouse) == nil {
        goPassthrough()
      }
      return
    }

    // ignoresMouseEvents=true: check if cursor is now over a tab
    let mouse = NSEvent.mouseLocation
    if let tabIndex = hitTestTabs(screenPoint: mouse) {
      goInteractive(hoveredTab: tabIndex)
    }
  }

  // MARK: - State Transitions

  /// Switch to interactive mode: panel accepts events, NSTrackingArea works.
  private func goInteractive(hoveredTab: Int) {
    state.hoveredTab = hoveredTab
    panel.ignoresMouseEvents = false
    // NSTrackingArea on the hosting view will now handle per-tab hover.
    // It is set up in ClickThroughHostingView.updateTrackingAreas().
    print("[v2] → interactive, tab=\(hoveredTab)")
  }

  /// Switch to passthrough mode: panel ignores events, clicks go through.
  func goPassthrough() {
    guard !panel.ignoresMouseEvents else { return }
    state.hoveredTab = nil
    panel.ignoresMouseEvents = true
    print("[v2] → passthrough")
  }

  // MARK: - Tab Hit Test (screen coordinates)

  func hitTestTabs(screenPoint: NSPoint) -> Int? {
    let pf = panel.frame
    guard pf.contains(screenPoint) else { return nil }

    for i in 0..<Layout.tabCount {
      let isExpanded = (state.hoveredTab == i)
      let hitWidth = isExpanded ? Layout.tabWidth : Layout.visibleCollapsed
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

// MARK: - ClickThroughHostingView

/// NSHostingView subclass with per-tab NSTrackingAreas.
/// Active only when ignoresMouseEvents=false (interactive mode).
class ClickThroughHostingView<Content: View>: NSHostingView<Content> {

  weak var controller: ClickThroughController?
  var state: ClickThroughState?
  private var tabTrackingAreas: [NSTrackingArea] = []

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    rebuildTrackingAreas()
  }

  func rebuildTrackingAreas() {
    for area in tabTrackingAreas { removeTrackingArea(area) }
    tabTrackingAreas.removeAll()

    let mouseScreen = NSEvent.mouseLocation
    let mouseWindow = window?.convertPoint(fromScreen: mouseScreen) ?? .zero
    let mouseLocal = convert(mouseWindow, from: nil)

    for i in 0..<Layout.tabCount {
      let isExpanded = (state?.hoveredTab == i)
      let rect = tabRectInView(index: i, expanded: isExpanded)
      var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
      if rect.contains(mouseLocal) {
        options.insert(.assumeInside)
      }
      let area = NSTrackingArea(
        rect: rect,
        options: options,
        owner: self,
        userInfo: ["tabIndex": i]
      )
      addTrackingArea(area)
      tabTrackingAreas.append(area)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    guard let info = event.trackingArea?.userInfo,
      let index = info["tabIndex"] as? Int
    else { return }
    print("[v2] mouseEntered: tab[\(index)]")
    state?.hoveredTab = index
    rebuildTrackingAreas()
  }

  override func mouseExited(with event: NSEvent) {
    guard let info = event.trackingArea?.userInfo,
      let index = info["tabIndex"] as? Int
    else { return }
    print("[v2] mouseExited: tab[\(index)]")

    // Check if cursor moved to another tab or left entirely
    let mouse = NSEvent.mouseLocation
    if let newTab = controller?.hitTestTabs(screenPoint: mouse) {
      // Moved to another tab — stay interactive
      state?.hoveredTab = newTab
      rebuildTrackingAreas()
    } else {
      // Left all tabs — go passthrough
      controller?.goPassthrough()
      rebuildTrackingAreas()
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func tabRectInView(index: Int, expanded: Bool) -> NSRect {
    let w = expanded ? Layout.tabWidth : Layout.visibleCollapsed
    let x = bounds.width - w
    let topDown = Layout.verticalPadding + CGFloat(index) * (Layout.tabHeight + Layout.tabGap)
    let y: CGFloat
    if isFlipped {
      y = topDown
    } else {
      y = bounds.height - topDown - Layout.tabHeight
    }
    return NSRect(x: x, y: y, width: w, height: Layout.tabHeight)
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

    // Wire up hosting view references
    if let hv = panel.contentView
      as? ClickThroughHostingView<
        ModifiedContent<PoCContentView, _EnvironmentKeyWritingModifier<ClickThroughState?>>
      >
    {
      hv.controller = ctrl
      hv.state = state
    }

    print("[v2] Panel frame: \(panel.frame)")
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

    let contentView = PoCContentView().environmentObject(state)
    let hostingView = ClickThroughHostingView(rootView: contentView)
    hostingView.frame = NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight)
    hostingView.autoresizingMask = [.width, .height]
    hostingView.controller = nil  // set after controller is created
    hostingView.state = state
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
      print("[v2] Tapped: \(label)")
    }
  }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
