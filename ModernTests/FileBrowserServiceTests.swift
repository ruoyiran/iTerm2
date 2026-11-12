import Foundation
import Darwin
import XCTest
@testable import iTerm2SharedARC

final class FileBrowserServiceTests: XCTestCase {
    private var root: URL!
    private var service: iTermFileBrowserService!
    private var context: iTermFileBrowserContext!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("file-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = iTermFileBrowserService()
        context = makeContext()
        service.activate(context)
#if FILE_BROWSER_TESTING
        FileBrowserFaultGate.trashReceipt = { [weak self] receipt in self?.captureReceipt(receipt) }
#endif
    }
#if FILE_BROWSER_TESTING
    private var exactTrashReceipts = [(URL, FileBrowserIdentity)]()
    private func captureReceipt(_ receipt: NSURL?) {
        if let receipt, let path = receipt.path, let identity = try? FileBrowserIdentity.read(path) {
            exactTrashReceipts.append((receipt as URL, identity))
        }
    }
#endif
    override func tearDownWithError() throws {
#if FILE_BROWSER_TESTING
        FileBrowserFaultGate.committed = nil; FileBrowserFaultGate.trashInput = nil
        FileBrowserFaultGate.trashReceipt = nil; FileBrowserFaultGate.receiptPathUnavailable = false; FileBrowserFaultGate.gitExecutable = nil; FileBrowserFaultGate.gitStarted = nil
        for (url, expected) in exactTrashReceipts {
            if let actual = try? FileBrowserIdentity.read(url.path), expected.sameItem(actual) {
                let recovered = root.appendingPathComponent("receipt-restored-" + UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: recovered)
            }
        }
        exactTrashReceipts.removeAll()
#endif
        try FileManager.default.removeItem(at: root)
    }
    private func makeContext(hidden: Bool = false, ignored: Bool = false, generation: UInt64 = 1) -> iTermFileBrowserContext {
        iTermFileBrowserContext(rootDirectory: root.path, projectIdentifier: "p", worktreeIdentifier: "w", generation: generation,
                                showsHiddenFiles: hidden, showsGitIgnoredFiles: ignored)
    }
    @discardableResult private func file(_ name: String, _ text: String = "hello\n") throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }
    private func listing(_ path: String? = nil, fails: Bool = false) -> [iTermFileBrowserEntry] {
        let done = expectation(description: "listing")
        var entries = [iTermFileBrowserEntry]()
        service.listDirectory(atPath: path ?? root.path, context: context) { values, error in
            XCTAssertTrue(Thread.isMainThread)
            if fails { XCTAssertNotNil(error) } else { XCTAssertNil(error) }
            entries = values ?? []; done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return entries
    }
    private func names(_ query: String) -> [iTermFileBrowserEntry] {
        let done = expectation(description: "name search")
        var entries = [iTermFileBrowserEntry]()
        service.searchNames(query, context: context) { value in
            XCTAssertTrue(Thread.isMainThread); XCTAssertNil(value.error)
            entries += value.entries
            if value.isComplete { done.fulfill() }
        }
        wait(for: [done], timeout: 20)
        return entries
    }
    private func contents(_ query: iTermFileContentQuery) -> ([iTermFileContentMatch], iTermFileSearchBatch?) {
        let done = expectation(description: "content search")
        var matches = [iTermFileContentMatch](); var final: iTermFileSearchBatch?
        service.searchContents(query, context: context) { value in
            XCTAssertTrue(Thread.isMainThread); matches += value.matches
            if value.isComplete { final = value; done.fulfill() }
        }
        wait(for: [done], timeout: 20)
        return (matches, final)
    }
    private func operation(fails: Bool = false, _ run: (@escaping (iTermFileOperationResult) -> Void) -> Void) -> iTermFileOperationResult? {
        let done = expectation(description: "operation")
        var result: iTermFileOperationResult?
        run { value in
            XCTAssertTrue(Thread.isMainThread)
            if fails { XCTAssertNotNil(value.error) } else { XCTAssertNil(value.error) }
            result = value; done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return result
    }
    func testLazyListingPackagesHiddenAndNaturalOrder() throws {
        try file("z.txt"); try file("file10"); try file("file2"); try file(".secret"); try file("Thing.app/inside")
        XCTAssertEqual(listing().map(\.name), ["Thing.app", "file2", "file10", "z.txt"])
        XCTAssertTrue(listing().first?.isExpandable == true)
        XCTAssertEqual(listing(root.appendingPathComponent("Thing.app").path).map(\.name), ["inside"])
        context = makeContext(hidden: true, generation: 2); service.activate(context)
        XCTAssertTrue(listing().contains { $0.name == ".secret" })
    }
    func testRecursiveNamesRequireEveryCaseInsensitivePathTokenAndInvalidateCache() throws {
        try file("Collapsed/Deep/你好 Report.md"); try file("Else/Report.md")
        XCTAssertEqual(names("COLLAPSED 你好 report").map(\.relativePath), ["Collapsed/Deep/你好 Report.md"])
        try file("Collapsed/New Report.md")
        service.invalidate(context, directoryPaths: [root.appendingPathComponent("Collapsed").path])
        XCTAssertEqual(Set(names("collapsed report").map(\.relativePath)), ["Collapsed/Deep/你好 Report.md", "Collapsed/New Report.md"])
    }
    private func git(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path] + args; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
    }
    func testGitIgnoreNegationNestedAndTrackedIgnoredFiles() throws {
        try git(["init", "-q"])
        try file("tracked.log"); try git(["add", "tracked.log"])
        try file(".gitignore", "*.log\n!keep.log\ncache/\n")
        try file("ignore.log"); try file("keep.log"); try file("cache/item"); try file("sub/.gitignore", "local.txt\n")
        try file("sub/local.txt"); try file("sub/yes.txt")
        XCTAssertEqual(Set(names("log").map(\.relativePath)), ["keep.log", "tracked.log"])
        XCTAssertEqual(names("local").count, 0)
        XCTAssertFalse(listing().contains { $0.name == "cache" })
        context = makeContext(ignored: true, generation: 2); service.activate(context)
        XCTAssertEqual(names("ignore.log").count, 1)
    }
    func testContentLiteralRegexWholeWordCaseGlobsAndLineNumbers() throws {
        try file("src/你好.swift", "Hello world\r\nhello HELLO helloish\nend\n")
        try file("src/skip.swift", "Hello world\n"); try file("other.txt", "Hello world\n")
        let (matches, final) = contents(iTermFileContentQuery(text: "hello", wholeWord: true,
                                                             includeGlobs: ["**/*.swift"], excludeGlobs: ["**/skip.*"]))
        XCTAssertNil(final?.error); XCTAssertEqual(matches.map(\.relativePath), ["src/你好.swift"])
        XCTAssertEqual(matches.first?.lines.map(\.lineNumber), [1, 2])
        XCTAssertEqual(matches.first?.lines.last?.ranges.count, 2)
        XCTAssertEqual(contents(iTermFileContentQuery(text: "Hello", caseSensitive: true)).0.count, 3)
        XCTAssertEqual(contents(iTermFileContentQuery(text: "h.llo", regularExpression: true)).0.count, 3)
        XCTAssertNotNil(contents(iTermFileContentQuery(text: "[", regularExpression: true)).1?.error)
        XCTAssertNotNil(contents(iTermFileContentQuery(text: String(repeating: "é", count: 1025))).1?.error)
    }
    func testSpecialBinaryOversizeUnreadableAndSymlinksAreSkippedWithoutOpening() throws {
        try file("ok", "needle\n")
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try file("large", String(repeating: "x", count: 10 * 1024 * 1024 + 1))
        let denied = try file("denied", "needle"); XCTAssertEqual(chmod(denied, 0), 0)
        defer { _ = chmod(denied, 0o600) }
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.path)
        let (matches, final) = contents(iTermFileContentQuery(text: "needle"))
        XCTAssertEqual(matches.map(\.relativePath), ["ok"])
        XCTAssertGreaterThanOrEqual(final?.skippedFileCount ?? 0, 4)
        XCTAssertFalse(listing().contains { $0.name == "fifo" })
        _ = listing(root.appendingPathComponent("link").path, fails: true)
    }
    func testCancellationAndContextSwitchDiscardAlreadyQueuedBatches() throws {
        try file("a", "needle")
        var called = false
        let id = service.searchNames("a", context: context) { _ in called = true }
        service.cancel(id)
        service.searchContents(iTermFileContentQuery(text: "needle"), context: context) { _ in called = true }
        context = makeContext(generation: 2); service.activate(context)
        _ = listing()
        XCTAssertFalse(called)
    }
    func testCreateRenameDuplicateMoveAndMappingUndoRedo() throws {
        let first = operation { service.createFile(inDirectory: root.path, name: "你好.txt", context: context, completion: $0) }
        let original = root.appendingPathComponent("你好.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: original)); XCTAssertEqual(first?.mappings.first?.newPath, original)
        _ = operation { service.createFolder(inDirectory: root.path, name: "folder", context: context, completion: $0) }
        _ = operation { service.duplicateFile(original, newName: "copy.txt", context: context, completion: $0) }
        let renamed = operation { service.rename(original, newName: "renamed.txt", context: context, completion: $0) }
        XCTAssertEqual(renamed?.mappings.first?.oldPath, original)
        let source = root.appendingPathComponent("renamed.txt").path
        let folder = root.appendingPathComponent("folder").path
        let moved = operation { service.move([source], toDirectory: folder, context: context, completion: $0) }
        XCTAssertEqual(moved?.mappings.first?.newPath, root.appendingPathComponent("folder/renamed.txt").path)
        let undone = operation { service.undo(context, completion: $0) }
        XCTAssertEqual(undone?.mappings.first?.newPath, source); XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        _ = operation { service.redo(context, completion: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
    }
    func testCollisionTraversalAndSymlinkParentNeverMutateOutsideRoot() throws {
        let a = try file("a", "original"); let b = try file("b", "existing")
        _ = operation(fails: true) { service.rename(a, newName: "b", context: context, completion: $0) }
        for name in ["", ".", "..", "../bad", "a/b", "a\0b"] {
            _ = operation(fails: true) { service.createFile(inDirectory: root.path, name: name, context: context, completion: $0) }
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside.path)
        _ = operation(fails: true) { service.createFile(inDirectory: link, name: "escape", context: context, completion: $0) }
        _ = operation(fails: true) { service.move([a], toDirectory: link, context: context, completion: $0) }
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "existing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testMultiMovePreflightAndUndoCollisionLeaveFilesIntact() throws {
        let a = try file("a"); let b = try file("b"); try file("dest/b", "existing")
        _ = operation(fails: true) { service.move([a, b], toDirectory: root.appendingPathComponent("dest").path, context: context, completion: $0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: a)); XCTAssertTrue(FileManager.default.fileExists(atPath: b))
        _ = operation { service.rename(a, newName: "c", context: context, completion: $0) }
        try file("a", "replacement")
        _ = operation(fails: true) { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("c").path))
    }
    func testStaleMutationRejectedAndDirectoryMoveMapsDirectoryOnly() throws {
        try file("folder/a")
        let stale = context!
        context = makeContext(generation: 2); service.activate(context)
        _ = operation(fails: true) { service.createFile(inDirectory: root.path, name: "stale", context: stale, completion: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stale").path))
        let result = operation { service.rename(root.appendingPathComponent("folder").path, newName: "new", context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.count, 1); XCTAssertTrue(result?.mappings.first?.isDirectory == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new/a").path))
    }
    func testTrashUndoRedoAndCreationUndoOnlyUseUniqueFixtures() throws {
        let path = try file("trash-" + UUID().uuidString, "restore me")
        let removed = operation { service.trash([path], context: context, completion: $0) }
        XCTAssertEqual(removed?.mappings.first?.oldPath, path); XCTAssertNil(removed?.mappings.first?.newPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        _ = operation { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "restore me")
        _ = operation { service.redo(context, completion: $0) }
        _ = operation { service.undo(context, completion: $0) } // Restore unique fixture before cleanup.
        let created = "created-" + UUID().uuidString
        _ = operation { service.createFile(inDirectory: root.path, name: created, context: context, completion: $0) }
        _ = operation { service.undo(context, completion: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(created).path))
        _ = operation { service.redo(context, completion: $0) } // Restore service-owned trash fixture.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(created).path))
    }
    func testTrackedDescendantKeepsIgnoredParentVisible() throws {
        try git(["init", "-q"])
        try file("cache/tracked.txt", "tracked needle")
        try git(["add", "cache/tracked.txt"])
        try file(".gitignore", "cache/\n")
        try file("cache/ignored.txt", "ignored needle")
        XCTAssertTrue(listing().contains { $0.name == "cache" })
        XCTAssertEqual(names("tracked").map(\.relativePath), ["cache/tracked.txt"])
        XCTAssertEqual(contents(iTermFileContentQuery(text: "needle")).0.map(\.relativePath), ["cache/tracked.txt"])
    }
    func testSnippetShowsDistantMatchAndBoundsDisplayAndRanges() throws {
        try file("long", String(repeating: "x", count: 4096) + " NEEDLE " + String(repeating: "x", count: 4096))
        let match = try XCTUnwrap(contents(iTermFileContentQuery(text: "needle")).0.first?.lines.first)
        XCTAssertTrue(match.snippet.contains("NEEDLE"))
        XCTAssertLessThanOrEqual(match.snippet.utf16.count, 1024)
        XCTAssertEqual(match.ranges.first?.rangeValue, NSRange(location: 4097, length: 6))
    }
    func testRootDirectoryReplacementCannotChangeCapturedScope() throws {
        try file("original")
        _ = listing()
        let oldRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: root, to: oldRoot)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.moveItem(at: oldRoot, to: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service.invalidate(context, directoryPaths: [root.path])
        _ = listing(fails: true)
        _ = operation(fails: true) { service.createFile(inDirectory: root.path, name: "escape", context: context, completion: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
    func testDuplicatePreservesBytesAndLeafSymlinkMovePreservesOutsideTarget() throws {
        let path = try file("data", "你好\r\n🌍\n")
        _ = operation { service.duplicateFile(path, newName: "copy", context: context, completion: $0) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy")), Data("你好\r\n🌍\n".utf8))
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let link = root.appendingPathComponent("leaf-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: external.path)
        _ = operation { service.rename(link, newName: "moved-link", context: context, completion: $0) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("moved-link").path), external.path)
        _ = operation { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "outside")
        _ = operation(fails: true) { service.duplicateFile(link, newName: "bad-copy", context: context, completion: $0) }
    }
    func testPermissionDeniedCreateAndReplacedUndoSourcePreserveExistingFiles() throws {
        try file("locked/item", "existing")
        let directory = root.appendingPathComponent("locked").path
        XCTAssertEqual(chmod(directory, 0o555), 0)
        defer { _ = chmod(directory, 0o755) }
        _ = operation(fails: true) { service.createFile(inDirectory: directory, name: "denied", context: context, completion: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("locked/denied").path))
        let path = try file("original")
        _ = operation { service.rename(path, newName: "moved", context: context, completion: $0) }
        let moved = root.appendingPathComponent("moved")
        // Atomic replacement keeps the old inode alive until after the new inode is allocated.
        try Data("replacement".utf8).write(to: moved, options: .atomic)
        _ = operation(fails: true) { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    func testContentCancellationInsideBatchAndUTF16Input() throws {
        let utf16 = Data([0xff, 0xfe]) + "needle 你好\r\nend\n".data(using: .utf16LittleEndian)!
        try utf16.write(to: root.appendingPathComponent("unicode"))
        XCTAssertEqual(contents(iTermFileContentQuery(text: "你好")).0.first?.lines.first?.lineNumber, 1)
        try file("many", String(repeating: "needle\n", count: 5002))
        service.invalidate(context, directoryPaths: [root.path])
        let first = expectation(description: "incremental callback")
        var batches = 0; var id = ""
        id = service.searchContents(iTermFileContentQuery(text: "needle"), context: context) { value in
            batches += 1; XCTAssertFalse(value.isComplete)
            self.service.cancel(id); first.fulfill()
        }
        wait(for: [first], timeout: 20)
        _ = listing() // Serial-worker barrier and main-queue drain, no timing sleep.
        XCTAssertEqual(batches, 1)
    }
    func testContentResultCapAndIncrementalBatches() throws {
        try file("many", String(repeating: "needle\n", count: 5002))
        let (matches, final) = contents(iTermFileContentQuery(text: "needle"))
        XCTAssertEqual(matches.reduce(0) { $0 + $1.lines.count }, 5000)
        XCTAssertTrue(final?.isTruncated == true)
    }
    func testNonGitParentChildRepoListingOrderDoesNotChangeRootScopedFiltering() throws {
        let child = root.appendingPathComponent("child")
        try file("child/.gitignore", "ignored\n"); try file("child/ignored"); try file("child/visible")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", child.path, "init", "-q"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(Set(listing(child.path).map(\.name)), ["ignored", "visible"])
        XCTAssertEqual(listing().map(\.name), ["child"])
        context = makeContext(generation: 2); service.activate(context)
        XCTAssertEqual(listing().map(\.name), ["child"])
        XCTAssertEqual(Set(listing(child.path).map(\.name)), ["ignored", "visible"])
    }
#if FILE_BROWSER_TESTING
    func testCommittedCreationBookkeepingFailureStillReturnsMappingAndSafeUndo() throws {
        let name = "created-" + UUID().uuidString
        let path = root.appendingPathComponent(name).path
        FileBrowserFaultGate.committed = { _, _, _ in throw fileBrowserError(99) }
        let result = operation(fails: true) { service.createFile(inDirectory: root.path, name: name, context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.newPath, path)
        XCTAssertTrue(result?.canUndo == true); XCTAssertEqual(result?.error?.code, 99)
        FileBrowserFaultGate.committed = nil
        _ = operation { service.undo(context, completion: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        _ = operation { service.redo(context, completion: $0) }
    }
    func testCommittedCopyReplacementDoesNotBindUndoToReplacementInode() throws {
        let source = try file("source", "copied")
        let name = "copied-" + UUID().uuidString
        let destination = root.appendingPathComponent(name)
        let retained = root.appendingPathComponent("retained-copy")
        FileBrowserFaultGate.committed = { _, _, _ in
            try FileManager.default.moveItem(at: destination, to: retained)
            try Data("replacement".utf8).write(to: destination)
        }
        let result = operation(fails: true) { service.duplicateFile(source, newName: name, context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.newPath, destination.path)
        XCTAssertTrue(result?.canUndo == true)
        FileBrowserFaultGate.committed = nil
        _ = operation(fails: true) { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "copied")
    }
    func testCommittedMoveAfterRootRenameKeepsMappingAndDoesNotUndoReplacement() throws {
        let source = try file("source", "original")
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("moved-root-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.moveItem(at: movedRoot, to: root)
        }
        FileBrowserFaultGate.committed = { _, _, _ in
            try FileManager.default.moveItem(at: self.root, to: movedRoot)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: self.root.appendingPathComponent("destination"))
        }
        let result = operation(fails: true) { service.rename(source, newName: "destination", context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.oldPath, source)
        XCTAssertEqual(result?.mappings.first?.newPath, root.appendingPathComponent("destination").path)
        XCTAssertTrue(result?.canUndo == true)
        FileBrowserFaultGate.committed = nil
        _ = operation(fails: true) { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("destination"), encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: movedRoot.appendingPathComponent("destination"), encoding: .utf8), "original")
    }
    func testNativeTrashReceiptFailureKeepsDeletionMappingAndOriginalIdentity() throws {
        let path = try file("receipt-" + UUID().uuidString, "original")
        FileBrowserFaultGate.trashReceipt = { receipt in
            self.captureReceipt(receipt)
            throw fileBrowserError(98)
        }
        let result = operation(fails: true) { service.trash([path], context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.oldPath, path); XCTAssertNil(result?.mappings.first?.newPath)
        XCTAssertTrue(result?.canUndo == true); XCTAssertEqual(result?.error?.code, 98)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        FileBrowserFaultGate.trashReceipt = { receipt in self.captureReceipt(receipt) }
        _ = operation { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original")
    }
    func testNativeTrashUsesOriginalFileReferenceWithoutStagingAndSurvivesParentLinkSwap() throws {
        let path = try file("parent/origin-" + UUID().uuidString, "original")
        let movedParent = root.appendingPathComponent("moved-parent")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsidePath = outside.appendingPathComponent((path as NSString).lastPathComponent)
        try Data("outside".utf8).write(to: outsidePath)
        FileBrowserFaultGate.trashInput = { input in
            XCTAssertTrue(input.isFileReferenceURL())
            let originalURL = input.perform(NSSelectorFromString("filePathURL"))?.takeUnretainedValue() as? NSURL
            XCTAssertEqual(originalURL?.lastPathComponent, (path as NSString).lastPathComponent)
            XCTAssertEqual(originalURL?.deletingLastPathComponent?.lastPathComponent, "parent")
            if let originalPath = originalURL?.path {
                XCTAssertTrue(try! FileBrowserIdentity.read(originalPath).sameItem(FileBrowserIdentity.read(path)))
            } else { XCTFail("native reference has no file path") }
            do {
                try FileManager.default.moveItem(at: self.root.appendingPathComponent("parent"), to: movedParent)
                try FileManager.default.createSymbolicLink(at: self.root.appendingPathComponent("parent"), withDestinationURL: outside)
            } catch { XCTFail("fixture swap failed: \(error)") }
        }
        let result = operation { service.trash([path], context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.oldPath, path)
        XCTAssertEqual(try String(contentsOf: outsidePath, encoding: .utf8), "outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedParent.appendingPathComponent((path as NSString).lastPathComponent).path))
        // Teardown restores only the captured receipt, independently of the now-replaced parent path.
    }
    func testTrashReceiptPathReplacementDoesNotMakeUndoTrashReplacement() throws {
        let name = "trash-identity-" + UUID().uuidString
        let source = try file(name, "original")
        let replacementSource = try file("second/" + name, "replacement")
        let retained = root.appendingPathComponent("retained-original")
        var replacementReceipt: NSURL?
        FileBrowserFaultGate.trashReceipt = { receipt in
            self.captureReceipt(receipt)
            let originalReceipt = try XCTUnwrap(receipt)
            try FileManager.default.moveItem(at: originalReceipt as URL, to: retained)
            try FileManager.default.trashItem(at: URL(fileURLWithPath: replacementSource), resultingItemURL: &replacementReceipt)
            self.captureReceipt(replacementReceipt)
            XCTAssertEqual(originalReceipt.path, replacementReceipt?.path)
            throw fileBrowserError(97)
        }
        let result = operation(fails: true) { service.trash([source], context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.oldPath, source); XCTAssertTrue(result?.canUndo == true)
        FileBrowserFaultGate.trashReceipt = { receipt in self.captureReceipt(receipt) }
        _ = operation(fails: true) { service.undo(context, completion: $0) }
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(replacementReceipt) as URL, encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
    }
    func testFolderCommitFaultKeepsDirectoryMapping() throws {
        let name = "folder-commit-" + UUID().uuidString
        FileBrowserFaultGate.committed = { _, _, _ in throw fileBrowserError(96) }
        let result = operation(fails: true) { service.createFolder(inDirectory: root.path, name: name, context: context, completion: $0) }
        XCTAssertTrue(result?.mappings.first?.isDirectory == true); XCTAssertTrue(result?.canUndo == true)
        FileBrowserFaultGate.committed = nil
        _ = operation { service.undo(context, completion: $0) }
        _ = operation { service.redo(context, completion: $0) }
    }
    func testNativeTrashOriginalLocationRemainsValidWithoutServiceHistory() throws {
        let name = "native-origin-" + UUID().uuidString
        let path = try file(name, "native origin")
        var receipt: NSURL?
        FileBrowserFaultGate.trashInput = { input in
            XCTAssertTrue(input.isFileReferenceURL())
            let fileURL = input.perform(NSSelectorFromString("filePathURL"))?.takeUnretainedValue() as? NSURL
            XCTAssertEqual(fileURL?.lastPathComponent, name)
            if let parent = fileURL?.deletingLastPathComponent?.path {
                XCTAssertTrue(try! FileBrowserIdentity.read(parent).sameItem(FileBrowserIdentity.read(self.root.path)))
            } else { XCTFail("missing native origin parent") }
        }
        FileBrowserFaultGate.trashReceipt = { value in receipt = value; self.captureReceipt(value) }
        let result = operation { service.trash([path], context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.trashPath, receipt?.path)
        service = nil // No app undo stack participates in the following exact native receipt restoration.
        try FileManager.default.moveItem(at: XCTUnwrap(receipt) as URL, to: URL(fileURLWithPath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "native origin")
    }
    func testGlobDynamicProgrammingHasFiniteBudgetAndCancellation() throws {
        let cases: [(String, String, Bool)] = [
            ("**/*.swift", "a.swift", true), ("**/*.swift", "a/b.swift", true),
            ("*.swift", "a/b.swift", false), ("a/**/b?.txt", "a/b1.txt", true),
            ("a/**/b?.txt", "a/d/e/b1.txt", true), ("a/**/b?.txt", "a/d/e/b12.txt", false),
            ("**/skip.*", "skip.swift", true), ("a?c", "abc", true), ("a?c", "a/c", false)
        ]
        for (pattern, path, expected) in cases {
            var work = 10000
            XCTAssertEqual(try fileBrowserGlob(pattern).matches(path, isCancelled: { false }, remainingWork: &work), expected)
        }
        let costly = try fileBrowserGlob(String(repeating: "*a", count: 1000) + "b")
        var work = 10000
        XCTAssertThrowsError(try costly.matches(String(repeating: "a", count: 1000), isCancelled: { false }, remainingWork: &work)) {
            XCTAssertEqual(($0 as NSError).code, 6)
        }
        var cancellationChecks = 0; work = 4_000_000
        XCTAssertThrowsError(try costly.matches(String(repeating: "a", count: 1000), isCancelled: {
            cancellationChecks += 1; return cancellationChecks > 3
        }, remainingWork: &work)) { XCTAssertEqual(($0 as NSError).code, 1) }
        XCTAssertLessThanOrEqual(cancellationChecks, 5)
    }
    func testCostlyGlobQueryTerminatesWithinBudgetAndNextRootLoads() throws {
        let directory = String(repeating: "a", count: 200)
        let relative = (0..<3).map { _ in directory }.joined(separator: "/") + "/file"
        try file(relative, "needle")
        let pattern = String(repeating: "*a", count: 1000) + "b"
        let (_, final) = contents(iTermFileContentQuery(text: "needle", includeGlobs: Array(repeating: pattern, count: 4)))
        XCTAssertEqual(final?.error?.code, 6)
        context = makeContext(ignored: true, generation: 2); service.activate(context)
        XCTAssertEqual(listing().map(\.name), [directory])
    }
    func testNativeTrashLeafLinkNeverDeletesItsTarget() throws {
        let target = try file("target", "outside target")
        let link = root.appendingPathComponent("trash-link-" + UUID().uuidString).path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let result = operation { service.trash([link], context: context, completion: $0) }
        XCTAssertEqual(result?.mappings.first?.oldPath, link)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "outside target")
        _ = operation { service.undo(context, completion: $0) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
    }
    func testMissingTrashReceiptPathStillReportsCommittedDeletionWithoutUnsafeInverse() throws {
        let path = try file("missing-receipt-" + UUID().uuidString, "original")
        FileBrowserFaultGate.receiptPathUnavailable = true
        let result = operation(fails: true) { service.trash([path], context: context, completion: $0) }
        XCTAssertEqual(result?.error?.code, 10)
        XCTAssertEqual(result?.mappings.first?.oldPath, path); XCTAssertNil(result?.mappings.first?.newPath)
        XCTAssertNil(result?.mappings.first?.trashPath); XCTAssertFalse(result?.canUndo ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // The independent exact native receipt observer handles cleanup even when receipt bookkeeping fails.
    }
    private func stalledGit() throws -> URL {
        let executable = root.appendingPathComponent("owned-stalled-git-" + UUID().uuidString)
        try Data("#!/usr/bin/perl\n$SIG{TERM} = 'IGNORE';\nwhile (1) { select(undef, undef, undef, 3600); }\n".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        return executable
    }
    func testCancelledOwnedGitIsReapedBeforeNextRootListingWithoutWatchdogRescue() throws {
        try file("item")
        FileBrowserFaultGate.gitExecutable = try stalledGit()
        let started = expectation(description: "owned process launched")
        var owned: Process?
        FileBrowserFaultGate.gitStarted = { process in owned = process; started.fulfill() }
        service.searchNames("item", context: context) { _ in XCTFail("cancelled search published") }
        wait(for: [started], timeout: 10)
        let process = try XCTUnwrap(owned)
        var rescued = false
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        watchdog.schedule(deadline: .now() + 3)
        watchdog.setEventHandler { if process.isRunning { rescued = true; _ = kill(process.processIdentifier, SIGKILL) } }
        watchdog.resume(); defer { watchdog.cancel() }
        let nextRoot = root.appendingPathComponent("next-root")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: true)
        context = iTermFileBrowserContext(rootDirectory: nextRoot.path, projectIdentifier: "next", worktreeIdentifier: "w", generation: 2,
                                          showsGitIgnoredFiles: true)
        service.activate(context)
        _ = listing(nextRoot.path)
        XCTAssertFalse(rescued); XCTAssertFalse(process.isRunning)
        XCTAssertEqual(kill(process.processIdentifier, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testTimedOutOwnedGitIsReapedWithoutWatchdogRescue() throws {
        try file("item")
        FileBrowserFaultGate.gitExecutable = try stalledGit()
        var owned: Process?; var rescued = false
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        FileBrowserFaultGate.gitStarted = { process in
            owned = process
            watchdog.schedule(deadline: .now() + 5)
            watchdog.setEventHandler { if process.isRunning { rescued = true; _ = kill(process.processIdentifier, SIGKILL) } }
            watchdog.resume()
        }
        defer { watchdog.cancel() }
        _ = listing(fails: true)
        XCTAssertFalse(rescued); XCTAssertFalse(owned?.isRunning ?? true)
    }
#endif

}
