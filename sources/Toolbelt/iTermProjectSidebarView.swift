import AppKit

@objc protocol iTermProjectSidebarDelegate: AnyObject {
    func projectSidebar(_ sidebar: iTermProjectSidebarView, didSelectProject project: iTermProjectDirectory, openIfNeeded: Bool)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, didSelectWorktree worktree: iTermGitWorktree, openIfNeeded: Bool)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, didSelectRepository repository: iTermGitRepositorySnapshot, openIfNeeded: Bool)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, openProject project: iTermProjectDirectory, style: iTermOpenStyle)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, openRepository repository: iTermGitRepositorySnapshot, style: iTermOpenStyle)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, openWorktree worktree: iTermGitWorktree, style: iTermOpenStyle)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, canOpenTerminalWithStyle style: iTermOpenStyle) -> Bool
    func projectSidebarAddFolder(_ sidebar: iTermProjectSidebarView)
    func projectSidebarAddCurrentDirectory(_ sidebar: iTermProjectSidebarView)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, removeProject project: iTermProjectDirectory)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, removeRepository repository: iTermGitRepositorySnapshot)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, removeWorktree worktree: iTermGitWorktree,
                        fromRepository repository: iTermGitRepositorySnapshot, deleteBranch: Bool)
    func projectSidebar(_ sidebar: iTermProjectSidebarView, refreshRepositories identifiers: [String]?)
}

