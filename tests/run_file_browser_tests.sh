#!/bin/bash
# Run the real Foundation browser implementation without an application host.
set -euo pipefail
file_browser_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_browser_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-file-browser-tests.XXXXXX")"
trap 'rm -rf "$file_browser_tmp"' EXIT
file_browser_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
sed '/@testable import iTerm2SharedARC/d' "$file_browser_repo/ModernTests/FileBrowserServiceTests.swift" > "$file_browser_tmp/Tests.swift"
cat > "$file_browser_tmp/main.swift" <<'SWIFT'
import XCTest
let suite = FileBrowserServiceTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors \
    -I "$file_browser_developer/usr/lib" -L "$file_browser_developer/usr/lib" \
    -F "$file_browser_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$file_browser_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$file_browser_developer/usr/lib" \
    "$file_browser_repo"/sources/FileWorkspace/iTermFileBrowser*.swift \
    "$file_browser_tmp/Tests.swift" "$file_browser_tmp/main.swift" -o "$file_browser_tmp/tests"
DYLD_FRAMEWORK_PATH="$file_browser_developer/Library/PrivateFrameworks" "$file_browser_tmp/tests"
