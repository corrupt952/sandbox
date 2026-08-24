import AppKit

struct TerminalWorkspace: Hashable {
  let directoryURL: URL

  init(directoryURL: URL) {
    self.directoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
  }

  var displayName: String {
    FileManager.default.displayName(atPath: directoryURL.path)
  }

  var icon: NSImage {
    NSWorkspace.shared.icon(forFile: directoryURL.path)
  }
}
