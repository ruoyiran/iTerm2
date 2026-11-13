#!/bin/bash
set -euo pipefail
file_content_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_content_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-file-content.XXXXXX")"
trap 'rm -rf "$file_content_tmp"' EXIT
file_content_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
sed '/@testable import iTerm2SharedARC/d' "$file_content_repo/ModernTests/FileContentServiceTests.swift" > "$file_content_tmp/Tests.swift"
cat > "$file_content_tmp/main.swift" <<'SWIFT'
import XCTest
let suite = FileContentServiceTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors \
 -import-objc-header "$file_content_repo/sources/SessionCreation/iTermOpenStyle.h" \
 -I "$file_content_developer/usr/lib" -L "$file_content_developer/usr/lib" -F "$file_content_developer/Library/Frameworks" \
 -Xlinker -rpath -Xlinker "$file_content_developer/Library/Frameworks" -Xlinker -rpath -Xlinker "$file_content_developer/usr/lib" \
 "$file_content_repo"/sources/FileWorkspace/*.swift \
 "$file_content_tmp/Tests.swift" "$file_content_tmp/main.swift" -o "$file_content_tmp/tests"
DYLD_FRAMEWORK_PATH="$file_content_developer/Library/PrivateFrameworks" "$file_content_tmp/tests"
