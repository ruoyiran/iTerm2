import AppKit
import XCTest
@testable import iTerm2SharedARC

final class SidebarWorkspaceIntegrationTests: XCTestCase {
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
