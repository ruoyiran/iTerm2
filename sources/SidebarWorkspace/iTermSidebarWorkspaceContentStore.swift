import AppKit

/// Non-session sidebar content is retained by item identity, independently of window focus.
@objcMembers final class iTermSidebarWorkspaceContentStore: NSObject {
    var fileRequest: ((iTermFileBrowserRequest) -> Void)?
    private var explorers = [String: iTermFileBrowserCoordinator]()
    private var changes = [String: SidebarGitChangesView]()
    private var visibleIdentifier: String?

    @objc(viewForItem:context:)
    func view(for item: iTermSidebarWorkspaceItem, context: iTermFileBrowserContext) -> NSView? {
        switch item.kind {
        case "files":
            var created = false
            if explorers[item.identifier] == nil {
                let explorer = iTermFileBrowserCoordinator(native: iTermFileWorkspaceService.bootstrap().coordinator)
                explorer.applyContext(context)
                explorer.nativeRequest = { [weak self] request in self?.fileRequest?(request) }
                explorers[item.identifier] = explorer
                created = true
            }
            explorers[item.identifier]?.setVisible(item.identifier == visibleIdentifier)
            if created, let query = item.state["contentQuery"] as? String {
                explorers[item.identifier]?.controller.focusQuery(contents: true, query: query)
            }
            return explorers[item.identifier]?.controller.view
        case "changes":
            if changes[item.identifier] == nil { changes[item.identifier] = SidebarGitChangesView(context: context) }
            return changes[item.identifier]
        default: return nil
        }
    }

    @objc(findInFiles:item:context:)
    func findInFiles(_ query: String, item: iTermSidebarWorkspaceItem, context: iTermFileBrowserContext) -> NSResponder? {
        _ = view(for: item, context: context)
        guard let explorer = explorers[item.identifier] else { return nil }
        explorer.applyContext(context)
        explorer.controller.focusQuery(contents: true, query: query)
        return explorer.controller.preferredFirstResponder
    }

    @objc(setVisibleItemIdentifier:)
    func setVisibleItemIdentifier(_ identifier: String?) {
        visibleIdentifier = identifier
        for (id, explorer) in explorers { explorer.setVisible(id == identifier) }
        for (id, view) in changes { view.setVisible(id == identifier) }
    }

    @objc(pruneKeepingItemIdentifiers:)
    func prune(keeping identifiers: [String]) {
        let live = Set(identifiers)
        for id in Array(explorers.keys) where !live.contains(id) { explorers.removeValue(forKey: id)?.shutdown() }
        for id in Array(changes.keys) where !live.contains(id) { changes.removeValue(forKey: id)?.shutdown() }
    }

    func shutdown() {
        explorers.values.forEach { $0.shutdown() }; explorers.removeAll()
        changes.values.forEach { $0.shutdown() }; changes.removeAll()
        fileRequest = nil
    }
}

