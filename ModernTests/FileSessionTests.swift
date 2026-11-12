import Foundation
import AppKit
import WebKit
import XCTest
@testable import iTerm2SharedARC

final class FileSessionTests: XCTestCase {
    func testDescriptorRejectsMalformedFileIdentityAndNeverContainsContent() throws {
        XCTAssertNil(iTermFileSessionDescriptor(dictionary: ["version": 99, "filePath": "/tmp/a"]))
        XCTAssertNil(iTermFileSessionDescriptor(dictionary: ["version": 1, "filePath": "relative", "rootDirectory": "/tmp"]))
        XCTAssertNil(iTermFileSessionDescriptor(dictionary: ["version": 1, "filePath": "/tmp/a", "rootDirectory": "/tmp", "documentIdentifier": "invalid"]))
        let descriptor = iTermFileSessionDescriptor(filePath: "/tmp/a", documentIdentifier: UUID().uuidString,
            rootDirectory: "/tmp", projectIdentifier: "project", worktreeIdentifier: "tree", preview: true,
            viewState: iTermFileViewState(dictionary: ["scrollTop": 12.0]))
        let decoded = try XCTUnwrap(iTermFileSessionDescriptor(dictionary: descriptor.dictionary))
        XCTAssertEqual(decoded.filePath, "/tmp/a")
        XCTAssertEqual(decoded.projectIdentifier, "project")
        XCTAssertTrue(decoded.preview)
        XCTAssertEqual(decoded.viewState.scrollTop, 12)
        XCTAssertNil(decoded.dictionary["text"])
        XCTAssertNil(decoded.dictionary["contents"])
    }

