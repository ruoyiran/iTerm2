#!/bin/bash
set -euo pipefail
file_ui_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_ui_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-file-ui-tests.XXXXXX")"
trap 'rm -rf "$file_ui_tmp"' EXIT
file_ui_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
sed '/@testable import iTerm2SharedARC/d' "$file_ui_repo/ModernTests/FileUITransportTests.swift" > "$file_ui_tmp/Tests.swift"
cat > "$file_ui_tmp/main.swift" <<'SWIFT'
import XCTest
let suite = FileUITransportTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors \
 -import-objc-header "$file_ui_repo/sources/SessionCreation/iTermOpenStyle.h" \
 -I "$file_ui_developer/usr/lib" -L "$file_ui_developer/usr/lib" -F "$file_ui_developer/Library/Frameworks" \
 -Xlinker -rpath -Xlinker "$file_ui_developer/Library/Frameworks" -Xlinker -rpath -Xlinker "$file_ui_developer/usr/lib" \
 "$file_ui_repo"/sources/FileWorkspace/*.swift \
 "$file_ui_repo/sources/FileWorkspace/UI/iTermFileUIContracts.swift" \
 "$file_ui_repo/sources/FileWorkspace/UI/iTermFileUIEditSession.swift" \
 "$file_ui_repo/sources/FileWorkspace/UI/iTermFileUIMessage.swift" \
 "$file_ui_repo/sources/FileWorkspace/UI/iTermFileUIAssetServer.swift" \
 "$file_ui_tmp/Tests.swift" "$file_ui_tmp/main.swift" -o "$file_ui_tmp/tests"
DYLD_FRAMEWORK_PATH="$file_ui_developer/Library/PrivateFrameworks" "$file_ui_tmp/tests"