private final class SidebarGitChangesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let context: iTermFileBrowserContext
    private let table = NSTableView()
    private let list = NSScrollView()
    private let original = NSTextView()
    private let modified = NSTextView()
    private let originalScroll = NSScrollView()
    private let modifiedScroll = NSScrollView()
    private let comparison = NSSplitView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton()
    private let queue = DispatchQueue(label: "com.iterm2.sidebar-git", qos: .userInitiated)
    private var entries = [[String: Any]]()
    private var generation: UInt64 = 0
    private var visible = false
    private var stopped = false
    private var loaded = false

    init(context: iTermFileBrowserContext) {
        self.context = context
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("changes")) // Localization unneeded.
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 26
        table.delegate = self; table.dataSource = self; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        list.documentView = table; list.hasVerticalScroller = true
        addSubview(list)
        for (text, scroll) in [(original, originalScroll), (modified, modifiedScroll)] {
            text.isEditable = false; text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            scroll.documentView = text; scroll.hasVerticalScroller = true
            comparison.addArrangedSubview(scroll)
        }
        original.setAccessibilityLabel(String(localized: "SidebarWorkspace.Original", defaultValue: "Original contents", comment: "Original side of a read-only file comparison"))
        modified.setAccessibilityLabel(String(localized: "SidebarWorkspace.Modified", defaultValue: "Modified contents", comment: "Modified side of a read-only file comparison"))
        comparison.isVertical = true; comparison.dividerStyle = .thin
        addSubview(comparison); addSubview(status)
        refreshButton.title = String(localized: "SidebarWorkspace.RefreshChanges", defaultValue: "Refresh", comment: "Refresh local Git changes")
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        addSubview(refreshButton)
        status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "SidebarWorkspace.SelectChange", defaultValue: "Select a changed file to compare its original and modified contents.", comment: "Git changes empty selection instruction")
    }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        refreshButton.frame = NSRect(x: max(8, bounds.width - 88), y: 8, width: 80, height: 28)
        status.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - 108), height: 48)
        let listHeight = min(200, max(60, bounds.height * 0.3))
        list.frame = NSRect(x: 0, y: 60, width: bounds.width, height: listHeight)
        comparison.frame = NSRect(x: 0, y: 60 + listHeight, width: bounds.width, height: max(0, bounds.height - 60 - listHeight))
        comparison.adjustSubviews()
        original.frame.size.width = originalScroll.contentSize.width
        modified.frame.size.width = modifiedScroll.contentSize.width
    }
    func setVisible(_ value: Bool) {
        visible = value
        if value && !loaded { refresh() }
        if !value { generation &+= 1 }
    }
    func shutdown() { stopped = true; generation &+= 1 }
    @objc private func refresh() {
        guard !stopped, visible else { return }
        generation &+= 1
        let expected = generation, root = context.rootDirectory
        status.stringValue = String(localized: "SidebarWorkspace.LoadingChanges", defaultValue: "Loading changes…", comment: "Git status loading indicator")
        queue.async { [weak self] in
            let result = Result { try FileGitContentService(rootDirectory: root).status() }
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.visible, self.generation == expected else { return }
                self.loaded = true
                switch result {
                case .success(let entries):
                    self.entries = entries; self.table.reloadData()
                    self.status.stringValue = entries.isEmpty ? String(localized: "SidebarWorkspace.NoChanges", defaultValue: "No local changes.", comment: "Clean local repository status") : root
                case .failure:
                    self.entries = []; self.table.reloadData()
                    self.status.stringValue = String(localized: "SidebarWorkspace.GitUnavailable", defaultValue: "This directory is not an available Git repository.", comment: "Repository missing or no longer accessible")
                }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let path = entry["path"] as? String ?? ""
        let area = entry["area"] as? String ?? "unstaged" // Localization unneeded: Git contract values.
        let label: String
        switch area {
        case "staged": label = String(localized: "SidebarWorkspace.StagedFile", defaultValue: "Staged: \(path)", comment: "Staged change row; placeholder is a file path")
        case "untracked": label = String(localized: "SidebarWorkspace.UntrackedFile", defaultValue: "Untracked: \(path)", comment: "Untracked change row; placeholder is a file path")
        default: label = String(localized: "SidebarWorkspace.UnstagedFile", defaultValue: "Unstaged: \(path)", comment: "Unstaged change row; placeholder is a file path")
        }
        let field = NSTextField(labelWithString: label); field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 12); return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard entries.indices.contains(row), visible, !stopped else { return }
        let entry = entries[row], root = context.rootDirectory
        guard let relative = entry["path"] as? String else { return }
        let path = (root as NSString).appendingPathComponent(relative)
        let source = entry["area"] as? String == "staged" ? "staged" : "unstaged" // Localization unneeded.
        generation &+= 1; let expected = generation
        queue.async { [weak self] in
            let result = Result { try FileGitContentService(rootDirectory: root).diff(path, source: source) }
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.visible, self.generation == expected else { return }
                switch result {
                case .success(let diff):
                    guard diff["kind"] as? String == "text", let old = diff["originalContent"] as? String,
                          let new = diff["modifiedContent"] as? String, old.utf8.count + new.utf8.count <= 400_000 else {
                        self.original.string = ""; self.modified.string = ""
                        self.status.stringValue = String(localized: "SidebarWorkspace.BinaryDiff", defaultValue: "This binary or large file cannot be displayed as a text comparison.", comment: "Read-only comparison limitation")
                        return
                    }
                    self.original.string = old; self.modified.string = new; self.status.stringValue = relative
                case .failure:
                    self.original.string = ""; self.modified.string = ""
                    self.status.stringValue = String(localized: "SidebarWorkspace.DiffUnavailable", defaultValue: "The file comparison is no longer available. Refresh the changes list.", comment: "Changed or deleted repository diff could not be read")
                }
            }
        }
    }
}
