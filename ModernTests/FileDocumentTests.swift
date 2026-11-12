import Foundation
import Darwin
import XCTest
@testable import iTerm2SharedARC

final class FileDocumentTests: XCTestCase {
    private var root: URL!
    private var allStores: [iTermFileDocumentStore] = []
    private var store: iTermFileDocumentStore! {
        didSet { if let store = store { allStores.append(store) } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = iTermFileDocumentStore(storageDirectory: root.appendingPathComponent("drafts"))
    }

    override func tearDownWithError() throws {
        for owner in allStores {
            let done = expectation(description: "flush before deleting fixtures")
            owner.flushDrafts { _ in done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        store = nil
        allStores.removeAll()
        try FileManager.default.removeItem(at: root)
    }

    private func fixture(_ name: String, _ data: Data) throws -> String {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    private func open(_ path: String) -> iTermFileDocumentSnapshot? {
        let done = expectation(description: "open")
        var result: iTermFileDocumentSnapshot?
        store.openFile(atPath: path) { snapshot, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            result = snapshot
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    func testOpenReusesCanonicalDocumentAndPreservesUTF8() throws {
        let path = try fixture("a.md", Data([0xef, 0xbb, 0xbf]) + Data("hello\r\n🌍\r\n".utf8))
        let link = root.appendingPathComponent("alias.md").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        let first = try XCTUnwrap(open(path))
        let second = try XCTUnwrap(open(link))
        XCTAssertEqual(first.documentIdentifier, second.documentIdentifier)
        XCTAssertEqual(first.text, "hello\r\n🌍\r\n")
        XCTAssertEqual(first.kind, .markdown)
        XCTAssertFalse(first.isDirty)
        XCTAssertFalse(first.isReadOnly)
        XCTAssertEqual(first.byteCount, 16)
    }
    private func fetch(_ id: String) -> iTermFileDocumentSnapshot? {
        let done = expectation(description: "snapshot")
        var result: iTermFileDocumentSnapshot?
        store.snapshot(documentIdentifier: id) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return result
    }

    private func edit(_ snapshot: iTermFileDocumentSnapshot, _ edits: [iTermFileTextEdit], fails: Bool = false) -> iTermFileDocumentSnapshot? {
        let done = expectation(description: "edit")
        var result: iTermFileDocumentSnapshot?
        store.applyEdits(edits, documentIdentifier: snapshot.documentIdentifier, expectedRevision: snapshot.revision) { value, error in
            XCTAssertTrue(Thread.isMainThread)
            if fails { XCTAssertNotNil(error) } else { XCTAssertNil(error) }
            result = value
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    private func replace(_ snapshot: iTermFileDocumentSnapshot, _ text: String) -> iTermFileDocumentSnapshot? {
        edit(snapshot, [iTermFileTextEdit(range: NSRange(location: 0, length: snapshot.text!.utf16.count), replacement: text)])
    }

    private func save(_ id: String, overwrite: Bool = false, toPath: String? = nil) -> iTermFileSaveOutcome {
        let done = expectation(description: "save")
        var result: iTermFileSaveOutcome = .failed
        let completion: (iTermFileSaveOutcome, NSError?) -> Void = { outcome, _ in
            XCTAssertTrue(Thread.isMainThread)
            result = outcome; done.fulfill()
        }
        if let path = toPath { store.saveAs(documentIdentifier: id, toPath: path, overwrite: overwrite, completion: completion) }
        else { store.save(documentIdentifier: id, overwrite: overwrite, completion: completion) }
        wait(for: [done], timeout: 10)
        return result
    }

    private func history(_ id: String, redo: Bool = false) -> iTermFileDocumentSnapshot? {
        let done = expectation(description: "history")
        var result: iTermFileDocumentSnapshot?
        let completion: (iTermFileDocumentSnapshot?, NSError?) -> Void = { value, error in
            XCTAssertNil(error); result = value; done.fulfill()
        }
        if redo { store.redo(documentIdentifier: id, completion: completion) }
        else { store.undo(documentIdentifier: id, completion: completion) }
        wait(for: [done], timeout: 10)
        return result
    }

    func testUnicodeEditsRejectInvalidTransactionsAtomicallyAndUndoAfterSave() throws {
        let path = try fixture("text", Data("A🌍BC".utf8))
        let initial = try XCTUnwrap(open(path))
        let invalid = [
            [iTermFileTextEdit(range: NSRange(location: 2, length: 1), replacement: "x")],
            [iTermFileTextEdit(range: NSRange(location: 0, length: 9), replacement: "x")],
            [iTermFileTextEdit(range: NSRange(location: 0, length: 3), replacement: "x"),
             iTermFileTextEdit(range: NSRange(location: 1, length: 0), replacement: "y")]
        ]
        for edits in invalid { _ = edit(initial, edits, fails: true) }
        XCTAssertEqual(fetch(initial.documentIdentifier)?.text, "A🌍BC")
        XCTAssertEqual(fetch(initial.documentIdentifier)?.revision, 0)
        let changed = try XCTUnwrap(edit(initial, [
            iTermFileTextEdit(range: NSRange(location: 1, length: 2), replacement: "🦋"),
            iTermFileTextEdit(range: NSRange(location: 4, length: 1), replacement: "!")]))
        XCTAssertEqual(changed.text, "A🦋B!")
        XCTAssertTrue(changed.isDirty)
        _ = edit(initial, [iTermFileTextEdit(range: NSRange(location: 0, length: 1), replacement: "z")], fails: true)
        XCTAssertEqual(save(changed.documentIdentifier), .saved)
        XCTAssertEqual(history(changed.documentIdentifier)?.text, "A🌍BC")
        XCTAssertTrue(fetch(changed.documentIdentifier)!.isDirty)
        XCTAssertEqual(history(changed.documentIdentifier, redo: true)?.text, "A🦋B!")
        XCTAssertFalse(fetch(changed.documentIdentifier)!.isDirty)
    }

    func testUTF16BothByteOrdersAndBOMRoundTripWithoutFormatting() throws {
        for (name, data) in [("le", Data([0xff, 0xfe, 0x61, 0, 0x0d, 0, 0x0a, 0])),
                             ("be", Data([0xfe, 0xff, 0, 0x61, 0, 0x0d, 0, 0x0a]))] {
            let path = try fixture(name, data)
            let initial = try XCTUnwrap(open(path))
            XCTAssertEqual(initial.text, "a\r\n")
            let changed = try XCTUnwrap(edit(initial, [iTermFileTextEdit(range: NSRange(location: 0, length: 1), replacement: "b")]))
            XCTAssertEqual(save(changed.documentIdentifier), .saved)
            var expected = data
            expected[name == "le" ? 2 : 3] = 0x62
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), expected)
        }
    }

    func testBinaryOversizeAndReadOnlyNeverBecomeEditable() throws {
        for (name, bytes, kind) in [("a.png", Data([0x89, 0x50, 0x4e, 0x47]), iTermFileDocumentKind.image),
                                    ("a.pdf", Data("%PDF-1.7".utf8), .pdf),
                                    ("a.bin", Data([0, 1, 255]), .unsupported)] {
            let snapshot = try XCTUnwrap(open(try fixture(name, bytes)))
            XCTAssertEqual(snapshot.kind, kind)
            XCTAssertNil(snapshot.text)
            XCTAssertTrue(snapshot.isReadOnly)
            XCTAssertEqual(save(snapshot.documentIdentifier), .readOnly)
        }
        let path = try fixture("large.txt", Data(repeating: 65, count: 10 * 1024 * 1024 + 1))
        let large = try XCTUnwrap(open(path))
        XCTAssertTrue(large.isTooLarge)
        XCTAssertNil(large.text)
        XCTAssertTrue(large.isReadOnly)
        let readOnlyPath = try fixture("readonly", Data("text".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyPath)
        let readOnly = try XCTUnwrap(open(readOnlyPath))
        XCTAssertTrue(readOnly.isReadOnly)
        XCTAssertEqual(save(readOnly.documentIdentifier), .readOnly)
    }

    func testConflictOverwriteDeletedSourceSaveAsAndPermissions() throws {
        let path = try fixture("file", Data("first".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let initial = try XCTUnwrap(open(path))
        let changed = try XCTUnwrap(replace(initial, "mine"))
        try Data("other".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(save(changed.documentIdentifier), .conflict)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "other")
        XCTAssertTrue(fetch(changed.documentIdentifier)!.hasDiskConflict)
        XCTAssertEqual(save(changed.documentIdentifier, overwrite: true), .saved)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "mine")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let collision = try fixture("collision", Data("keep".utf8))
        XCTAssertEqual(save(changed.documentIdentifier, toPath: collision), .conflict)
        XCTAssertEqual(try String(contentsOfFile: collision, encoding: .utf8), "keep")
        let newPath = root.appendingPathComponent("new").path
        XCTAssertEqual(save(changed.documentIdentifier, toPath: newPath), .saved)
        XCTAssertEqual(fetch(changed.documentIdentifier)?.filePath, newPath)
        XCTAssertEqual(open(newPath)?.documentIdentifier, changed.documentIdentifier)
        try FileManager.default.removeItem(atPath: newPath)
        XCTAssertEqual(save(changed.documentIdentifier, overwrite: true), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPath))
    }

    func testEditDuringCoordinatedSaveLeavesLatestTextDirty() throws {
        let path = try fixture("gated", Data("disk".utf8))
        let first = try XCTUnwrap(replace(try XCTUnwrap(open(path)), "captured"))
        let acquired = expectation(description: "coordinator acquired")
        let released = expectation(description: "coordinator released")
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: path), options: [], error: &error) { _ in
                acquired.fulfill()
                _ = gate.wait(timeout: .now() + 10)
            }
            XCTAssertNil(error)
            released.fulfill()
        }
        wait(for: [acquired], timeout: 10)
        let saved = expectation(description: "saved")
        store.save(documentIdentifier: first.documentIdentifier, overwrite: false) { outcome, error in
            XCTAssertEqual(outcome, .saved); XCTAssertNil(error); saved.fulfill()
        }
        let latest = try XCTUnwrap(replace(first, "latest"))
        gate.signal()
        wait(for: [saved, released], timeout: 10)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "captured")
        XCTAssertEqual(fetch(latest.documentIdentifier)?.text, "latest")
        XCTAssertTrue(fetch(latest.documentIdentifier)!.isDirty)
    }

    private func persist(_ id: String) {
        let done = expectation(description: "draft")
        store.persistDraft(documentIdentifier: id) { error in XCTAssertNil(error); done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func recover(expectError: Bool = false) -> [iTermFileDocumentSnapshot] {
        let done = expectation(description: "recover")
        var result: [iTermFileDocumentSnapshot] = []
        store.recoverDrafts { value, error in
            if expectError { XCTAssertNotNil(error) } else { XCTAssertNil(error) }
            result = value; done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    func testDraftRecoveryConflictsCorruptionAndDiscard() throws {
        let path = try fixture("draft-source", Data("baseline".utf8))
        let changed = try XCTUnwrap(replace(try XCTUnwrap(open(path)), "unsaved 🌍"))
        persist(changed.documentIdentifier)
        let draftDirectory = root.appendingPathComponent("drafts")
        let files = try FileManager.default.contentsOfDirectory(at: draftDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("external".utf8).write(to: URL(fileURLWithPath: path))
        store = iTermFileDocumentStore(storageDirectory: draftDirectory)
        let recovered = try XCTUnwrap(recover().first)
        XCTAssertEqual(recovered.documentIdentifier, changed.documentIdentifier)
        XCTAssertEqual(recovered.text, "unsaved 🌍")
        XCTAssertTrue(recovered.isDirty)
        XCTAssertTrue(recovered.hasDiskConflict)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "external")
        try Data("bad json".utf8).write(to: draftDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        XCTAssertEqual(recover(expectError: true).count, 1)
        let done = expectation(description: "discard")
        store.discardChanges(documentIdentifier: recovered.documentIdentifier) { value, error in
            XCTAssertNil(error); XCTAssertEqual(value?.text, "external"); XCTAssertFalse(value!.isDirty); done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
    }

    func testUndoRestoresAdjacentDeletionsAndNotificationCarriesDeltas() throws {
        let initial = try XCTUnwrap(open(try fixture("adjacent", Data("abcde".utf8))))
        let notified = expectation(description: "delta notification")
        let token = NotificationCenter.default.addObserver(forName: Notification.Name(iTermFileDocumentStore.didChangeNotification), object: store, queue: nil) { notification in
            XCTAssertTrue(Thread.isMainThread)
            let snapshot = notification.userInfo?["snapshot"] as? iTermFileDocumentSnapshot
            if snapshot?.revision == 1 {
                XCTAssertEqual((notification.userInfo?["edits"] as? [iTermFileTextEdit])?.count, 2)
                XCTAssertEqual(snapshot?.text, "ade")
                notified.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let changed = try XCTUnwrap(edit(initial, [
            iTermFileTextEdit(range: NSRange(location: 1, length: 1), replacement: ""),
            iTermFileTextEdit(range: NSRange(location: 2, length: 1), replacement: "")]))
        wait(for: [notified], timeout: 10)
        XCTAssertEqual(history(changed.documentIdentifier)?.text, "abcde")
        XCTAssertEqual(history(changed.documentIdentifier, redo: true)?.text, "ade")
    }

    func testRejectsUnsafePathsAndSourceIdentityChanges() throws {
        let special = root.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(special, 0o600), 0)
        for path in ["relative", root.path, root.path + "/null\0", special] {
            let done = expectation(description: "reject unsafe path")
            store.openFile(atPath: path) { value, error in XCTAssertNil(value); XCTAssertNotNil(error); done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        let path = try fixture("identity", Data("same bytes".utf8))
        let initial = try XCTUnwrap(open(path))
        _ = replace(initial, "mine")
        try Data("same bytes".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertEqual(save(initial.documentIdentifier), .conflict)
        XCTAssertEqual(save(initial.documentIdentifier, overwrite: true, toPath: special), .failed)
        let alias = root.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
        store = iTermFileDocumentStore(storageDirectory: root.appendingPathComponent("other-drafts"))
        let aliasDocument = try XCTUnwrap(open(alias))
        _ = replace(aliasDocument, "edit")
        let other = try fixture("other", Data("keep".utf8))
        try FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: other)
        XCTAssertEqual(save(aliasDocument.documentIdentifier, overwrite: true), .conflict)
        XCTAssertEqual(try String(contentsOfFile: other, encoding: .utf8), "keep")
    }

    func testUTF8BOMAndFinalNewlinePreservedOnSave() throws {
        let path = try fixture("bom.txt", Data([0xef, 0xbb, 0xbf]) + Data("a\r\n".utf8))
        let initial = try XCTUnwrap(open(path))
        _ = edit(initial, [iTermFileTextEdit(range: NSRange(location: 0, length: 1), replacement: "b")])
        XCTAssertEqual(save(initial.documentIdentifier), .saved)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([0xef, 0xbb, 0xbf, 0x62, 0x0d, 0x0a]))
    }

    func testSaveAsExplicitOverwriteAndRejectsOpenDestination() throws {
        let path = try fixture("source", Data("source".utf8))
        let initial = try XCTUnwrap(open(path))
        let target = try fixture("target", Data("target".utf8))
        let targetDocument = try XCTUnwrap(open(target))
        XCTAssertEqual(save(initial.documentIdentifier, overwrite: true, toPath: target), .conflict)
        XCTAssertEqual(fetch(targetDocument.documentIdentifier)?.text, "target")
        let other = try fixture("not-open", Data("old".utf8))
        XCTAssertEqual(save(initial.documentIdentifier, overwrite: true, toPath: other), .saved)
        XCTAssertEqual(try String(contentsOfFile: other, encoding: .utf8), "source")
    }

    func testDiskHooksReloadCleanPreserveDirtyAndFollowMoves() throws {
        let path = try fixture("watched", Data("first".utf8))
        let initial = try XCTUnwrap(open(path))
        try Data("second".utf8).write(to: URL(fileURLWithPath: path))
        let reloaded = expectation(description: "reloaded")
        store.fileDidChange(atPath: path) { value, error in
            XCTAssertNil(error); XCTAssertEqual(value?.text, "second"); XCTAssertFalse(value!.isDirty); reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 10)
        _ = replace(try XCTUnwrap(fetch(initial.documentIdentifier)), "mine")
        try Data("third".utf8).write(to: URL(fileURLWithPath: path))
        let conflict = expectation(description: "conflict hook")
        store.fileDidChange(atPath: path) { value, error in
            XCTAssertNil(error); XCTAssertEqual(value?.text, "mine"); XCTAssertTrue(value!.hasDiskConflict); conflict.fulfill()
        }
        wait(for: [conflict], timeout: 10)
        let destination = root.appendingPathComponent("moved").path
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        let moved = expectation(description: "move hook")
        store.fileDidMove(fromPath: path, toPath: destination) { value, error in
            XCTAssertNil(error); XCTAssertEqual(value?.filePath, destination)
            XCTAssertEqual(value?.documentIdentifier, initial.documentIdentifier); moved.fulfill()
        }
        wait(for: [moved], timeout: 10)
        XCTAssertEqual(save(initial.documentIdentifier), .conflict)
        XCTAssertEqual(save(initial.documentIdentifier, overwrite: true), .saved)
        let descriptor = expectation(description: "restorable path")
        store.restorableDescriptor(documentIdentifier: initial.documentIdentifier) { value in
            XCTAssertEqual(value?["documentIdentifier"] as? String, initial.documentIdentifier)
            XCTAssertEqual(value?["filePath"] as? String, destination)
            XCTAssertNil(value?["text"])
            descriptor.fulfill()
        }
        wait(for: [descriptor], timeout: 10)
    }

    func testDraftRecoveryWithoutDiskAndOversizeOrSymlinkDraftsSkipped() throws {
        let path = try fixture("deleted-draft", Data("baseline".utf8))
        let changed = try XCTUnwrap(replace(try XCTUnwrap(open(path)), "recover"))
        persist(changed.documentIdentifier)
        try FileManager.default.removeItem(atPath: path)
        let directory = root.appendingPathComponent("drafts")
        let huge = directory.appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 70 * 1024 * 1024)
        try handle.close()
        let link = directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: try fixture("not-a-draft", Data("private fixture".utf8))))
        store = iTermFileDocumentStore(storageDirectory: directory)
        let recovered = try XCTUnwrap(recover(expectError: true).first)
        XCTAssertEqual(recovered.text, "recover")
        XCTAssertTrue(recovered.hasDiskConflict)
        XCTAssertTrue(recovered.isDirty)
        XCTAssertEqual(save(recovered.documentIdentifier, overwrite: true), .missing)
        let done = expectation(description: "remove draft")
        store.removeDraft(documentIdentifier: recovered.documentIdentifier) { error in XCTAssertNil(error); done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(changed.documentIdentifier + ".json").path))
    }

    func testSavePreservesExtendedAttributesAndClassifiesImageMagic() throws {
        let path = try fixture("attributes", Data("text".utf8))
        let attribute = "org.iterm2.document-test"
        let payload = Array("metadata".utf8)
        let status = payload.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(status, 0)
        let initial = try XCTUnwrap(open(path))
        _ = replace(initial, "changed")
        XCTAssertEqual(save(initial.documentIdentifier), .saved)
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = getxattr(path, attribute, &bytes, bytes.count, 0, 0)
        XCTAssertEqual(count, 8)
        XCTAssertEqual(Array(bytes.prefix(max(0, count))), payload)
        let image = try XCTUnwrap(open(try fixture("extensionless", Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]))))
        XCTAssertEqual(image.kind, .image)
        XCTAssertTrue(image.isReadOnly)
    }

    func testReleaseKeepsDraftAndUnknownOrConcurrentOperationsReportFailures() throws {
        let initial = try XCTUnwrap(open(try fixture("release", Data("baseline".utf8))))
        _ = replace(initial, "draft")
        let released = expectation(description: "release cache")
        store.releaseDocument(documentIdentifier: initial.documentIdentifier) { error in XCTAssertNil(error); released.fulfill() }
        wait(for: [released], timeout: 10)
        XCTAssertNil(fetch(initial.documentIdentifier))
        let recovered = try XCTUnwrap(recover().first)
        XCTAssertEqual(recovered.documentIdentifier, initial.documentIdentifier)
        XCTAssertEqual(recovered.text, "draft")
        XCTAssertEqual(save(UUID().uuidString), .missing)
        XCTAssertEqual(save(recovered.documentIdentifier, toPath: "relative"), .failed)
        XCTAssertEqual(fetch(recovered.documentIdentifier)?.text, "draft")
    }

    func testConcurrentSaveRejectsStaleAndMaximumEditIsBounded() throws {
        let path = try fixture("busy", Data("base".utf8))
        let initial = try XCTUnwrap(open(path))
        _ = replace(initial, "new")
        let acquired = expectation(description: "hold busy file")
        let released = expectation(description: "release busy file")
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: path), options: [], error: &error) { _ in
                acquired.fulfill(); _ = gate.wait(timeout: .now() + 10)
            }
            XCTAssertNil(error); released.fulfill()
        }
        wait(for: [acquired], timeout: 10)
        let saved = expectation(description: "first save")
        store.save(documentIdentifier: initial.documentIdentifier, overwrite: false) { outcome, error in
            XCTAssertEqual(outcome, .saved); XCTAssertNil(error); saved.fulfill()
        }
        XCTAssertEqual(save(initial.documentIdentifier), .stale)
        gate.signal()
        wait(for: [saved, released], timeout: 10)
        let maximumPath = try fixture("maximum.txt", Data(repeating: 65, count: 10 * 1024 * 1024))
        let maximum = try XCTUnwrap(open(maximumPath))
        XCTAssertFalse(maximum.isReadOnly)
        XCTAssertFalse(maximum.isTooLarge)
        XCTAssertEqual(maximum.text?.utf16.count, 10 * 1024 * 1024)
        _ = edit(maximum, [iTermFileTextEdit(range: NSRange(location: 0, length: 0), replacement: "B")], fails: true)
        XCTAssertEqual(fetch(maximum.documentIdentifier)?.revision, maximum.revision)
    }

    // The coordinated read blocks the production IO queue while state-queue edits continue.
    private func holdIO() throws -> (DispatchSemaphore, XCTestExpectation, XCTestExpectation) {
        let path = try fixture("io-gate", Data("gate".utf8))
        let acquired = expectation(description: "acquire IO gate")
        let released = expectation(description: "release IO gate")
        let opened = expectation(description: "gated read completes")
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: path), options: [], error: &error) { _ in
                acquired.fulfill()
                _ = gate.wait(timeout: .now() + 10)
            }
            XCTAssertNil(error)
            released.fulfill()
        }
        wait(for: [acquired], timeout: 10)
        store.openFile(atPath: path) { value, error in XCTAssertNotNil(value); XCTAssertNil(error); opened.fulfill() }
        return (gate, released, opened)
    }

    private func explicitPersistenceKeepsLatestDraft(flush: Bool) throws {
        let path = try fixture("persist-race", Data("baseline".utf8))
        let initial = try XCTUnwrap(open(path))
        let (gate, released, opened) = try holdIO()
        defer { gate.signal() }
        let first = try XCTUnwrap(replace(initial, "A"))
        let persisted = expectation(description: "explicit persistence")
        let completion: (NSError?) -> Void = { error in XCTAssertNil(error); persisted.fulfill() }
        if flush { store.flushDrafts(completion: completion) }
        else { store.persistDraft(documentIdentifier: first.documentIdentifier, completion: completion) }
        _ = try XCTUnwrap(replace(first, "B"))
        gate.signal()
        wait(for: [released, opened, persisted], timeout: 10)
        store = iTermFileDocumentStore(storageDirectory: root.appendingPathComponent("drafts"))
        let recovered = try XCTUnwrap(recover().first)
        XCTAssertEqual(recovered.text, "B")
        XCTAssertEqual(recovered.documentIdentifier, initial.documentIdentifier)
    }

    func testPersistCapturesLatestAfterQueuedAutomaticPersistence() throws {
        try explicitPersistenceKeepsLatestDraft(flush: false)
    }

    func testFlushCapturesLatestAfterQueuedAutomaticPersistence() throws {
        try explicitPersistenceKeepsLatestDraft(flush: true)
    }

    func testMoveDuringReleaseRetainsDirtyDraftAtNewPath() throws {
        let path = try fixture("move-release", Data("disk".utf8))
        let initial = try XCTUnwrap(replace(try XCTUnwrap(open(path)), "dirty"))
        persist(initial.documentIdentifier)
        let destination = root.appendingPathComponent("move-release-destination").path
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        let acquired = expectation(description: "hold destination read")
        let released = expectation(description: "destination gate released")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: destination), options: [], error: &error) { _ in
                acquired.fulfill(); _ = gate.wait(timeout: .now() + 10)
            }
            XCTAssertNil(error); released.fulfill()
        }
        wait(for: [acquired], timeout: 10)
        let moved = expectation(description: "move completed")
        store.fileDidMove(fromPath: path, toPath: destination) { value, error in
            XCTAssertNil(error); XCTAssertEqual(value?.filePath, destination); moved.fulfill()
        }
        let releaseCompleted = expectation(description: "release becomes stale after metadata change")
        store.releaseDocument(documentIdentifier: initial.documentIdentifier) { error in
            XCTAssertEqual(error?.domain, "iTermFileDocumentError")
            XCTAssertEqual(error?.code, 7)
            releaseCompleted.fulfill()
        }
        // State FIFO ensures move and release have both been scheduled while the read is held.
        XCTAssertEqual(fetch(initial.documentIdentifier)?.filePath, path)
        gate.signal()
        wait(for: [moved, released, releaseCompleted], timeout: 10)
        // An ordinary open is a deterministic IO barrier behind the move’s automatic draft job.
        _ = try XCTUnwrap(open(destination))
        store = iTermFileDocumentStore(storageDirectory: root.appendingPathComponent("drafts"))
        let recovered = try XCTUnwrap(recover().first)
        XCTAssertEqual(recovered.documentIdentifier, initial.documentIdentifier)
        XCTAssertEqual(recovered.filePath, destination)
        XCTAssertEqual(recovered.text, "dirty")
    }

    func testPermissionOnlyWatcherEventsRefreshAccessWithoutChangingRevisionOrHistory() throws {
        let path = try fixture("chmod", Data("text".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        let initial = try XCTUnwrap(open(path))
        XCTAssertTrue(initial.isReadOnly)
        for mode in [0o644, 0o444, 0o644] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            let done = expectation(description: "chmod watcher")
            store.fileDidChange(atPath: path) { value, error in
                XCTAssertNil(error); XCTAssertEqual(value?.isReadOnly, mode == 0o444)
                XCTAssertEqual(value?.revision, initial.revision)
                XCTAssertEqual(value?.text, "text"); done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }
        let changed = try XCTUnwrap(replace(try XCTUnwrap(fetch(initial.documentIdentifier)), "edited"))
        XCTAssertEqual(save(changed.documentIdentifier), .saved)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        let locked = expectation(description: "saved clean document locks")
        store.fileDidChange(atPath: path) { value, error in
            XCTAssertNil(error); XCTAssertTrue(value!.isReadOnly)
            XCTAssertEqual(value?.revision, changed.revision); locked.fulfill()
        }
        wait(for: [locked], timeout: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        let unlocked = expectation(description: "saved clean document unlocks")
        store.fileDidChange(atPath: path) { value, error in XCTAssertNil(error); XCTAssertFalse(value!.isReadOnly); unlocked.fulfill() }
        wait(for: [unlocked], timeout: 10)
        XCTAssertEqual(history(changed.documentIdentifier)?.text, "text")
    }

    func testOrphanDraftCleanupValidatesNamesTypesAndAccountsRemainingOwnedFiles() throws {
        let directory = root.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data("partial".utf8), attributes: [.posixPermissions: 0o600]))
        let hugeOrphan = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: hugeOrphan.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let handle = try FileHandle(forWritingTo: hugeOrphan)
        try handle.truncate(atOffset: 140 * 1024 * 1024)
        try handle.close()
        let unrelated = directory.appendingPathComponent(".draft-not-a-uuid")
        try Data("leave alone".utf8).write(to: unrelated)
        let privateFixture = try fixture("orphan-link-target", Data("keep".utf8))
        let symlink = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: privateFixture)
        let protectedDirectory = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        XCTAssertTrue(recover().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hugeOrphan.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "leave alone")
        XCTAssertEqual(try String(contentsOfFile: privateFixture, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedDirectory.path))
        let initial = try XCTUnwrap(replace(try XCTUnwrap(open(try fixture("budget", Data("disk".utf8)))), "draft"))
        persist(initial.documentIdentifier)
        // Unremovable owned-name directories still count toward the file budget.
        for _ in 0..<100 {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(".draft-" + UUID().uuidString), withIntermediateDirectories: false)
        }
        let denied = expectation(description: "owned file budget enforced")
        store.persistDraft(documentIdentifier: initial.documentIdentifier) { error in
            XCTAssertEqual(error?.domain, "iTermFileDocumentError"); XCTAssertEqual(error?.code, 4); denied.fulfill()
        }
        wait(for: [denied], timeout: 10)
    }

    func testRetainedUnsafeOrphanBytesAreReportedAndBlockFurtherWrites() throws {
        let initial = try XCTUnwrap(replace(try XCTUnwrap(open(try fixture("byte-budget", Data("disk".utf8)))), "draft"))
        persist(initial.documentIdentifier)
        let directory = root.appendingPathComponent("drafts")
        let protected = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: protected.path, contents: nil, attributes: [.posixPermissions: 0o644]))
        let handle = try FileHandle(forWritingTo: protected)
        try handle.truncate(atOffset: 128 * 1024 * 1024 + 1)
        try handle.close()
        let privatePath = try fixture("hardlink-private", Data("do not remove".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privatePath)
        let hardlink = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        try FileManager.default.linkItem(atPath: privatePath, toPath: hardlink.path)
        XCTAssertEqual(recover(expectError: true).first?.text, "draft")
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardlink.path))
        XCTAssertEqual(try String(contentsOfFile: privatePath, encoding: .utf8), "do not remove")
        let done = expectation(description: "byte budget rejects write")
        store.persistDraft(documentIdentifier: initial.documentIdentifier) { error in
            XCTAssertEqual(error?.domain, "iTermFileDocumentError"); XCTAssertEqual(error?.code, 4); done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    private func draftFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("drafts"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func draftByteCount() throws -> UInt64 {
        try draftFiles().reduce(0) { total, file in
            total + (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).uint64Value
        }
    }

    private func expectPersistenceBound(_ id: String) {
        let done = expectation(description: "steady draft quota rejects new record")
        store.persistDraft(documentIdentifier: id) { error in
            XCTAssertEqual(error?.domain, "iTermFileDocumentError"); XCTAssertEqual(error?.code, 4); done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testHundredCommittedDraftsRemainUpdateableAndRejectNewAdmission() throws {
        var first: iTermFileDocumentSnapshot?
        for index in 0..<100 {
            let path = try fixture("count-\(index)", Data("disk".utf8))
            let changed = try XCTUnwrap(replace(try XCTUnwrap(open(path)), "draft-\(index)"))
            persist(changed.documentIdentifier)
            if index == 0 { first = changed }
        }
        XCTAssertEqual(try draftFiles().count, 100)
        let changed = try XCTUnwrap(replace(try XCTUnwrap(first), "newest at capacity"))
        persist(changed.documentIdentifier)
        let extra = try XCTUnwrap(replace(try XCTUnwrap(open(try fixture("count-extra", Data("disk".utf8)))), "denied"))
        expectPersistenceBound(extra.documentIdentifier)
        XCTAssertEqual(try draftFiles().count, 100)
        store = iTermFileDocumentStore(storageDirectory: root.appendingPathComponent("drafts"))
        let snapshots = recover()
        XCTAssertEqual(snapshots.count, 100)
        XCTAssertEqual(snapshots.first { $0.documentIdentifier == changed.documentIdentifier }?.text, "newest at capacity")
        XCTAssertNil(snapshots.first { $0.documentIdentifier == extra.documentIdentifier })
    }

    func testSteadyByteCapacityAllowsReplacementAndShrinkWhileRejectingNewAdmission() throws {
        // Six real JSON-escaped text drafts occupy just over 120 MiB; each source text is
        // within 10 MiB. The final ASCII draft fills the actual on-disk envelope sum exactly.
        let escaped = String(repeating: "\"", count: 10 * 1024 * 1024)
        for index in 0..<6 {
            let path = try fixture("bytes-\(index)", Data("disk".utf8))
            let changed = try XCTUnwrap(replace(try XCTUnwrap(open(path)), escaped))
            persist(changed.documentIdentifier)
        }
        let path = try fixture("bytes-fill", Data("disk".utf8))
        let initial = try XCTUnwrap(replace(try XCTUnwrap(open(path)), "A"))
        persist(initial.documentIdentifier)
        let capacity: UInt64 = 128 * 1024 * 1024
        let currentBytes = try draftByteCount()
        XCTAssertLessThan(currentBytes, capacity)
        let fillCount = Int(capacity - currentBytes) + 1
        XCTAssertLessThan(fillCount, 10 * 1024 * 1024)
        let filled = try XCTUnwrap(replace(initial, String(repeating: "A", count: fillCount)))
        persist(filled.documentIdentifier)
        let actualBytes = try draftByteCount()
        XCTAssertEqual(actualBytes, capacity)
        guard actualBytes == capacity else { return }
        let updated = try XCTUnwrap(replace(filled, String(repeating: "B", count: fillCount)))
        persist(updated.documentIdentifier)
        XCTAssertEqual(try draftByteCount(), capacity)
        let extra = try XCTUnwrap(replace(try XCTUnwrap(open(try fixture("bytes-extra", Data("disk".utf8)))), "new"))
        expectPersistenceBound(extra.documentIdentifier)
        XCTAssertEqual(try draftFiles().count, 7)
        XCTAssertEqual(try draftByteCount(), capacity)
        // Inspect a production envelope to ensure equal-size replacement advanced the recovery content.
        let recordURL = root.appendingPathComponent("drafts").appendingPathComponent(updated.documentIdentifier + ".json")
        let record = try JSONDecoder().decode(FileDocumentDraft.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(record.text.utf8.count, fillCount)
        XCTAssertTrue(record.text.allSatisfy { $0 == "B" })
        let shrunk = try XCTUnwrap(replace(updated, "shrunk"))
        persist(shrunk.documentIdentifier)
        XCTAssertLessThan(try draftByteCount(), capacity)
        persist(extra.documentIdentifier)
        XCTAssertEqual(try draftFiles().count, 8)
        let shrunkRecord = try JSONDecoder().decode(FileDocumentDraft.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(shrunkRecord.text, "shrunk")
    }

}
