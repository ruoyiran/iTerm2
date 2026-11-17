import AppKit
import XCTest
@testable import iTerm2SharedARC

final class ProjectSidebarTerminalShortcutTests: XCTestCase {
    private final class Window: NSWindow {
        var key = true
        override var isKeyWindow: Bool { key }
    }

    private final class Scanner: iTermGitWorktreeScanning {
        var snapshot: iTermGitRepositorySnapshot?
        func scan(directory: String, completion: @escaping (iTermGitRepositorySnapshot?, NSError?) -> Void) { completion(snapshot, nil) }
    }

    private final class Delegate: NSObject, iTermProjectSidebarDelegate {
        var opened = [(directory: String, style: iTermOpenStyle)]()
        var disabled = Set<UInt>()
        var didSelect: (() -> Void)?
        var removedProjects = [String]()
        var removedRepositories = [String]()
        func projectSidebar(_ sidebar: iTermProjectSidebarView, didSelectProject project: iTermProjectDirectory, openIfNeeded: Bool) { didSelect?() }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, didSelectWorktree worktree: iTermGitWorktree, openIfNeeded: Bool) { didSelect?() }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, didSelectRepository repository: iTermGitRepositorySnapshot, openIfNeeded: Bool) { didSelect?() }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, openProject project: iTermProjectDirectory, style: iTermOpenStyle) { opened.append((project.rootDirectory, style)) }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, openRepository repository: iTermGitRepositorySnapshot, style: iTermOpenStyle) { opened.append((repository.rootDirectory, style)) }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, openWorktree worktree: iTermGitWorktree, style: iTermOpenStyle) { opened.append((worktree.rootDirectory, style)) }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, canOpenTerminalWithStyle style: iTermOpenStyle) -> Bool { !disabled.contains(UInt(style.rawValue)) }
        func projectSidebarAddFolder(_ sidebar: iTermProjectSidebarView) {}
        func projectSidebarAddCurrentDirectory(_ sidebar: iTermProjectSidebarView) {}
        func projectSidebar(_ sidebar: iTermProjectSidebarView, removeProject project: iTermProjectDirectory) { removedProjects.append(project.identifier) }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, removeRepository repository: iTermGitRepositorySnapshot) { removedRepositories.append(repository.identifier) }
        func projectSidebar(_ sidebar: iTermProjectSidebarView, refreshRepositories identifiers: [String]?) {}
    }

    private func fixture() -> (Window, iTermProjectSidebarView, NSOutlineView, Delegate) {
        _ = NSApplication.shared
        let name = "ProjectSidebarTerminalShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set([
            ["identifier": "11111111-1111-1111-1111-111111111111", "rootDirectory": "/tmp"],
            ["identifier": "22222222-2222-2222-2222-222222222222", "rootDirectory": "/var"]
        ], forKey: iTermProjectCatalog.defaultsKey)
        let sidebar = iTermProjectSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let pasteboard = NSPasteboard(name: .init(name))
        sidebar.pathPasteboard = pasteboard
        addTeardownBlock { pasteboard.releaseGlobally() }
        sidebar.tree = iTermProjectSidebarTree(catalog: iTermProjectCatalog(defaults: defaults))
        sidebar.selectedProjectIdentifier = "11111111-1111-1111-1111-111111111111"
        let outline = sidebar.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSOutlineView }.first!
        let delegate = Delegate()
        sidebar.delegate = delegate
        let window = Window(contentRect: sidebar.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        window.makeFirstResponder(outline)
        return (window, sidebar, outline, delegate)
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    func testStandardShortcutsOpenSelectedDirectoryInEachMode() {
        let (window, sidebar, _, delegate) = fixture()
        defer { window.close() }
        let cases: [(String, NSEvent.ModifierFlags, iTermOpenStyle)] = [
            ("t", .command, .tab), ("n", .command, .window),
            ("d", .command, .verticalSplit), ("D", [.command, .shift], .horizontalSplit)
        ]
        for (characters, flags, style) in cases {
            XCTAssertTrue(sidebar.performKeyEquivalent(with: key(characters, flags)))
            XCTAssertEqual(delegate.opened.last?.directory, "/tmp")
            XCTAssertEqual(delegate.opened.last?.style, style)
        }
        XCTAssertEqual(delegate.opened.count, 4)
    }

    func testMenuShowsShortcutsAndCapturesItsOwnDirectory() throws {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        let menu = try XCTUnwrap(outline.menu)
        sidebar.menuNeedsUpdate(menu)
        let oldItems = try XCTUnwrap(menu.items.first?.submenu).items
        XCTAssertEqual(oldItems.map(\.keyEquivalent), ["t", "d", "D", "n"])
        XCTAssertEqual(oldItems.map(\.keyEquivalentModifierMask), [.command, .command, [.command, .shift], .command])
        sidebar.selectedProjectIdentifier = "22222222-2222-2222-2222-222222222222"
        sidebar.menuNeedsUpdate(menu)
        let oldItem = oldItems[0]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(oldItem.action), to: oldItem.target, from: oldItem))
        XCTAssertEqual(delegate.opened.last?.directory, "/tmp")
        XCTAssertTrue(sidebar.performKeyEquivalent(with: key("t")))
        XCTAssertEqual(delegate.opened.last?.directory, "/var")
    }

    func testDirectoryActionsCaptureTheMenuProject() throws {
        let (window, sidebar, outline, _) = fixture()
        defer { window.close() }
        var openedURLs = [URL]()
        sidebar.directoryOpener = { openedURLs.append($0); return true }
        sidebar.pathPasteboard.setString("previous clipboard contents", forType: .string)
        let menu = try XCTUnwrap(outline.menu)
        sidebar.menuNeedsUpdate(menu)
        let items = menu.items
        sidebar.selectedProjectIdentifier = "22222222-2222-2222-2222-222222222222"
        sidebar.menuNeedsUpdate(menu)
        for selector in ["openDirectory:", "copyFullPath:", "removeFromSidebar:"] {
            let item = try XCTUnwrap(items.first { $0.action == NSSelectorFromString(selector) })
            XCTAssertTrue(item.isEnabled)
            let node = try XCTUnwrap(item.representedObject as? iTermProjectSidebarNode)
            XCTAssertEqual(node.project?.rootDirectory, "/tmp")
            if selector != "removeFromSidebar:" {
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            }
        }
        XCTAssertEqual(openedURLs, [URL(fileURLWithPath: "/tmp", isDirectory: true)])
        XCTAssertEqual(sidebar.pathPasteboard.string(forType: .string), "/tmp")
    }

    func testRemoveFromContextMenuUsesCapturedProjectAfterSelectionChanges() throws {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        let menu = try XCTUnwrap(outline.menu)
        sidebar.menuNeedsUpdate(menu)
        let remove = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("removeFromSidebar:") })
        sidebar.selectedProjectIdentifier = "22222222-2222-2222-2222-222222222222"
        sidebar.menuNeedsUpdate(menu)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
        XCTAssertEqual(delegate.removedProjects, ["11111111-1111-1111-1111-111111111111"])
        XCTAssertTrue(delegate.removedRepositories.isEmpty)
    }

    func testContextMenuIsEmptyWithoutADirectorySelection() throws {
        let (window, sidebar, outline, _) = fixture()
        defer { window.close() }
        outline.deselectAll(nil)
        let menu = try XCTUnwrap(outline.menu)
        sidebar.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty)
    }

    func testRightClickMenuUsesClickedDirectoryInsteadOfSelection() throws {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        let rect = outline.rect(ofRow: 1)
        let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(outline.menu(for: event))
        sidebar.menuNeedsUpdate(menu)
        let remove = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("removeFromSidebar:") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
        XCTAssertEqual(delegate.removedProjects, ["22222222-2222-2222-2222-222222222222"])
    }

    func testRightClickOnBackgroundDoesNotOfferActionsForSelectedProject() throws {
        let (window, sidebar, outline, _) = fixture()
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        let location = outline.convert(NSPoint(x: 20, y: 150), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        if let menu = outline.menu(for: event) {
            sidebar.menuNeedsUpdate(menu)
            XCTAssertTrue(menu.items.isEmpty)
        }
    }

    func testSingleSelectionKeepsOutlineFocusAfterSwitchingTerminal() {
        let (window, sidebar, outline, _) = fixture()
        defer { window.close() }
        let delegate = Delegate()
        sidebar.delegate = delegate
        let terminal = NSTextView()
        sidebar.addSubview(terminal)
        delegate.didSelect = { window.makeFirstResponder(terminal) }
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertTrue(sidebar.performKeyEquivalent(with: key("n")))
        XCTAssertEqual(delegate.opened.last?.directory, "/var")
    }

    func testTrackingMenuUsesItsDirectoryForEachShortcut() throws {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        let menu = try XCTUnwrap(outline.menu)
        sidebar.menuNeedsUpdate(menu)
        let submenu = try XCTUnwrap(menu.items.first?.submenu)
        sidebar.selectedProjectIdentifier = "22222222-2222-2222-2222-222222222222"
        sidebar.menuWillOpen(menu)
        let cases: [(String, NSEvent.ModifierFlags, iTermOpenStyle)] = [
            ("t", .command, .tab), ("n", .command, .window),
            ("d", .command, .verticalSplit), ("D", [.command, .shift], .horizontalSplit)
        ]
        for (characters, flags, style) in cases {
            let event = key(characters, flags)
            XCTAssertFalse(sidebar.performKeyEquivalent(with: event))
            XCTAssertTrue(submenu.performKeyEquivalent(with: event))
            XCTAssertEqual(delegate.opened.last?.directory, "/tmp")
            XCTAssertEqual(delegate.opened.last?.style, style)
        }
        sidebar.menuDidClose(menu)
        XCTAssertTrue(sidebar.performKeyEquivalent(with: key("t")))
        XCTAssertEqual(delegate.opened.last?.directory, "/var")
    }

    func testDisabledModeDoesNotFallThroughToOrdinaryTerminalCreation() {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        delegate.disabled.insert(UInt(iTermOpenStyle.verticalSplit.rawValue))
        sidebar.menuNeedsUpdate(outline.menu!)
        XCTAssertFalse(outline.menu!.items[0].submenu!.items[1].isEnabled)
        XCTAssertTrue(sidebar.performKeyEquivalent(with: key("d")))
        XCTAssertTrue(delegate.opened.isEmpty)
        outline.deselectAll(nil)
        XCTAssertTrue(sidebar.performKeyEquivalent(with: key("t")))
        XCTAssertTrue(delegate.opened.isEmpty)
    }

    func testRepositoryAndWorktreeShortcutsUseTheirDisplayedRoot() throws {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let main = base.appendingPathComponent("main")
        let linked = base.appendingPathComponent("linked worktree 中文")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        let scanner = Scanner()
        scanner.snapshot = .init(commonDirectory: main.path + "/.git", rootDirectory: main.path, worktrees: [
            .init(rootDirectory: main.path, branch: "main", head: "a", isMain: true),
            .init(rootDirectory: linked.path, branch: "feature", head: "b", isMain: false)
        ])
        let name = "ProjectSidebarTerminalShortcutGitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set([["identifier": "11111111-1111-1111-1111-111111111111", "rootDirectory": main.path + "/sub",
                       "gitCommonDirectory": main.path + "/.git", "gitRepositoryRoot": main.path,
                       "gitWorktreeDirectory": main.path]], forKey: iTermProjectCatalog.defaultsKey)
        let catalog = iTermProjectCatalog(defaults: defaults, scanner: scanner)
        let ready = expectation(description: "repository metadata")
        catalog.refreshProject(withIdentifier: catalog.projects[0].identifier) { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let tree = iTermProjectSidebarTree(catalog: catalog)
        sidebar.tree = tree
        let repository = try XCTUnwrap(tree.roots.first)
        let worktree = try XCTUnwrap(repository.children.first { $0.worktree?.rootDirectory == linked.path })
        var openedURLs = [URL]()
        sidebar.directoryOpener = { openedURLs.append($0); return true }
        outline.expandItem(repository)
        for (node, path) in [(repository, main.path), (worktree, linked.path)] {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
            for (event, style) in [(key("t"), iTermOpenStyle.tab), (key("n"), .window),
                                   (key("d"), .verticalSplit), (key("D", [.command, .shift]), .horizontalSplit)] {
                XCTAssertTrue(sidebar.performKeyEquivalent(with: event))
                XCTAssertEqual(delegate.opened.last?.directory, path)
                XCTAssertEqual(delegate.opened.last?.style, style)
            }
            let menu = try XCTUnwrap(outline.menu)
            sidebar.menuNeedsUpdate(menu)
            let open = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("openDirectory:") })
            let copy = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("copyFullPath:") })
            let remove = menu.items.first { $0.action == NSSelectorFromString("removeFromSidebar:") }
            outline.deselectAll(nil)
            for item in [open, copy] {
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            }
            XCTAssertEqual(openedURLs.last?.path, path)
            XCTAssertEqual(openedURLs.last?.isFileURL, true)
            XCTAssertEqual(sidebar.pathPasteboard.string(forType: .string), path)
            if node.kind == .repository {
                let remove = try XCTUnwrap(remove)
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
                XCTAssertEqual(delegate.removedRepositories, [main.path + "/.git"])
                XCTAssertTrue(delegate.removedProjects.isEmpty)
                XCTAssertTrue(FileManager.default.fileExists(atPath: main.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
            } else {
                XCTAssertNil(remove)
            }
        }
        XCTAssertEqual(delegate.opened.count, 8)
        scanner.snapshot = .init(commonDirectory: main.path + "/.git", rootDirectory: main.path, worktrees: [
            .init(rootDirectory: main.path, branch: "main", head: "a", isMain: true, available: false)
        ])
        let unavailable = expectation(description: "unavailable repository root")
        catalog.refreshProject(withIdentifier: catalog.projects[0].identifier) { _ in unavailable.fulfill() }
        wait(for: [unavailable], timeout: 5)
        sidebar.tree = iTermProjectSidebarTree(catalog: catalog)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sidebar.menuNeedsUpdate(outline.menu!)
        XCTAssertTrue(outline.menu!.items[0].submenu!.items.allSatisfy { !$0.isEnabled })
        let unavailableOpen = try XCTUnwrap(outline.menu!.items.first { $0.action == NSSelectorFromString("openDirectory:") })
        XCTAssertFalse(unavailableOpen.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(unavailableOpen.action), to: unavailableOpen.target, from: unavailableOpen))
        XCTAssertEqual(openedURLs.count, 2)
        let copy = try XCTUnwrap(outline.menu!.items.first { $0.action == NSSelectorFromString("copyFullPath:") })
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(sidebar.pathPasteboard.string(forType: .string), main.path)
        XCTAssertTrue(sidebar.performKeyEquivalent(with: key("t")))
        XCTAssertEqual(delegate.opened.count, 8)
    }

    func testShortcutsDoNotClaimEventsOutsideDirectoryList() {
        let (window, sidebar, outline, delegate) = fixture()
        defer { window.close() }
        let terminal = NSTextView()
        sidebar.addSubview(terminal)
        window.makeFirstResponder(terminal)
        XCTAssertFalse(sidebar.performKeyEquivalent(with: key("t")))
        window.makeFirstResponder(outline)
        sidebar.isHidden = true
        XCTAssertFalse(sidebar.performKeyEquivalent(with: key("n")))
        sidebar.isHidden = false
        window.makeFirstResponder(outline)
        window.key = false
        XCTAssertFalse(sidebar.performKeyEquivalent(with: key("d")))
        window.key = true
        let leaderFlag = NSEvent.ModifierFlags(rawValue: iTermEventModifierFlags.leaderModifierFlag.rawValue)
        for event in [key("t", [.command, .option]), key("d", [.command, .control]), key("x"), key("t", []),
                      key("t", [.command, leaderFlag]), key("D", [.command, .shift, leaderFlag])] {
            XCTAssertFalse(sidebar.performKeyEquivalent(with: event))
        }
        XCTAssertTrue(delegate.opened.isEmpty)
    }
}
