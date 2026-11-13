#!/bin/bash
# Exercise the native sidebar without launching or driving an iTerm2 instance.
set -euo pipefail
sidebar_shortcut_repo="$(cd "$(dirname "$0")/.." && pwd)"
sidebar_shortcut_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-sidebar-shortcuts.XXXXXX")"
trap 'rm -rf "$sidebar_shortcut_tmp"' EXIT
sidebar_shortcut_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
sed '/@testable import iTerm2SharedARC/d' "$sidebar_shortcut_repo/ModernTests/ProjectSidebarTerminalShortcutTests.swift" > "$sidebar_shortcut_tmp/Tests.swift"
cat > "$sidebar_shortcut_tmp/Stubs.swift" <<'SWIFT'
import AppKit
@objc enum iTermOpenStyle: UInt { case window, tab, verticalSplit, horizontalSplit, floatingPane }
@objc enum iTermEventModifierFlags: UInt { case leaderModifierFlag = 16777216 }
class iTermUserDefaults: NSObject {
    static func userDefaults() -> UserDefaults { UserDefaults(suiteName: "ProjectSidebarShortcutsStandalone")! }
}
private class EmptyGitExecutor: iTermGitWorktreeCommandExecuting {
    func run(arguments: [String], directory: String, timeout: TimeInterval) -> iTermGitWorktreeCommandResult {
        iTermGitWorktreeCommandResult(output: Data(), status: 128)
    }
}
extension iTermGitWorktreeScanner {
    static func makeDefault() -> iTermGitWorktreeScanner { iTermGitWorktreeScanner(executor: EmptyGitExecutor()) }
}
func DLog(_ message: @autoclosure () -> String) {}
func it_assert(_ value: Bool, _ message: String) { precondition(value, message) }
func it_fatalError(_ message: String) -> Never { preconditionFailure(message) }
SWIFT
cat > "$sidebar_shortcut_tmp/main.swift" <<'SWIFT'
import XCTest
let suite = ProjectSidebarTerminalShortcutTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors \
    -I "$sidebar_shortcut_developer/usr/lib" -L "$sidebar_shortcut_developer/usr/lib" \
    -F "$sidebar_shortcut_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$sidebar_shortcut_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$sidebar_shortcut_developer/usr/lib" \
    "$sidebar_shortcut_repo/ThirdParty/SFSymbolEnum/SFSymbolEnum.swift" \
    "$sidebar_shortcut_repo/ThirdParty/SFSymbolEnum/SFSymbolEnum.generated.swift" \
    "$sidebar_shortcut_repo/sources/Toolbelt/iTermProjectDirectory.swift" \
    "$sidebar_shortcut_repo/sources/Toolbelt/iTermGitWorktreeScanner.swift" \
    "$sidebar_shortcut_repo/sources/Toolbelt/iTermProjectSidebarTree.swift" \
    "$sidebar_shortcut_repo/sources/Toolbelt/iTermSidebarCellView.swift" \
    "$sidebar_shortcut_repo/sources/Toolbelt/iTermProjectTerminalMenu.swift" \
    "$sidebar_shortcut_repo/sources/Toolbelt/iTermProjectSidebarView.swift" \
    "$sidebar_shortcut_tmp/Stubs.swift" "$sidebar_shortcut_tmp/Tests.swift" "$sidebar_shortcut_tmp/main.swift" \
    -o "$sidebar_shortcut_tmp/tests"
DYLD_FRAMEWORK_PATH="$sidebar_shortcut_developer/Library/PrivateFrameworks" "$sidebar_shortcut_tmp/tests"
