import AppKit
import XCTest
@testable import iTerm2SharedARC

final class BrowserGatewayNativeTests: XCTestCase {
    private func withBrowserSetting(_ enabled: Bool, _ block: () -> Void) {
        let defaults = iTermUserDefaults.userDefaults()
        let setting = defaults.object(forKey: "BrowserProfiles")
        let hint = defaults.object(forKey: "BrowserPluginPathHint")
        defer {
            if let setting { defaults.set(setting, forKey: "BrowserProfiles") }
            else { defaults.removeObject(forKey: "BrowserProfiles") }
            if let hint { defaults.set(hint, forKey: "BrowserPluginPathHint") }
            else { defaults.removeObject(forKey: "BrowserPluginPathHint") }
            _ = iTermAdvancedSettingsModel.perform(NSSelectorFromString("load_browserProfiles"))
            _ = iTermAdvancedSettingsModel.perform(NSSelectorFromString("load_browserPluginPathHint"))
            iTermBrowserGateway.reload()
        }
        defaults.set(enabled, forKey: "BrowserProfiles")
        defaults.set("/nonexistent/browser-plugin.app", forKey: "BrowserPluginPathHint")
        _ = iTermAdvancedSettingsModel.perform(NSSelectorFromString("load_browserProfiles"))
        _ = iTermAdvancedSettingsModel.perform(NSSelectorFromString("load_browserPluginPathHint"))
        iTermBrowserGateway.reload()
        block()
    }

    func testNativeBrowserCanOpenWithoutSeparatePlugin() {
        withBrowserSetting(true) {
            XCTAssertTrue(iTermBrowserGateway.browserAllowed(checkIfNo: true))
            XCTAssertFalse(iTermBrowserGateway.shouldOfferPlugin())
        }
    }

    func testDisablingBrowserProfilesStillDisablesNativeBrowsing() {
        withBrowserSetting(false) {
            XCTAssertFalse(iTermBrowserGateway.browserAllowed(checkIfNo: true))
            XCTAssertFalse(iTermBrowserGateway.shouldOfferPlugin())
        }
    }

    func testReadinessGetterNotifiesOnlyOnceForAnAllowedState() {
        withBrowserSetting(true) {
            var changes = 0
            let observer = NotificationCenter.default.addObserver(forName: iTermBrowserGateway.didChange,
                object: nil, queue: .main) { _ in changes += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            for _ in 0..<5 { XCTAssertTrue(iTermBrowserGateway.browserAllowed(checkIfNo: true)) }
            XCTAssertEqual(changes, 1)
        }
    }
}
