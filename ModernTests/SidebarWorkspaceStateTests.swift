import XCTest
#if !SIDEBAR_HOSTLESS
@testable import iTerm2SharedARC
#endif

final class SidebarWorkspaceStateTests: XCTestCase {
    private func item(_ identifier: String) -> iTermSidebarWorkspaceItem {
        iTermSidebarWorkspaceItem(identifier: identifier, title: identifier, kind: "terminal",
                                  sessionIdentifier: "session-" + identifier, state: ["directory": "/tmp"])
    }

    // Dropping descriptor metadata or selection from the saved arrangement breaks restoration.
    func testRestorationPreservesDescriptorsAndSelectedItem() throws {
        let state = iTermSidebarWorkspaceState()
        state.appendItem(item("first"))
        state.appendItem(item("second"))
        state.visible = true
        state.width = 620
        let restored = iTermSidebarWorkspaceState(dictionary: state.dictionaryRepresentation)
        XCTAssertEqual(restored.items.map(\.identifier), ["first", "second"])
        XCTAssertEqual(restored.selectedIdentifier, "second")
        let first = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(first.sessionIdentifier, "session-first")
        XCTAssertEqual(first.state["directory"] as? String, "/tmp")
        XCTAssertTrue(restored.visible)
        XCTAssertEqual(restored.width, 620)
        XCTAssertTrue(PropertyListSerialization.propertyList(restored.dictionaryRepresentation,
                                                             isValidFor: .binary))
    }

    // Invalid selection must never leave the owner with an item it cannot display.
    func testUnknownSelectionFallsBackToFirstItem() {
        let state = iTermSidebarWorkspaceState()
        state.items = [item("first"), item("second")]
        state.selectedIdentifier = "missing"
        XCTAssertEqual(state.selectedIdentifier, "first")
        state.selectItem(withIdentifier: "second")
        XCTAssertEqual(state.selectedIdentifier, "second")
        state.selectItem(withIdentifier: "missing")
        XCTAssertEqual(state.selectedIdentifier, "second")
    }

    // Closing the selected middle tab should select its right neighbor, then the left at the end.
    func testClosingSelectedItemSelectsNearestRemainingNeighbor() {
        let state = iTermSidebarWorkspaceState()
        state.items = [item("first"), item("second"), item("third")]
        state.selectItem(withIdentifier: "second")
        state.removeItem(withIdentifier: "second")
        XCTAssertEqual(state.selectedIdentifier, "third")
        state.removeItem(withIdentifier: "third")
        XCTAssertEqual(state.selectedIdentifier, "first")
        state.removeItem(withIdentifier: "first")
        XCTAssertNil(state.selectedIdentifier)
        XCTAssertTrue(state.items.isEmpty)
    }

    // An unselected close must not steal focus from the selected session.
    func testClosingUnselectedItemPreservesSelection() {
        let state = iTermSidebarWorkspaceState()
        state.items = [item("first"), item("second"), item("third")]
        state.selectItem(withIdentifier: "third")
        state.removeItem(withIdentifier: "first")
        XCTAssertEqual(state.selectedIdentifier, "third")
    }

    // Corrupt saved state may contain duplicate IDs, missing fields, and runtime objects.
    func testMalformedRestorationRejectsInvalidDescriptorsAndRuntimeMetadata() throws {
        let state = iTermSidebarWorkspaceState(dictionary: [
            "items": [
                ["identifier": "first", "title": "Shell", "kind": "terminal",
                 "state": ["directory": "/tmp", "runtime": NSObject()]],
                ["identifier": "first", "title": "Duplicate", "kind": "browser"],
                ["identifier": "", "title": "Bad", "kind": "terminal"],
                ["identifier": "missing-kind", "title": "Bad"],
                ["identifier": "second", "title": "Page", "kind": "browser",
                 "state": ["url": "https://example.com"]]
            ],
            "selectedIdentifier": "missing"
        ])
        XCTAssertEqual(state.items.map(\.identifier), ["first", "second"])
        XCTAssertEqual(state.selectedIdentifier, "first")
        let first = try XCTUnwrap(state.items.first)
        XCTAssertNil(first.state["runtime"])
        XCTAssertEqual(first.state["directory"] as? String, "/tmp")
    }

    // Non-finite saved widths otherwise poison the split layout with NaN or infinity.
    func testWidthIsSanitizedForRestorationAndInteractiveUpdates() {
        for input in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(iTermSidebarWorkspaceState(dictionary: ["width": input]).width, 480)
        }
        XCTAssertEqual(iTermSidebarWorkspaceState(dictionary: ["width": 1]).width, 360)
        XCTAssertEqual(iTermSidebarWorkspaceState(dictionary: ["width": 9000]).width, 720)
        XCTAssertEqual(iTermSidebarWorkspaceState(dictionary: [:]).width, 480)
        let state = iTermSidebarWorkspaceState()
        state.width = -2
        XCTAssertEqual(state.width, 360)
        state.width = 800
        XCTAssertEqual(state.width, 720)
        state.width = .nan
        XCTAssertEqual(state.width, 480)
        XCTAssertFalse(state.visible)
    }

    // Updating a descriptor by identifier must not create a duplicate tab.
    func testAppendingExistingIdentifierUpdatesDescriptorInPlace() {
        let state = iTermSidebarWorkspaceState()
        state.appendItem(item("first"))
        state.appendItem(item("second"))
        state.appendItem(iTermSidebarWorkspaceItem(identifier: "first", title: "Renamed", kind: "terminal",
                                                  sessionIdentifier: "session-first", state: [:]))
        XCTAssertEqual(state.items.map(\.identifier), ["first", "second"])
        XCTAssertEqual(state.items[0].title, "Renamed")
        XCTAssertEqual(state.selectedIdentifier, "first")
    }

}
