#!/bin/bash
# Run the real Foundation document implementation without an application host.
set -euo pipefail
file_document_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_document_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-file-document-tests.XXXXXX")"
trap 'rm -rf "$file_document_tmp"' EXIT
file_document_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
sed '/@testable import iTerm2SharedARC/d' "$file_document_repo/ModernTests/FileDocumentTests.swift" > "$file_document_tmp/Tests.swift"
cat > "$file_document_tmp/main.swift" <<'SWIFT'
import XCTest
let suite = FileDocumentTests.defaultTestSuite
suite.run()
exit(suite.testRun!.hasSucceeded ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors \
    -I "$file_document_developer/usr/lib" -L "$file_document_developer/usr/lib" \
    -F "$file_document_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$file_document_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$file_document_developer/usr/lib" \
    "$file_document_repo"/sources/FileWorkspace/*.swift \
    "$file_document_tmp/Tests.swift" "$file_document_tmp/main.swift" -o "$file_document_tmp/tests"
DYLD_FRAMEWORK_PATH="$file_document_developer/Library/PrivateFrameworks" "$file_document_tmp/tests"
