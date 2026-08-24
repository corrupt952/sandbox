import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard GhosttyBridge.shared.initialize() else {
      fatalError("GhosttyBridge.initialize() failed")
    }

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let workspaceController = WorkspaceSplitViewController()
    win.title = "GhosttyPoC"
    win.contentViewController = workspaceController
    win.setContentSize(NSSize(width: 900, height: 600))
    win.contentMinSize = NSSize(width: 640, height: 400)
    win.center()
    win.makeFirstResponder(workspaceController.currentTerminalView)
    win.makeKeyAndOrderFront(nil)
    self.window = win

    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
