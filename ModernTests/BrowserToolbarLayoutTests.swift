import AppKit
import XCTest
@testable import iTerm2SharedARC

@MainActor final class BrowserToolbarLayoutTests: XCTestCase {
    func testAddressBarFitsBetweenNavigationAndMenuAtNarrowWidths() throws {
        for width in [CGFloat(240), 356, 360, 480, 720] {
            let toolbar = iTermBrowserToolbar(frame: NSRect(x: 0, y: 0, width: width, height: 44))
            toolbar.updateURL("https://example.test/a/very/long/path/that/must/not/push/toolbar/buttons")
            toolbar.layoutSubtreeIfNeeded()
            let address = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? iTermURLBar }.first)
            let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
            let reload = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("reloadTapped") })
            let menu = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("menuTapped") })
            XCTAssertGreaterThanOrEqual(address.frame.minX, reload.frame.maxX)
            XCTAssertLessThanOrEqual(address.frame.maxX, menu.frame.minX)
            XCTAssertGreaterThanOrEqual(address.frame.width, 0)
        }
    }

    func testLoadingStopButtonUsesReloadPosition() throws {
        let toolbar = iTermBrowserToolbar(frame: NSRect(x: 0, y: 0, width: 356, height: 44))
        toolbar.setLoading(true)
        toolbar.layoutSubtreeIfNeeded()
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
        let reload = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("reloadTapped") })
        let stop = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("stopTapped") })
        XCTAssertEqual(stop.frame, reload.frame)
    }
}
