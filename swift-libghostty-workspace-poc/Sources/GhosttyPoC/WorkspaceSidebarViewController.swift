import AppKit

final class WorkspaceSidebarViewController: NSViewController {
  var onSelectWorkspace: ((TerminalWorkspace) -> Void)?

  private let tableView = NSTableView()
  private var workspaces: [TerminalWorkspace] = []
  private var isUpdatingSelection = false

  init() {
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override func loadView() {
    let root = NSView()
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Workspace"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .sourceList
    tableView.backgroundColor = .clear
    tableView.allowsEmptySelection = false
    tableView.allowsMultipleSelection = false
    tableView.rowSizeStyle = .medium
    tableView.autoresizingMask = [.width]
    tableView.dataSource = self
    tableView.delegate = self
    scrollView.documentView = tableView

    root.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: root.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])

    view = root
  }

  func updateWorkspaces(_ workspaces: [TerminalWorkspace], selected: TerminalWorkspace) {
    _ = view
    isUpdatingSelection = true
    defer { isUpdatingSelection = false }
    self.workspaces = workspaces
    tableView.reloadData()
    guard let index = workspaces.firstIndex(of: selected) else { return }
    if tableView.selectedRow != index {
      tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    tableView.scrollRowToVisible(index)
  }

}

extension WorkspaceSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    workspaces.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")
    let cell: NSTableCellView

    if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
      as? NSTableCellView
    {
      cell = reused
    } else {
      cell = NSTableCellView()
      cell.identifier = identifier

      let imageView = NSImageView()
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.imageScaling = .scaleProportionallyDown

      let textField = NSTextField(labelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.lineBreakMode = .byTruncatingTail

      cell.imageView = imageView
      cell.textField = textField
      cell.addSubview(imageView)
      cell.addSubview(textField)

      NSLayoutConstraint.activate([
        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        imageView.widthAnchor.constraint(equalToConstant: 18),
        imageView.heightAnchor.constraint(equalToConstant: 18),
        textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }

    let workspace = workspaces[row]
    workspace.icon.size = NSSize(width: 18, height: 18)
    cell.imageView?.image = workspace.icon
    cell.textField?.stringValue = workspace.displayName
    cell.toolTip = workspace.directoryURL.path
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isUpdatingSelection else { return }
    let row = tableView.selectedRow
    guard workspaces.indices.contains(row) else { return }
    onSelectWorkspace?(workspaces[row])
  }
}

final class WorkspaceAddAccessoryViewController: NSSplitViewItemAccessoryViewController {
  var onAddWorkspace: (() -> Void)?

  override func loadView() {
    let root = NSView()
    let image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Workspace")!
    let button = NSButton(image: image, target: self, action: #selector(addWorkspace))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.bezelStyle = .glass
    button.toolTip = "Add Workspace…"
    button.setAccessibilityLabel("Add Workspace")
    root.addSubview(button)

    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      button.topAnchor.constraint(equalTo: root.topAnchor),
      button.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    view = root
  }

  @objc private func addWorkspace() {
    onAddWorkspace?()
  }
}
