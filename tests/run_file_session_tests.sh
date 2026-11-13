#!/bin/bash
set -euo pipefail
file_ui_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_ui_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-file-ui-webkit.XXXXXX")"
trap 'rm -rf "$file_ui_tmp"' EXIT
file_ui_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
sed '/@testable import iTerm2SharedARC/d' "$file_ui_repo/ModernTests/FileSessionTests.swift" > "$file_ui_tmp/Tests.swift"
cat > "$file_ui_tmp/HostDeclarations.swift" <<'SWIFT'
import AppKit
func DLog(_ text: String) {}
func it_fatalError(_ text: String) -> Never { preconditionFailure(text) }
final class MarkdownPortholeRenderer {
 static func attributedString(markdown: String, font: NSFont, textColor: NSColor, backgroundColor: NSColor, imageLoader: AnyObject?) -> NSAttributedString { NSAttributedString(string: markdown) }
}
SWIFT
cat > "$file_ui_tmp/main.swift" <<'SWIFT'
import XCTest
let all = FileSessionTests.defaultTestSuite
let filter = CommandLine.arguments.dropFirst().first ?? ""
let suite = XCTestSuite(name: filter.isEmpty ? "FileSessionTests" : filter)
for test in all.tests where filter.isEmpty || test.name.contains(filter) { suite.addTest(test) }
guard !suite.tests.isEmpty else { exit(2) }
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors \
 -import-objc-header "$file_ui_repo/sources/SessionCreation/iTermOpenStyle.h" \
 -I "$file_ui_developer/usr/lib" -L "$file_ui_developer/usr/lib" -F "$file_ui_developer/Library/Frameworks" \
 -Xlinker -rpath -Xlinker "$file_ui_developer/Library/Frameworks" -Xlinker -rpath -Xlinker "$file_ui_developer/usr/lib" \
 "$file_ui_repo"/sources/FileWorkspace/*.swift "$file_ui_repo"/sources/FileWorkspace/UI/*.swift \
 "$file_ui_repo"/sources/FileWorkspace/Native/iTermFileSessionDescriptor.swift \
 "$file_ui_repo"/sources/FileWorkspace/Native/iTermFileSessionCoordinator.swift \
 "$file_ui_repo"/sources/FileWorkspace/Native/iTermFileOpenCoordinator.swift \
 "$file_ui_repo"/sources/ClaudeCode/Orchestration/StableSessionID.swift \
 "$file_ui_repo"/sources/FileWorkspace/Native/iTermFileBrowserCoordinator.swift \
 "$file_ui_repo"/sources/FileWorkspace/Native/iTermSessionRevivalMap.swift \
 "$file_ui_repo"/sources/FileWorkspace/Native/iTermFileMenuActions.swift \
 "$file_ui_tmp/HostDeclarations.swift" "$file_ui_tmp/Tests.swift" "$file_ui_tmp/main.swift" -o "$file_ui_tmp/tests"
FILE_SESSION_MAIN_MENU="$file_ui_repo/sources/MainMenu/Base.lproj/MainMenu.xib" \
FILE_UI_RESOURCE_DIR="$file_ui_repo/sources/FileWorkspace/Resources/FileWorkspaceUI" \
 DYLD_FRAMEWORK_PATH="$file_ui_developer/Library/PrivateFrameworks" "$file_ui_tmp/tests" "${1:-}"
