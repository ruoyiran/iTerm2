import AppKit
import XCTest
@testable import iTerm2SharedARC

final class SidebarWorkspaceIntegrationTests: XCTestCase {
    func testFindInFilesRestoresProjectRootAfterFolderScopedSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subfolder = root.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = iTermSidebarWorkspaceContentStore()
        defer { store.shutdown() }
        let context = iTermFileBrowserContext(rootDirectory: root.path, projectIdentifier: "project",
                                             worktreeIdentifier: "worktree", generation: 1)
        let item = iTermSidebarWorkspaceItem(identifier: "files", title: "Files", kind: "files",
                                            sessionIdentifier: nil, state: ["rootDirectory": root.path])
        let view = try XCTUnwrap(store.view(for: item, context: context))
        let controller = try XCTUnwrap(view.nextResponder as? iTermFileBrowserViewController)
        let explorer = try XCTUnwrap(controller.delegate as? iTermFileBrowserCoordinator)
        explorer.applyContext(iTermFileBrowserContext(rootDirectory: subfolder.path, projectIdentifier: "project",
                                                     worktreeIdentifier: "worktree", generation: 2))
        _ = store.findInFiles("original", item: item, context: context)
        XCTAssertEqual(explorer.context?.rootDirectory, root.path)
        XCTAssertEqual(explorer.context?.projectIdentifier, "project")
        XCTAssertEqual(explorer.context?.worktreeIdentifier, "worktree")
    }

    func testRightCornerButtonReturnsFromToolsToWorkspaceAndKeepsTabs() throws {
        try OnscreenTestGate.skipUnlessEnabled()
        let fixture = TerminalWindowTestFixture()
        defer { fixture.close() }
        fixture.window.setFrame(NSRect(x: 50, y: 50, width: 1200, height: 800), display: true)
        let root = try XCTUnwrap(fixture.window.contentView)
        let workspace = try XCTUnwrap(root.value(forKey: "sidebarWorkspace") as? iTermSidebarWorkspaceView)
        let tab = try XCTUnwrap(fixture.terminal.currentTab())
        tab.sidebarWorkspaceState.appendItem(iTermSidebarWorkspaceItem(
            identifier: "saved-browser", title: "Saved Browser", kind: "home", sessionIdentifier: nil,
            state: ["url": "https://example.test"]))
        workspace.delegate?.sidebarWorkspaceViewDidRequestTools(workspace)
        XCTAssertEqual(root.value(forKey: "shouldShowToolbelt") as? Bool, true)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap { buttons(in: $0) }
        }
        let button = try XCTUnwrap(buttons(in: root).first { $0.action == NSSelectorFromString("toggleFileTree:") })
        button.performClick(nil)
        XCTAssertTrue(tab.sidebarWorkspaceState.visible)
        XCTAssertEqual(root.value(forKey: "shouldShowSidebarWorkspace") as? Bool, true)
        XCTAssertEqual(root.value(forKey: "shouldShowToolbelt") as? Bool, false)
        XCTAssertTrue(tab.sidebarWorkspaceState.items.contains { $0.kind == "files" })
        button.performClick(nil)
        XCTAssertFalse(tab.sidebarWorkspaceState.visible)
        XCTAssertEqual(tab.sidebarWorkspaceState.selectedIdentifier, "saved-browser")
        XCTAssertEqual(tab.sidebarWorkspaceState.items.first?.state["url"] as? String, "https://example.test")
        button.performClick(nil)
        XCTAssertEqual(root.value(forKey: "shouldShowSidebarWorkspace") as? Bool, true)
        XCTAssertEqual(tab.sidebarWorkspaceState.items.count, 2)
    }

    func testSidebarBrowserProfilePreservesPrivateOriginProfileOwnership() throws {
        guard PseudoTerminal.responds(to: NSSelectorFromString("sidebarBrowserProfile:url:")) else {
            XCTFail("Sidebar browser profile construction must preserve its origin’s profile owner")
            return
        }
        let primary = try XCTUnwrap(PTYSession(synthetic: false))
        primary.profile = try XCTUnwrap(ProfileModel.sharedInstance().defaultBookmark())
        let privateGUID = try XCTUnwrap(primary.divorceAddressBookEntryFromPreferences())
        defer { primary.remarry() }
        let model = try XCTUnwrap(ProfileModel.sessionsInstance())
        let original = try XCTUnwrap(model.bookmark(withGuid: privateGUID))
        let browser = try XCTUnwrap(PTYSession(synthetic: false))
        browser.profile = PseudoTerminal.sidebarBrowserProfile(primary.profile, url: URL(string: "https://example.test")!)
        defer { browser.remarry() }
        XCTAssertNotEqual(browser.profile?[KEY_GUID] as? String, privateGUID)
        XCTAssertEqual(browser.profile?[KEY_CUSTOM_COMMAND] as? String, kProfilePreferenceCommandTypeBrowserValue)
        browser.setSessionSpecificProfileValues([KEY_NAME: "Sidebar Browser"])
        XCTAssertEqual(model.bookmark(withGuid: privateGUID) as? NSDictionary, original as NSDictionary)
        XCTAssertEqual(primary.profile?[KEY_GUID] as? String, privateGUID)
    }

    func testSidebarLayoutKeepsTerminalTextViewAndScreenContents() throws {
        try OnscreenTestGate.skipUnlessEnabled()
        let fixture = TerminalWindowTestFixture()
        defer { fixture.close() }
        fixture.window.setFrame(NSRect(x: 50, y: 50, width: 1200, height: 800), display: true)
        let tab = try XCTUnwrap(fixture.terminal.currentTab())
        let primary = try XCTUnwrap(tab.activeSession)
        let sidebar = try XCTUnwrap(PTYSession(synthetic: false))
        sidebar.profile = primary.profile
        fixture.terminal.setupSession(sidebar, with: nil)
        tab.installSidebarSession(sidebar)
        defer { sidebar.terminate() }
        let originalPrimaryTextView = try XCTUnwrap(primary.textview)
        let originalSidebarTextView = try XCTUnwrap(sidebar.textview)
        for (session, marker) in [(primary, "PRIMARY-CONTENT"), (sidebar, "SIDEBAR-CONTENT")] {
            session.screen.inject(Data(marker.utf8))
            session.screen.waitForQueuedTokensForTesting()
        }
        fixture.terminal.selectSidebarSession(sidebar)
        fixture.window.setFrame(NSRect(x: 50, y: 50, width: 1100, height: 750), display: true)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(primary.textview === originalPrimaryTextView)
        XCTAssertTrue(sidebar.textview === originalSidebarTextView)
        for (session, marker) in [(primary, "PRIMARY-CONTENT"), (sidebar, "SIDEBAR-CONTENT")] {
            let line = session.screen.screenCharArray(atScreenIndex: 0)
            XCTAssertTrue(ScreenCharArrayToStringDebug(line.line, session.screen.width())?.contains(marker) == true)
        }
    }

    func testTerminalCardCreatesLocalProfileWithoutChangingDefault() {
        for kind in [kProfilePreferenceCommandTypeBrowserValue, kProfilePreferenceCommandTypeSSHValue, "Yes"] {
            let original: [AnyHashable: Any] = [KEY_CUSTOM_COMMAND: kind, KEY_COMMAND_LINE: "ssh remote.example",
                                              KEY_SSH_CONFIG: ["host": "remote.example"], KEY_INITIAL_TEXT: "ssh another.example\n",
                                              KEY_NAME: "Appearance to preserve"]
            let local = PseudoTerminal.localSidebarTerminalProfile(original)
            XCTAssertEqual(local?[KEY_CUSTOM_COMMAND] as? String, kProfilePreferenceCommandTypeLoginShellValue)
            XCTAssertNil(local?[KEY_COMMAND_LINE])
            XCTAssertNil(local?[KEY_SSH_CONFIG])
            XCTAssertEqual(local?[KEY_INITIAL_TEXT] as? String, "")
            XCTAssertEqual(local?[KEY_NAME] as? String, "Appearance to preserve")
            XCTAssertEqual(original[KEY_CUSTOM_COMMAND] as? String, kind)
            XCTAssertEqual(original[KEY_COMMAND_LINE] as? String, "ssh remote.example")
        }
    }

    func testSidebarFocusAndReturnToUnchangedPrimaryPublishTransitions() throws {
        try OnscreenTestGate.skipUnlessEnabled()
        let fixture = TerminalWindowTestFixture()
        defer { fixture.close() }
        let tab = try XCTUnwrap(fixture.terminal.currentTab())
        let primary = try XCTUnwrap(tab.activeSession)
        let sidebar = try XCTUnwrap(PTYSession(synthetic: false))
        sidebar.profile = primary.profile
        fixture.terminal.setupSession(sidebar, with: nil)
        tab.installSidebarSession(sidebar)
        var focusChanges: [PTYSession] = []
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("iTermSessionBecameKey"), object: nil, queue: .main) { note in
            guard let changed = note.userInfo?["changed"] as? Bool, changed,
                  let session = note.object as? PTYSession else { return }
            focusChanges.append(session)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.terminal.selectSidebarSession(sidebar)
        XCTAssertTrue(tab.activeSession === primary)
        XCTAssertTrue(fixture.terminal.currentSession() === sidebar)
        XCTAssertTrue(focusChanges.contains { $0 === sidebar })
        XCTAssertTrue(fixture.window.makeFirstResponder(primary.mainResponder))
        XCTAssertTrue(fixture.terminal.currentSession() === primary)
        XCTAssertTrue(focusChanges.contains { $0 === primary })
        XCTAssertTrue(tab.activeSession === primary)
        sidebar.terminate()
    }
}
