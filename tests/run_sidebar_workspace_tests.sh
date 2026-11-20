#!/bin/bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/iterm-sidebar-tests.XXXXXX")"
trap 'rm -rf "$test_output"' EXIT
xcode_developer="$(xcode-select -p)"
xctest_frameworks="$xcode_developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
xctest_libraries="$xcode_developer/Platforms/MacOSX.platform/Developer/usr/lib"
xctest_private="$xcode_developer/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
cat > "$test_output/main.swift" <<'SWIFT'
import XCTest
let suite = XCTestSuite(forTestCaseClass: SidebarWorkspaceStateTests.self)
suite.addTest(XCTestSuite(forTestCaseClass: SidebarWorkspaceViewTests.self))
suite.run()
exit(suite.testRun!.totalFailureCount == 0 ? 0 : 1)
SWIFT
xcrun swiftc -warnings-as-errors -D SIDEBAR_HOSTLESS \
    -F "$xctest_frameworks" -Xlinker -rpath -Xlinker "$xctest_frameworks" \
    -I "$xctest_libraries" -L "$xctest_libraries" -Xlinker -rpath -Xlinker "$xctest_libraries" \
    -Xlinker -rpath -Xlinker "$xctest_private" \
    "$workspace_root/sources/SidebarWorkspace/iTermSidebarWorkspaceState.swift" \
    "$workspace_root/sources/SidebarWorkspace/iTermSidebarWorkspaceView.swift" \
    "$workspace_root/ThirdParty/SFSymbolEnum/SFSymbolEnum.generated.swift" \
    "$workspace_root/ModernTests/SidebarWorkspaceStateTests.swift" \
    "$workspace_root/ModernTests/SidebarWorkspaceViewTests.swift" \
    "$test_output/main.swift" -o "$test_output/sidebar-tests"
"$test_output/sidebar-tests"