@objcMembers final class iTermProjectSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: iTermProjectSidebarDelegate?
    var tree: iTermProjectSidebarTree? { didSet { publishTree() } }
    var selectedProjectIdentifier: String? { didSet { if oldValue != selectedProjectIdentifier { updateSelection(reveal: true) } } }
    var selectedWorktreeIdentifier: String? { didSet { if oldValue != selectedWorktreeIdentifier { updateSelection(reveal: true) } } }
    var canAddCurrentDirectory = false { didSet { if oldValue != canAddCurrentDirectory { currentButton.isEnabled = canAddCurrentDirectory } } }
    @nonobjc var directoryOpener: (URL) -> Bool = {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path)
    }
    var pathPasteboard = NSPasteboard.general
    private let outline = iTermProjectSidebarOutlineView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()
    private let currentButton = NSButton()
    private let removeButton = NSButton()
    private let refreshButton = NSButton()
    private let title = NSTextField(labelWithString: String(localized: "ProjectSidebar.Projects", defaultValue: "Projects", comment: "Project sidebar heading"))
    private let folderImage = NSImage(systemSymbolName: SFSymbol.folder.rawValue, accessibilityDescription: nil)
    private let branchImage = NSImage(systemSymbolName: SFSymbol.arrowTriangleBranch.rawValue, accessibilityDescription: nil)
    private let errorImage = NSImage(systemSymbolName: SFSymbol.exclamationmarkTriangle.rawValue, accessibilityDescription: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: String(localized: "ProjectSidebar.Empty", defaultValue: "Add a folder to get started.", comment: "Empty state in the project sidebar"))
    private var publishedTree: iTermProjectSidebarTree?
    private var updatingSelection = false
    private var expandedRepositories = Set<String>()
    private var refreshTimer: Timer?
    private var observers = [NSObjectProtocol]()
    private var terminalMenuIsTracking = false
    private var preferredRepositoryIdentifier: String?
    private var handlingSidebarSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Project")) // Localization unneeded: column identifier.
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.style = .sourceList
        outline.focusRingType = .none
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.doubleAction = #selector(openSelection(_:))
        outline.backgroundColor = .controlBackgroundColor
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; outline.menu = menu
        outline.setAccessibilityLabel(title.stringValue)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        addSubview(scroll)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        addSubview(title)
        emptyLabel.textColor = .secondaryLabelColor
        addSubview(emptyLabel)
        configure(addButton, title: String(localized: "ProjectSidebar.AddFolder", defaultValue: "Add Folder…", comment: "Choose a folder to add as a project"), image: .plus, action: #selector(addFolder(_:)))
        configure(currentButton, title: String(localized: "ProjectSidebar.AddCurrent", defaultValue: "Add Current Directory", comment: "Add current terminal directory as a project"), image: .folderBadgePlus, action: #selector(addCurrent(_:)))
        configure(removeButton, title: String(localized: "ProjectSidebar.Remove", defaultValue: "Remove Project", comment: "Remove selected project from the list"), image: .minus, action: #selector(remove(_:)))
        configure(refreshButton, title: String(localized: "ProjectSidebar.RefreshWorktrees", defaultValue: "Refresh Worktrees", comment: "Refresh registered repositories and worktree lists"), image: .arrowClockwise, action: #selector(refresh(_:)))
        currentButton.isEnabled = false
        removeButton.isEnabled = false
    }

    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    @nonobjc private func configure(_ button: NSButton, title: String, image: SFSymbol, action: Selector) {
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: image.rawValue, accessibilityDescription: nil)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isBordered = false
        button.controlSize = .small
        button.target = self
        button.action = action
        addSubview(button)
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 9, width: max(0, bounds.width - 121), height: 18)
        for (index, button) in [addButton, currentButton, removeButton, refreshButton].enumerated() {
            button.frame = NSRect(x: bounds.width - 8 - CGFloat(4 - index) * 25, y: 5, width: 24, height: 24)
        }
        scroll.frame = NSRect(x: 0, y: 34, width: bounds.width, height: max(0, bounds.height - 34))
        emptyLabel.frame = NSRect(x: 12, y: 48, width: max(0, bounds.width - 24), height: 60)
    }

    private var selectedNode: iTermProjectSidebarNode? { outline.item(atRow: outline.selectedRow) as? iTermProjectSidebarNode }
    private func publishTree() {
        if let tree, let publishedTree, tree.isEquivalent(to: publishedTree) { return }
        let headerSelection = selectedNode.flatMap { $0.kind == .repository ? $0.identifier : nil }
        updatingSelection = true
        publishedTree = tree
        expandedRepositories.formIntersection(Set(tree?.roots.compactMap { $0.repository?.identifier } ?? []))
        outline.reloadData()
        for node in tree?.roots ?? [] where expandedRepositories.contains(node.repository?.identifier ?? "") { outline.expandItem(node) }
        updatingSelection = false
        emptyLabel.isHidden = !(tree?.roots.isEmpty ?? true)
        if let headerSelection, let node = tree?.node(withIdentifier: headerSelection) {
            select(node)
        } else { updateSelection(reveal: false) }
    }

    private func select(_ node: iTermProjectSidebarNode?) {
        updatingSelection = true
        let row = node.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outline.deselectAll(nil) }
        updatingSelection = false
        updateRemoveButton()
    }

    private func updateSelection(reveal: Bool) {
        let preferred = preferredRepositoryIdentifier.flatMap { publishedTree?.node(withIdentifier: "repository:" + $0) }
        let node = handlingSidebarSelection && preferred != nil ? preferred : publishedTree?.selectionNode(
            projectIdentifier: selectedProjectIdentifier, worktreeIdentifier: selectedWorktreeIdentifier,
            preferredRepositoryIdentifier: preferredRepositoryIdentifier)
        if !handlingSidebarSelection, node?.identifier != preferred?.identifier { preferredRepositoryIdentifier = nil }
        if reveal, node?.kind == .worktree, let repository = node?.repository,
           let parent = publishedTree?.node(withIdentifier: "repository:" + repository.identifier) {
            updatingSelection = true
            if !outline.isItemExpanded(parent) { outline.expandItem(parent) }
            updatingSelection = false
        }
        select(node)
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = selectedNode?.kind == .folder || selectedNode?.kind == .repository
        let label = selectedNode?.kind == .repository
            ? String(localized: "ProjectSidebar.RemoveRepository", defaultValue: "Remove Repository from Sidebar", comment: "Remove repository registration without deleting worktrees")
            : String(localized: "ProjectSidebar.Remove", defaultValue: "Remove Project", comment: "Remove selected project from the list")
        if removeButton.toolTip != label { removeButton.toolTip = label; removeButton.setAccessibilityLabel(label) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? iTermProjectSidebarNode)?.children.count ?? publishedTree?.roots.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = (item as? iTermProjectSidebarNode)?.children ?? publishedTree?.roots ?? []
        guard children.indices.contains(index) else { it_assert(false, "Project outline requested an invalid child"); return NSNull() }
        return children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? iTermProjectSidebarNode else { return false }
        return !node.children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? iTermProjectSidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProjectSidebarCell") // Localization unneeded: reuse identifier.
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? iTermSidebarCellView ?? iTermSidebarCellView(frame: .zero)
        cell.identifier = identifier
        cell.configure(name: node.title, path: node.tooltip, image: node.hasError ? errorImage : (node.kind == .worktree ? branchImage : folderImage), folder: node.kind != .worktree)
        cell.textField?.font = .systemFont(ofSize: 12, weight: node.kind == .repository ? .semibold : .regular)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let node = selectedNode else { return }
        let keepOutlineFocus = window?.firstResponder === outline
        updateRemoveButton()
        select(node, openIfNeeded: false)
        // Selecting an existing project terminal restores that pane's focus. Keep keyboard
        // navigation in the list until the user explicitly opens or focuses a terminal.
        if keepOutlineFocus, !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow {
            window.makeFirstResponder(outline)
        }
    }
    @objc private func openSelection(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? iTermProjectSidebarNode else { return }
        select(node, openIfNeeded: true)
    }
    private func select(_ node: iTermProjectSidebarNode, openIfNeeded: Bool) {
        preferredRepositoryIdentifier = node.kind == .repository ? node.repository?.identifier : nil
        let wasHandlingSelection = handlingSidebarSelection
        handlingSidebarSelection = true
        defer { handlingSidebarSelection = wasHandlingSelection }
        if let worktree = node.worktree { delegate?.projectSidebar(self, didSelectWorktree: worktree, openIfNeeded: openIfNeeded) }
        else if let project = node.project { delegate?.projectSidebar(self, didSelectProject: project, openIfNeeded: openIfNeeded) }
        else if let repository = node.repository { delegate?.projectSidebar(self, didSelectRepository: repository, openIfNeeded: openIfNeeded) }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? iTermProjectSidebarNode, let repository = node.repository else { return }
        expandedRepositories.insert(repository.identifier)
        if !updatingSelection { scheduleRefresh([repository.identifier]) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? iTermProjectSidebarNode, let repository = node.repository else { return }
        expandedRepositories.remove(repository.identifier)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        menu.removeAllItems()
        guard let node = outline.item(atRow: row) as? iTermProjectSidebarNode else { return }
        let item = NSMenuItem(title: String(localized: "Projects.OpenTerminal", defaultValue: "Open Terminal", comment: "Project/worktree context menu for explicit terminal opening"), action: nil, keyEquivalent: "")
        let submenu = iTermProjectTerminalMenu.make(target: self, action: #selector(openTerminalWithStyle(_:)), includeShortcuts: true) { [weak self] style in
            self?.canOpenTerminal(node, style: style) == true
        }
        for choice in submenu.items { choice.representedObject = node }
        item.submenu = submenu
        menu.addItem(item)
        menu.addItem(.separator())
        let openDirectory = addMenuItem(to: menu, title: String(localized: "ProjectSidebar.OpenDirectory", defaultValue: "Open Directory in Finder", comment: "Open the clicked project, repository, or worktree directory in Finder"), action: #selector(openDirectory(_:)), node: node)
        let worktree = node.worktree ?? node.repository?.rootWorktree
        openDirectory.isEnabled = worktree?.available != false
        addMenuItem(to: menu, title: String(localized: "ProjectSidebar.CopyFullPath", defaultValue: "Copy Full Path", comment: "Copy the absolute directory path of the clicked sidebar item"), action: #selector(copyFullPath(_:)), node: node)
        if node.kind == .folder || node.kind == .repository {
            menu.addItem(.separator())
            let title = node.kind == .repository
                ? String(localized: "ProjectSidebar.RemoveRepository", defaultValue: "Remove Repository from Sidebar", comment: "Remove repository registration without deleting worktrees")
                : String(localized: "ProjectSidebar.Remove", defaultValue: "Remove Project", comment: "Remove selected project from the list")
            addMenuItem(to: menu, title: title, action: #selector(removeFromSidebar(_:)), node: node)
        } else if let worktree = node.worktree {
            menu.addItem(.separator())
            let canRemove = !worktree.isMain && !worktree.locked && worktree.available
            let removeDirectory = addMenuItem(to: menu, title: String(localized: "ProjectSidebar.DeleteWorktreeDirectory",
                defaultValue: "Delete Worktree Directory…", comment: "Delete the clicked linked worktree while keeping its branch"),
                action: #selector(removeWorktreeDirectory(_:)), node: node)
            removeDirectory.isEnabled = canRemove
            if worktree.branch != nil {
                let removeBranch = addMenuItem(to: menu, title: String(localized: "ProjectSidebar.DeleteWorktreeAndBranch",
                    defaultValue: "Delete Worktree and Branch…", comment: "Delete the clicked linked worktree and its local Git branch"),
                    action: #selector(removeWorktreeAndBranch(_:)), node: node)
                removeBranch.isEnabled = canRemove
            }
        }
    }

    @discardableResult private func addMenuItem(to menu: NSMenu, title: String, action: Selector, node: iTermProjectSidebarNode) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node
        menu.addItem(item)
        return item
    }

    private func directoryPath(for node: iTermProjectSidebarNode) -> String? {
        node.worktree?.rootDirectory ?? node.repository?.rootDirectory ?? node.project?.rootDirectory
    }

    @objc private func openDirectory(_ item: NSMenuItem) {
        guard item.isEnabled, let node = item.representedObject as? iTermProjectSidebarNode,
              let path = directoryPath(for: node) else { return }
        DLog("Open project sidebar directory \(path) in Finder")
        if !directoryOpener(URL(fileURLWithPath: path, isDirectory: true)) { NSSound.beep() }
    }

    @objc private func copyFullPath(_ item: NSMenuItem) {
        guard item.isEnabled, let node = item.representedObject as? iTermProjectSidebarNode,
              let path = directoryPath(for: node) else { return }
        pathPasteboard.clearContents()
        pathPasteboard.setString(path, forType: .string)
    }

    @objc private func removeFromSidebar(_ item: NSMenuItem) {
        guard item.isEnabled, let node = item.representedObject as? iTermProjectSidebarNode else { return }
        removeNode(node)
    }

    @objc private func removeWorktreeDirectory(_ item: NSMenuItem) { removeWorktree(item, deleteBranch: false) }
    @objc private func removeWorktreeAndBranch(_ item: NSMenuItem) { removeWorktree(item, deleteBranch: true) }

    private func removeWorktree(_ item: NSMenuItem, deleteBranch: Bool) {
        guard item.isEnabled, let node = item.representedObject as? iTermProjectSidebarNode,
              let worktree = node.worktree, let repository = node.repository,
              !worktree.isMain, !worktree.locked, worktree.available,
              !deleteBranch || worktree.branch != nil else { return }
        DLog("Request deletion of project sidebar worktree \(worktree.identifier), deleteBranch=\(deleteBranch)")
        delegate?.projectSidebar(self, removeWorktree: worktree, fromRepository: repository, deleteBranch: deleteBranch)
    }

    func menuWillOpen(_ menu: NSMenu) { terminalMenuIsTracking = true }
    func menuDidClose(_ menu: NSMenu) { terminalMenuIsTracking = false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !terminalMenuIsTracking, !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow,
              window.firstResponder === outline, let style = iTermProjectTerminalMenu.style(for: event) else { return false }
        if let node = selectedNode { openTerminal(node, style: style) }
        // A disabled mode or empty selection must not fall through and open in a different directory.
        return true
    }

    @objc private func openTerminalWithStyle(_ item: NSMenuItem) {
        guard item.isEnabled, item.tag >= 0, let style = iTermOpenStyle(rawValue: UInt(item.tag)),
              let node = item.representedObject as? iTermProjectSidebarNode else { return }
        openTerminal(node, style: style)
    }

    private func canOpenTerminal(_ node: iTermProjectSidebarNode, style: iTermOpenStyle) -> Bool {
        let worktree = node.worktree ?? node.repository?.rootWorktree
        return worktree?.available != false && delegate?.projectSidebar(self, canOpenTerminalWithStyle: style) == true
    }

    private func openTerminal(_ node: iTermProjectSidebarNode, style: iTermOpenStyle) {
        guard canOpenTerminal(node, style: style) else { return }
        DLog("Open project sidebar node \(node.identifier) with style \(style.rawValue)")
        if let worktree = node.worktree { delegate?.projectSidebar(self, openWorktree: worktree, style: style) }
        else if let project = node.project { delegate?.projectSidebar(self, openProject: project, style: style) }
        else if let repository = node.repository { delegate?.projectSidebar(self, openRepository: repository, style: style) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateVisibility() })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateVisibility() })
            }
        }
        updateVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateSelection(reveal: true); updateVisibility() }
    private var visible: Bool {
        !isHiddenOrHasHiddenAncestor && window?.isVisible == true && window?.isMiniaturized == false &&
            window?.occlusionState.contains(.visible) == true && NSApp.isActive
    }
    private func updateVisibility() {
        guard visible else { refreshTimer?.invalidate(); refreshTimer = nil; return }
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.visible, !self.expandedRepositories.isEmpty else { return }
            self.delegate?.projectSidebar(self, refreshRepositories: Array(self.expandedRepositories))
        }
        scheduleRefresh(nil)
    }
    private func scheduleRefresh(_ identifiers: [String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visible else { return }
            self.delegate?.projectSidebar(self, refreshRepositories: identifiers)
        }
    }
    deinit {
        refreshTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    @objc private func addFolder(_ sender: Any?) { delegate?.projectSidebarAddFolder(self) }
    @objc private func addCurrent(_ sender: Any?) { delegate?.projectSidebarAddCurrentDirectory(self) }
    @objc private func refresh(_ sender: Any?) { delegate?.projectSidebar(self, refreshRepositories: nil) }
    @objc private func remove(_ sender: Any?) {
        guard let node = selectedNode else { return }
        removeNode(node)
    }
    private func removeNode(_ node: iTermProjectSidebarNode) {
        DLog("Remove project sidebar node \(node.identifier)")
        if node.kind == .folder, let project = node.project { delegate?.projectSidebar(self, removeProject: project) }
        else if node.kind == .repository, let repository = node.repository { delegate?.projectSidebar(self, removeRepository: repository) }
    }
}

private final class iTermProjectSidebarOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        // Mouse context menus must target a row. Keyboard menus can use the selection.
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard row(at: convert(event.locationInWindow, from: nil)) >= 0 else { return nil }
        default:
            break
        }
        return super.menu(for: event)
    }
}
