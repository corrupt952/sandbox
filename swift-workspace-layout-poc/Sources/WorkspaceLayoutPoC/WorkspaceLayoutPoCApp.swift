import AppKit
import SwiftUI
import WorkspaceLayoutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store = WorkspaceStore()
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let rootView = WorkspaceRootView(store: store)
      .frame(minWidth: 920, minHeight: 560)
      .preferredColorScheme(.dark)
    let hostingController = NSHostingController(rootView: rootView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Workspace Layout PoC"
    window.styleMask = [
      .titled,
      .closable,
      .miniaturizable,
      .resizable,
      .fullSizeContentView,
    ]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = NSColor(red: 0.055, green: 0.058, blue: 0.062, alpha: 1)
    window.setContentSize(NSSize(width: 1280, height: 760))
    window.minSize = NSSize(width: 920, height: 560)
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window

    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
@MainActor
enum WorkspaceLayoutPoCMain {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
  }
}
