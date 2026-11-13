#!/bin/bash
set -euo pipefail
file_ui_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_ui_tmp="$(mktemp -d "${TMPDIR:-/tmp}/iterm-file-ui-compile.XXXXXX")"
trap 'rm -rf "$file_ui_tmp"' EXIT
cat > "$file_ui_tmp/HostDeclarations.swift" <<'SWIFT'
import AppKit
func DLog(_ text: String) {}
func it_fatalError(_ text: String) -> Never { preconditionFailure(text) }
final class MarkdownPortholeRenderer {
 static func attributedString(markdown: String, font: NSFont, textColor: NSColor, backgroundColor: NSColor, imageLoader: AnyObject?) -> NSAttributedString { NSAttributedString(string: markdown) }
}
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors -typecheck \
 -import-objc-header "$file_ui_repo/sources/SessionCreation/iTermOpenStyle.h" \
 "$file_ui_repo"/sources/FileWorkspace/*.swift "$file_ui_repo"/sources/FileWorkspace/UI/*.swift \
 "$file_ui_tmp/HostDeclarations.swift"
