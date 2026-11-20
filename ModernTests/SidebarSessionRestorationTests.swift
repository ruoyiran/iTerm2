import XCTest
@testable import iTerm2SharedARC

final class SidebarSessionRestorationTests: XCTestCase {
    private func arrangement(_ session: [String: Any]) -> [String: Any] {
        ["Root": ["View Type": "Splitter", "Subviews": []],
         "Sidebar Sessions": [["Item Identifier": "sidebar-item",
                               "Node": ["View Type": "SessionView", "Session": session]]]]
    }

    func testRevivalIncludesRetainedSidebarJob() throws {
        let retained = NSObject()
        let result = try XCTUnwrap(iTermSessionRevivalMap.build(
            arrangement(["Session GUID": "sidebar-job"]), sessions: ["sidebar-job": retained]))
        XCTAssertTrue(result["sidebar-job"] === retained)
    }

    func testPrimaryRebuildPreservesIndependentSidebarOwnership() throws {
        let retained = NSObject()
        var full = arrangement(["Session GUID": "sidebar-job"])
        full["Root"] = ["View Type": "SessionView", "Session": ["Session GUID": "primary-job"]]
        XCTAssertNil(iTermSessionRevivalMap.build(full, sessions: ["primary-job": retained]))
        let primary = try XCTUnwrap(PTYTab.arrangementWithoutSidebarSessions(full) as? [String: Any])
        XCTAssertNil(primary["Sidebar Sessions"])
        let result = try XCTUnwrap(iTermSessionRevivalMap.build(primary, sessions: ["primary-job": retained]))
        XCTAssertTrue(result["primary-job"] === retained)
        XCTAssertNotNil(full["Sidebar Sessions"])
    }

    func testRevivalRefusesMissingSidebarJob() {
        XCTAssertNil(iTermSessionRevivalMap.build(arrangement(["Session GUID": "missing"]), sessions: [:]))
    }

    func testRevivalAllowsFileAndArchiveSidebarReconstruction() throws {
        for session: [String: Any] in [["Session GUID": "file", "File Session": "malformed"],
                                      ["Session GUID": "archive", "Restore As Archive": "archive-id"]] {
            let result = try XCTUnwrap(iTermSessionRevivalMap.build(arrangement(session), sessions: [:]))
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testMalformedSidebarNodeCannotSilentlyLoseAJob() {
        let tab: [String: Any] = ["Root": ["View Type": "Splitter", "Subviews": []],
                                 "Sidebar Sessions": [["Item Identifier": "missing-node"]]]
        XCTAssertNil(iTermSessionRevivalMap.build(tab, sessions: [:]))
    }
    func testSidebarSessionsParticipateInLookupAndArrangementMutation() throws {
        let original = arrangement(["Session GUID": "sidebar-job"])
        XCTAssertNotNil(PTYTab.arrangementForSession(withGUID: "sidebar-job", inArrangement: original))
        XCTAssertTrue(PTYTab.arrangement(original, passesTest: { candidate in
            candidate?["Session GUID"] as? String == "sidebar-job"
        }))
        let modified = try XCTUnwrap(PTYTab.modifiedArrangement(original) { session in
            var copy = session ?? [:]
            copy["Marker"] = "modified"
            return copy
        })
        let restored = try XCTUnwrap(PTYTab.arrangementForSession(withGUID: "sidebar-job", inArrangement: modified))
        XCTAssertEqual(restored["Marker"] as? String, "modified")
        XCTAssertNil(PTYTab.arrangementForSession(withGUID: "sidebar-job", inArrangement: original)?["Marker"])
    }

    func testDuplicationGivesWorkspaceItemsIndependentIdentitiesAndKeepsSelection() throws {
        let tab = try makeTab()
        tab.sidebarWorkspaceState.appendItem(iTermSidebarWorkspaceItem(
            identifier: "browser", title: "Browser", kind: "browser", sessionIdentifier: nil,
            state: ["url": "https://example.test"]))
        tab.sidebarWorkspaceState.appendItem(iTermSidebarWorkspaceItem(
            identifier: "agent", title: "Agent", kind: "agent", sessionIdentifier: nil,
            state: ["draftIdentifier": "draft-original"]))
        tab.sidebarWorkspaceState.visible = true
        let duplicate = try XCTUnwrap(tab.arrangementForDuplication())
        let workspace = try XCTUnwrap(duplicate["Sidebar Workspace"] as? [String: Any])
        let items = try XCTUnwrap(workspace["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let identifiers = items.compactMap { $0["identifier"] as? String }
        XCTAssertEqual(Set(identifiers).count, 2)
        XCTAssertTrue(Set(identifiers).isDisjoint(with: ["browser", "agent"]))
        XCTAssertEqual(workspace["selectedIdentifier"] as? String, items.last?["identifier"] as? String)
        XCTAssertEqual((items.last?["state"] as? [String: Any])?["draftIdentifier"] as? String, "draft-original")
        XCTAssertEqual(tab.sidebarWorkspaceState.selectedIdentifier, "agent")
    }

    func testRevivedSessionRebindsDescriptorAndPreservesItemState() throws {
        let tab = try makeTab()
        let session = try XCTUnwrap(PTYSession(synthetic: false))
        session.view = SessionView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let guid = try XCTUnwrap(session.guid)
        let saved: [String: Any] = [
            "Sidebar Sessions": [["Item Identifier": "file-item", "Node": ["View Type": "SessionView", "Session": ["Session GUID": guid]]]],
            "Sidebar Workspace": ["items": [["identifier": "file-item", "kind": "file", "title": "Draft",
                                              "sessionIdentifier": "previous-session", "state": ["draftIdentifier": "draft-original"]]]]]
        tab.addRevivedSidebarSession(session, fromArrangement: saved)
        XCTAssertTrue(tab.selectedSidebarSession === session)
        XCTAssertEqual(tab.sidebarWorkspaceState.items.count, 1)
        let item = try XCTUnwrap(tab.sidebarWorkspaceState.items.first)
        XCTAssertEqual(item.identifier, "file-item")
        XCTAssertEqual(item.sessionIdentifier, session.guid)
        XCTAssertEqual(item.state["draftIdentifier"] as? String, "draft-original")
        XCTAssertTrue(tab.tiledSessions()?.isEmpty == true)
        tab.remove(session)
    }

    private func makeTab() throws -> PTYTab {
        let root = PTYSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        return try XCTUnwrap(PTYTab(root: root, sessions: NSMapTable<SessionView, PTYSession>.strongToStrongObjects()))
    }

}
