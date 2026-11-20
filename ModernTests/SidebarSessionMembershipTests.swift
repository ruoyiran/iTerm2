import XCTest
@testable import iTerm2SharedARC

final class SidebarSessionMembershipTests: XCTestCase {
    func testSidebarCollectionDoesNotBecomeTiledAndOwnsDelegate() throws {
        let root = PTYSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let map = NSMapTable<SessionView, PTYSession>.strongToStrongObjects()
        let tab = try XCTUnwrap(PTYTab(root: root, sessions: map))
        let session = try XCTUnwrap(PTYSession(synthetic: false))
        session.view = SessionView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        tab.installSidebarSession(session)
        XCTAssertEqual(tab.sidebarSessions, [session])
        XCTAssertEqual(tab.allSessions(), [session])
        XCTAssertTrue(tab.sessions()?.isEmpty == true)
        XCTAssertTrue(tab.tiledSessions()?.isEmpty == true)
        XCTAssertTrue(tab.sessionIsSidebar(session))
        XCTAssertTrue(session.delegate === tab)
        XCTAssertTrue(tab.session(withViewId: try XCTUnwrap(session.view).viewId) === session)
        XCTAssertEqual(tab.sidebarWorkspaceState.items.first?.sessionIdentifier, session.guid)
        tab.installSidebarSession(session)
        XCTAssertEqual(tab.sidebarSessions.count, 1)
        tab.remove(session)
        XCTAssertTrue(tab.sidebarSessions.isEmpty)
        XCTAssertFalse(tab.sessionIsSidebar(session))
        XCTAssertNil(tab.session(for: session.view))
        XCTAssertTrue(tab.sidebarWorkspaceState.items.isEmpty)
        XCTAssertNil(session.delegate)
    }

    func testSidebarSelectionDoesNotReplacePrimaryActiveSession() throws {
        let root = PTYSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tab = try XCTUnwrap(PTYTab(root: root, sessions: NSMapTable<SessionView, PTYSession>.strongToStrongObjects()))
        let session = try XCTUnwrap(PTYSession(synthetic: false))
        session.view = SessionView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        tab.installSidebarSession(session)
        tab.setActiveSession(session)
        XCTAssertNil(tab.activeSession)
        XCTAssertTrue(tab.selectedSidebarSession === session)
        session.delegate = nil
    }
}
