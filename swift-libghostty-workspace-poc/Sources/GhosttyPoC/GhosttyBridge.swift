import AppKit
import CGhostty

/// Minimal singleton wrapper around one Ghostty app instance.
final class GhosttyBridge {
  static let shared = GhosttyBridge()

  private(set) var app: ghostty_app_t?
  private(set) var config: ghostty_config_t?

  private init() {}

  @discardableResult
  func initialize() -> Bool {
    let argc = CommandLine.argc
    let rawArgv = CommandLine.unsafeArgv
    guard ghostty_init(UInt(argc), rawArgv) == 0 else {
      print("[GhosttyBridge] ghostty_init failed")
      return false
    }

    guard let cfg = ghostty_config_new() else {
      print("[GhosttyBridge] ghostty_config_new failed")
      return false
    }
    ghostty_config_load_default_files(cfg)
    ghostty_config_load_recursive_files(cfg)
    ghostty_config_finalize(cfg)
    self.config = cfg

    var rtConfig = ghostty_runtime_config_s()
    rtConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
    rtConfig.supports_selection_clipboard = false
    rtConfig.wakeup_cb = GhosttyBridge.wakeupCallback
    rtConfig.action_cb = GhosttyBridge.actionCallback
    rtConfig.close_surface_cb = GhosttyBridge.closeSurfaceCallback
    rtConfig.read_clipboard_cb = GhosttyBridge.readClipboardCallback
    rtConfig.confirm_read_clipboard_cb = GhosttyBridge.confirmReadClipboardCallback
    rtConfig.write_clipboard_cb = GhosttyBridge.writeClipboardCallback

    guard let appHandle = ghostty_app_new(&rtConfig, cfg) else {
      print("[GhosttyBridge] ghostty_app_new failed")
      return false
    }
    self.app = appHandle
    return true
  }

  /// Caller owns the returned handle and must call ghostty_surface_free().
  func newSurface(
    nsView: NSView, scaleFactor: Double, workingDirectory: URL
  ) -> ghostty_surface_t? {
    guard let appHandle = app else { return nil }

    var surfCfg = ghostty_surface_config_new()
    surfCfg.scale_factor = scaleFactor
    surfCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfCfg.platform.macos.nsview = Unmanaged.passUnretained(nsView).toOpaque()

    return workingDirectory.path.withCString { wdPtr in
      surfCfg.working_directory = wdPtr
      return ghostty_surface_new(appHandle, &surfCfg)
    }
  }

  // MARK: - C callbacks

  private static let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
    guard let ptr = userdata else { return }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(ptr).takeUnretainedValue()
    // Match Ghostty's macOS host: wakeups may arrive on any thread, while
    // app ticks belong on the main thread. The upstream host intentionally
    // does not coalesce these callbacks.
    DispatchQueue.main.async {
      guard let appHandle = bridge.app else { return }
      ghostty_app_tick(appHandle)
    }
  }

  // Every action is acknowledged/ignored — this PoC has no config UI or
  // link-hover affordances.
  private static let actionCallback: ghostty_runtime_action_cb = { _, _, action in
    switch action.tag {
    case GHOSTTY_ACTION_CONFIG_CHANGE:
      return true
    default:
      return false
    }
  }

  private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }

  // No paste support in this PoC: always deny.
  private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = {
    _, _, _, _, _, _ in
    GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
  }

  private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = {
    _, _, _, _ in
  }

  // No copy support in this PoC: drop the selection.
  private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, _, _, _, _ in
  }
}
