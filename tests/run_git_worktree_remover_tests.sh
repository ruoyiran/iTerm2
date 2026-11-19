#!/bin/bash
# Verify deletion against temporary Git repositories without launching the app.
set -euo pipefail
cd "$(dirname "$0")/.."
remover_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/iterm-git-remover-tests.XXXXXX")"
trap 'rm -rf "$remover_test_dir"' EXIT
remover_test_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
xcrun swiftc -swift-version 5 -warnings-as-errors -D GIT_WORKTREE_REMOVER_STANDALONE \
    -I "$remover_test_developer/usr/lib" -L "$remover_test_developer/usr/lib" \
    -F "$remover_test_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$remover_test_developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$remover_test_developer/usr/lib" \
    -Xlinker -rpath -Xlinker "$remover_test_developer/Library/PrivateFrameworks" \
    sources/Toolbelt/iTermGitWorktreeScanner.swift \
    sources/Toolbelt/iTermGitWorktreeRemover.swift \
    ModernTests/GitWorktreeRemoverTests.swift -o "$remover_test_dir/tests"
"$remover_test_dir/tests"