    func testCopiesShareDocumentButHaveDistinctPaneIdentityAndOwner() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = fixture.open("first", project: "one")
        let second = fixture.open("second", project: "two")
        XCTAssertEqual(first.documentIdentifier, second.documentIdentifier)
        XCTAssertNotEqual(first.viewIdentifier, second.viewIdentifier)
        XCTAssertEqual(first.descriptor.projectIdentifier, "one")
        XCTAssertEqual(second.descriptor.projectIdentifier, "two")
    }

    func testOnlyLastViewPromptsAndCancelPreservesDirtyText() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = fixture.open("first"), second = fixture.open("second")
        fixture.edit(first, "changed")
        fixture.coordinator.delegate = fixture
        fixture.decision = .cancel
        var allowed = false
        fixture.wait { done in fixture.coordinator.prepareClose([first], quitting: false) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        XCTAssertEqual(fixture.prompts, 0)
        fixture.coordinator.cancelOperation()
        fixture.wait { done in fixture.coordinator.prepareClose([first, second], quitting: false) { allowed = $0; done() } }
        XCTAssertFalse(allowed)
        XCTAssertEqual(fixture.prompts, 1)
        XCTAssertEqual(fixture.snapshot(first)?.text, "changed")
    }

    func testLastViewDiscardRemovesDraftAndRestoresDisk() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("first")
        fixture.edit(pane, "changed")
        fixture.coordinator.delegate = fixture; fixture.decision = .discard
        var allowed = false
        fixture.wait { done in fixture.coordinator.prepareClose([pane], quitting: false) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        XCTAssertEqual(fixture.snapshot(pane)?.text, "original")
        let recovering = iTermFileDocumentStore(storageDirectory: fixture.drafts)
        fixture.wait { done in recovering.recoverDrafts { values, error in XCTAssertNil(error); XCTAssertTrue(values.isEmpty); done() } }
        fixture.coordinator.cancelOperation()
    }

    func testQuitKeepDraftsDoesNotSaveSourceAndPreservesRecovery() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("first"); fixture.edit(pane, "changed")
        fixture.coordinator.delegate = fixture; fixture.decision = .keepDrafts
        var allowed = false
        fixture.wait { done in fixture.coordinator.prepareClose([pane], quitting: true) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), "original")
        let recovering = iTermFileDocumentStore(storageDirectory: fixture.drafts)
        fixture.wait { done in recovering.recoverDrafts { values, error in XCTAssertNil(error); XCTAssertEqual(values.first?.text, "changed"); done() } }
        fixture.coordinator.cancelOperation()
    }

    func testSaveFromSharedViewDrainsPreviousWriterDuringFocusTransfer() throws { try verifySharedViewSave(saveAs: false) }
    func testSaveAsFromSharedViewDrainsPreviousWriterDuringFocusTransfer() throws { try verifySharedViewSave(saveAs: true) }
    private func verifySharedViewSave(saveAs: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = fixture.open("first"), second = fixture.open("second")
        for pane in [first, second] {
            pane.delegate = fixture
            let ready = expectation(description: "editor ready")
            fixture.changed = { value in
                if value === pane && value.controller.status.isReady { fixture.changed = nil; ready.fulfill() }
            }
            pane.controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
            pane.controller.setVisible(true)
            wait(for: [ready], timeout: 20)
        }
        let firstWeb = try XCTUnwrap(first.controller.view.subviews.compactMap { $0 as? iTermFileWorkspaceWebView }.first)
        first.controller.focusEditor()
        let writable = expectation(description: "writer authority")
        firstWeb.callAsyncJavaScript("return new Promise(resolve => { const e = monaco.editor.getEditors()[0], k = monaco.editor.EditorOption.readOnly; if (!e.getOption(k)) { resolve(true); return; } const s = e.onDidChangeConfiguration(() => { if (!e.getOption(k)) { s.dispose(); resolve(true); } }); })", arguments: [:], in: nil, in: .page) { result in
            switch result { case .success(let value): XCTAssertEqual(value as? Bool, true); case .failure(let error): XCTFail("Authority query failed: \(error)") }; writable.fulfill()
        }
        wait(for: [writable], timeout: 10)
        let gate = EditGate(original: firstWeb.fileDelegate!)
        firstWeb.fileDelegate = gate
        defer { firstWeb.fileDelegate = gate.original }
        let edited = expectation(description: "edit held before native acceptance")
        gate.onEdit = { edited.fulfill() }
        firstWeb.send("paste", payload: ["text": "new-"])
        wait(for: [edited], timeout: 10)
        second.controller.focusEditor() // the first writer's acknowledgment is still outstanding
        var saved = false
        let save = expectation(description: "shared-view save")
        let destination = saveAs ? fixture.root.appendingPathComponent("saved.txt") : fixture.file
        fixture.coordinator.save(second, toPath: saveAs ? destination.path : nil, overwrite: false) { outcome, error in
            XCTAssertNil(error); XCTAssertEqual(outcome, .saved); saved = true; save.fulfill()
        }
        let checked = expectation(description: "second pane barrier and file IO ordered")
        second.controller.flushEdits(reason: .save) { error in
            XCTAssertNil(error)
            fixture.store.openFile(atPath: fixture.file.path) { _, error in
                XCTAssertNil(error)
                XCTAssertFalse(saved, "Save completed before the actual writer's held transaction")
                XCTAssertEqual(try? String(contentsOf: fixture.file, encoding: .utf8), "original")
                gate.release(); checked.fulfill()
            }
        }
        wait(for: [checked, save], timeout: 12)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new-original")
        XCTAssertEqual(fixture.snapshot(first)?.text, "new-original")
    }

    func testOpenFailurePaneCanCloseWithoutLosingBufferedInput() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var pane: iTermFileSessionPane?
        let context = iTermFileBrowserContext(rootDirectory: fixture.root.path, projectIdentifier: "p", worktreeIdentifier: "", generation: 1)
        fixture.wait { done in fixture.coordinator.openFile(atPath: fixture.root.appendingPathComponent("missing.txt").path,
            context: context, viewIdentifier: "missing", preview: false) { value, error in
                XCTAssertNotNil(error); pane = value; done()
            }
        }
        let failedPane = try XCTUnwrap(pane)
        XCTAssertFalse(failedPane.controller.status.hasPendingEdits)
        var allowed = false
        fixture.wait { done in fixture.coordinator.prepareClose([failedPane], quitting: false) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        fixture.coordinator.cancelOperation()
        fixture.wait { done in fixture.coordinator.prepareClose([failedPane], quitting: true) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        fixture.coordinator.cancelOperation()
    }

    func testRebindingPreservesPaneAndControllerButReleasesOldDocumentOwnership() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("one")
        let oldID = pane.documentIdentifier, controller = pane.controller
        let second = fixture.root.appendingPathComponent("second.txt")
        try Data("second".utf8).write(to: second)
        let descriptor = iTermFileSessionDescriptor(filePath: second.path, documentIdentifier: nil,
            rootDirectory: fixture.root.path, projectIdentifier: "different", worktreeIdentifier: "", preview: true, viewState: iTermFileViewState())
        fixture.wait { done in fixture.coordinator.rebind(pane, descriptor: descriptor, context: descriptor.context) { error in XCTAssertNil(error); done() } }
        XCTAssertTrue(pane.controller === controller)
        XCTAssertEqual(pane.viewIdentifier, "one")
        XCTAssertNotEqual(pane.documentIdentifier, oldID)
        XCTAssertEqual(fixture.snapshot(pane)?.text, "second")
        XCTAssertEqual(pane.descriptor.projectIdentifier, "different")
    }

    func testCanceledCloseDecisionCannotDiscardAfterOperationResumes() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("one"); fixture.edit(pane, "retained")
        fixture.coordinator.delegate = fixture
        fixture.deferDecision = true
        let asked = expectation(description: "decision captured")
        fixture.onDecision = { asked.fulfill() }
        let completed = expectation(description: "canceled decision retired")
        fixture.coordinator.prepareClose([pane], quitting: false) { allowed in XCTAssertFalse(allowed); completed.fulfill() }
        wait(for: [asked], timeout: 5)
        fixture.coordinator.cancelOperation()
        fixture.pendingDecision?(.discard)
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(fixture.snapshot(pane)?.text, "retained")
    }

    func testMissingDocumentDiscardLeavesClosableCleanMetadata() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("missing-after-edit")
        pane.delegate = fixture
        let ready = expectation(description: "actual controller ready")
        fixture.changed = { value in if value.controller.status.isReady { fixture.changed = nil; ready.fulfill() } }
        pane.controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        pane.controller.setVisible(true); wait(for: [ready], timeout: 20)
        fixture.edit(pane, "discard me")
        try FileManager.default.removeItem(at: fixture.file)
        fixture.coordinator.delegate = fixture; fixture.decision = .discard
        var allowed = false
        fixture.wait { done in fixture.coordinator.prepareClose([pane], quitting: false) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        XCTAssertNil(fixture.snapshot(pane)?.text)
        XCTAssertEqual(fixture.snapshot(pane)?.isDirty, false)
        fixture.coordinator.cancelOperation() // a later terminal confirmation can leave this pane open
        fixture.wait { done in fixture.coordinator.prepareClose([pane], quitting: true) { allowed = $0; done() } }
        XCTAssertTrue(allowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        fixture.coordinator.cancelOperation()
    }

    func testFileSplitRequiresBothPanesAndDividerToFit() {
        let old = NSSize(width: 395, height: 190), file = NSSize(width: 240, height: 190)
        XCTAssertFalse(iTermFilePaneGeometry.canSplit(size: NSSize(width: 635, height: 190), targetMinimum: old, fileMinimum: file, divider: 1, vertical: true))
        XCTAssertTrue(iTermFilePaneGeometry.canSplit(size: NSSize(width: 636, height: 190), targetMinimum: old, fileMinimum: file, divider: 1, vertical: true))
        XCTAssertFalse(iTermFilePaneGeometry.canSplit(size: NSSize(width: 636, height: 189), targetMinimum: old, fileMinimum: file, divider: 1, vertical: true))
        XCTAssertFalse(iTermFilePaneGeometry.canSplit(size: NSSize(width: 395, height: 380), targetMinimum: old, fileMinimum: file, divider: 1, vertical: false))
        XCTAssertTrue(iTermFilePaneGeometry.canSplit(size: NSSize(width: 395, height: 381), targetMinimum: old, fileMinimum: file, divider: 1, vertical: false))
        XCTAssertFalse(iTermFilePaneGeometry.canSplit(size: NSSize(width: CGFloat.nan, height: 381), targetMinimum: old, fileMinimum: file, divider: 1, vertical: false))
    }

    func testAbandonedAdmissionDoesNotResumeAnotherActiveOperation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let live = fixture.open("live"), abandoned = fixture.open("never-installed")
        live.delegate = fixture
        let ready = expectation(description: "live editor ready")
        fixture.changed = { pane in if pane === live && pane.controller.status.isReady { fixture.changed = nil; ready.fulfill() } }
        live.controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        live.controller.setVisible(true); live.controller.focusEditor(); wait(for: [ready], timeout: 20)
        let web = try XCTUnwrap(live.controller.view.subviews.compactMap { $0 as? iTermFileWorkspaceWebView }.first)
        fixture.wait { done in fixture.coordinator.beginOperation { error in XCTAssertNil(error); done() } }
        fixture.coordinator.abandon(abandoned)
        XCTAssertTrue(abandoned.closed)
        XCTAssertTrue(fixture.coordinator.operationInProgress)
        XCTAssertFalse(live.controller.canPerform(.paste))
        web.send("paste", payload: ["text": "must remain blocked"])
        fixture.wait { done in live.controller.flushEdits(reason: .save) { error in XCTAssertNil(error); done() } }
        XCTAssertEqual(fixture.snapshot(live)?.text, "original")
        fixture.wait { done in fixture.coordinator.finishOperation { error in XCTAssertNil(error); done() } }
        XCTAssertFalse(fixture.coordinator.operationInProgress)
        XCTAssertTrue(live.controller.canPerform(.paste))
    }

    private final class EditGate: FileUIWebViewDelegate {
        let original: FileUIWebViewDelegate
        var onEdit: (() -> Void)?
        private var pending: (() -> Void)?
        init(original: FileUIWebViewDelegate) { self.original = original }
        func release() { let action = pending; pending = nil; action?() }
        func fileUIWebViewReady(_ webView: iTermFileWorkspaceWebView) { original.fileUIWebViewReady(webView) }
        func fileUIWebView(_ webView: iTermFileWorkspaceWebView, failed error: NSError) { original.fileUIWebView(webView, failed: error) }
        func fileUIWebView(_ webView: iTermFileWorkspaceWebView, received type: String, payload: [String: Any], identifier: String) {
            if type == "edits" {
                pending = { self.original.fileUIWebView(webView, received: type, payload: payload, identifier: identifier) }
                onEdit?()
            } else { original.fileUIWebView(webView, received: type, payload: payload, identifier: identifier) }
        }
    }

    private final class Fixture: NSObject, iTermFileSessionCoordinatorDelegate, iTermFileSessionPaneDelegate {
        let root: URL, file: URL, drafts: URL
        let store: iTermFileDocumentStore
        let runtime: iTermFileWorkspaceUIRuntime
        let coordinator: iTermFileSessionCoordinator
        var panes = [iTermFileSessionPane]()
        var decision = iTermFileCloseDecision.cancel
        var prompts = 0
        var deferDecision = false
        var pendingDecision: ((iTermFileCloseDecision) -> Void)?
        var onDecision: (() -> Void)?
        var changed: ((iTermFileSessionPane) -> Void)?
        func fileSessionPaneDidChange(_ pane: iTermFileSessionPane) { changed?(pane) }
        func fileSessionPaneDidReceiveFocus(_ pane: iTermFileSessionPane) {}
        func fileSessionPane(_ pane: iTermFileSessionPane, request command: iTermFileViewCommand) {}

        init(testing: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("file.txt"); drafts = root.appendingPathComponent("drafts")
            try Data("original".utf8).write(to: file)
            store = iTermFileDocumentStore(storageDirectory: drafts)
            runtime = iTermFileWorkspaceUIRuntime(documentStore: store,
                resourceDirectory: ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath: $0) }, makeRenderer: { dataStore in
                    let web = iTermFileWorkspaceWebView(dataStore: dataStore)
                    web.configuration.userContentController.addUserScript(WKUserScript(source: "globalThis.MonacoEnvironment = { globalAPI: true };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
                    return web
                })
            coordinator = iTermFileSessionCoordinator(documentStore: store, runtime: runtime)
            super.init()
        }
        func wait(_ block: (@escaping () -> Void) -> Void) {
            let done = XCTestExpectation(description: "completion"); block { done.fulfill() }
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        }
        func open(_ id: String, project: String = "project") -> iTermFileSessionPane {
            var result: iTermFileSessionPane?
            let context = iTermFileBrowserContext(rootDirectory: root.path, projectIdentifier: project, worktreeIdentifier: "", generation: 1)
            wait { done in coordinator.openFile(atPath: file.path, context: context, viewIdentifier: id, preview: false) { pane, error in
                XCTAssertNil(error); result = pane; done()
            } }
            panes.append(result!); return result!
        }
        func snapshot(_ pane: iTermFileSessionPane) -> iTermFileDocumentSnapshot? {
            var result: iTermFileDocumentSnapshot?
            wait { done in store.snapshot(documentIdentifier: pane.documentIdentifier!) { result = $0; done() } }; return result
        }
        func edit(_ pane: iTermFileSessionPane, _ text: String) {
            let current = snapshot(pane)!
            wait { done in store.applyEdits([iTermFileTextEdit(range: NSRange(location: 0, length: (current.text! as NSString).length), replacement: text)],
                documentIdentifier: current.documentIdentifier, expectedRevision: current.revision) { _, error in XCTAssertNil(error); done() } }
        }
        func fileSessionCoordinator(_ coordinator: iTermFileSessionCoordinator, decideFor documents: [iTermFileDocumentSnapshot], quitting: Bool,
                                    completion: @escaping (iTermFileCloseDecision) -> Void) {
            prompts += 1
            if deferDecision { pendingDecision = completion; onDecision?() } else { completion(decision) }
        }
        func fileSessionCoordinator(_ coordinator: iTermFileSessionCoordinator, didFail error: NSError) { XCTFail("Unexpected error \(error)") }
        func cleanup() {
            coordinator.cancelOperation(); runtime.shutdown()
            wait { done in store.flushDrafts { _ in done() } }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
