import AppKit

private final class TerminalContainerViewController: NSViewController {
  private weak var currentTerminal: TerminalView?

  override func loadView() {
    view = NSView()
  }

  func show(_ terminal: TerminalView) {
    guard currentTerminal !== terminal else { return }
    currentTerminal?.removeFromSuperview()

    terminal.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(terminal)
    NSLayoutConstraint.activate([
      terminal.topAnchor.constraint(equalTo: view.topAnchor),
      terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    currentTerminal = terminal
  }
}

final class WorkspaceSplitViewController: NSSplitViewController {
  private let sidebarController: WorkspaceSidebarViewController
  private let terminalController = TerminalContainerViewController()
  private var workspaces: [TerminalWorkspace]
  private var terminalViews: [TerminalWorkspace: TerminalView] = [:]
  private var currentWorkspace: TerminalWorkspace?
  private(set) var currentTerminalView: TerminalView?

  init(initialDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    let initialWorkspace = TerminalWorkspace(directoryURL: initialDirectory)
    workspaces = [initialWorkspace]
    sidebarController = WorkspaceSidebarViewController()
    super.init(nibName: nil, bundle: nil)

    splitView.isVertical = true
    splitView.dividerStyle = .thin

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebarItem.minimumThickness = 160
    sidebarItem.maximumThickness = 320
    sidebarItem.canCollapse = true
    addSplitViewItem(sidebarItem)

    addSplitViewItem(NSSplitViewItem(viewController: terminalController))

    sidebarController.onSelectWorkspace = { [weak self] workspace in
      self?.showWorkspace(workspace)
    }
    let accessory = WorkspaceAddAccessoryViewController()
    accessory.onAddWorkspace = { [weak self] in
      self?.chooseWorkspaceDirectory()
    }
    sidebarItem.addBottomAlignedAccessoryViewController(accessory)

    showWorkspace(initialWorkspace)
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidAppear() {
    super.viewDidAppear()
    updateWindowForCurrentWorkspace()
  }

  private func showWorkspace(_ workspace: TerminalWorkspace) {
    guard workspaces.contains(workspace) else { return }

    let terminal: TerminalView
    if let existing = terminalViews[workspace] {
      terminal = existing
    } else {
      terminal = TerminalView(frame: .zero, workingDirectory: workspace.directoryURL)
      terminalViews[workspace] = terminal
    }

    terminalController.show(terminal)
    currentWorkspace = workspace
    currentTerminalView = terminal
    sidebarController.updateWorkspaces(workspaces, selected: workspace)
    updateWindowForCurrentWorkspace()

    DispatchQueue.main.async { [weak self, weak terminal] in
      guard let self, let terminal else { return }
      self.view.window?.makeFirstResponder(terminal)
    }
  }

  private func chooseWorkspaceDirectory() {
    guard let window = view.window else { return }

    let panel = NSOpenPanel()
    panel.title = "Add Workspace"
    panel.message = "Choose a directory to open as a workspace."
    panel.prompt = "Add"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.treatsFilePackagesAsDirectories = true

    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let directory = panel.url else { return }
      self?.addWorkspace(directory)
    }
  }

  private func addWorkspace(_ directory: URL) {
    let workspace = TerminalWorkspace(directoryURL: directory)
    if !workspaces.contains(workspace) {
      workspaces.append(workspace)
    }
    showWorkspace(workspace)
  }

  private func updateWindowForCurrentWorkspace() {
    guard let workspace = currentWorkspace else { return }
    view.window?.title = "GhosttyPoC — \(workspace.displayName)"
  }
}
