import Foundation
import AppKit
import WebKit
import XCTest
@testable import iTerm2SharedARC

final class FileSessionTests: XCTestCase {
    func testWorkspaceBrowserBackendRoundTripAndPausedSurfacePreserveQuery() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let browser = iTermFileBrowserCoordinator(native: f.coordinator); defer { browser.shutdown() }
        let other = iTermFileBrowserCoordinator(native: f.coordinator); defer { other.shutdown() }
        let context = iTermFileBrowserContext(rootDirectory: f.root.path, projectIdentifier: "project", worktreeIdentifier: "", generation: 1)
        var warm: FileUIAcquisition?
        f.wait { done in warm = f.runtime.acquire(owner: f) { _, error in XCTAssertNil(error); done() } }; warm?.cancel()
        browser.applyContext(context); browser.controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600); browser.setVisible(true)
        let web = try XCTUnwrap(browser.controller.preferredFirstResponder as? iTermFileWorkspaceWebView)
        let ready = expectation(description: "explorer receiver ready")
        let gate = BrowserGate(original: browser.controller, ready: { ready.fulfill() }); web.fileDelegate = gate
        wait(for: [ready], timeout: 20)
        func evaluate(_ script: String, arguments: [String: Any] = [:]) throws -> Any? {
            var result: Result<Any, Error>?
            f.wait { done in web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result = $0; done() } }
            return try result?.get()
        }
        let rows = "return new Promise(resolve => { const check = () => { const row = [...document.querySelectorAll('[data-path]')].find(r => r.dataset.path === path); if (row) { observer.disconnect(); resolve(row.textContent); } }; const observer = new MutationObserver(check); observer.observe(document.body, {childList:true,subtree:true}); check(); });"
        XCTAssertNotNil(try evaluate(rows, arguments: ["path": f.file.path]))
        let pane = f.open("shared")
        // A second explorer activation must not reset the first backend's context.
        other.applyContext(iTermFileBrowserContext(rootDirectory: f.root.path, projectIdentifier: "other", worktreeIdentifier: "", generation: 2))
        _ = try evaluate("const q=document.querySelector('[data-query=names]'); q.value='file'; q.dispatchEvent(new Event('input',{bubbles:true})); return true;")
        browser.setVisible(false); browser.setVisible(true)
        XCTAssertTrue(web === browser.controller.preferredFirstResponder)
        XCTAssertEqual(try evaluate("return document.querySelector('[data-query=names]').value;") as? String, "file")
        let request = try XCTUnwrap(iTermFileBrowserRequest(identifier: "rename", context: context, type: "rename", payload: ["paths": [f.file.path], "name": "file-renamed.txt"]))
        browser.fileBrowser(browser.controller, didRequest: request)
        let target = f.root.appendingPathComponent("file-renamed.txt")
        XCTAssertNotNil(try evaluate(rows, arguments: ["path": target.path]))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(pane.descriptor.filePath, target.path)
        XCTAssertFalse(f.coordinator.operationInProgress)
        f.edit(pane, "unsaved buffer"); f.coordinator.delegate = f; f.decision = .cancel
        let duplicate = try XCTUnwrap(iTermFileBrowserRequest(identifier: "duplicate", context: context, type: "duplicateFile", payload: ["paths": [target.path], "name": "file-copy.txt"]))
        browser.fileBrowser(browser.controller, didRequest: duplicate)
        XCTAssertNotNil(try evaluate(rows, arguments: ["path": f.root.appendingPathComponent("file-copy.txt").path]))
        XCTAssertEqual(f.prompts, 0); XCTAssertEqual(f.snapshot(pane)?.text, "unsaved buffer")
        let visibility = try XCTUnwrap(iTermFileBrowserRequest(identifier: "visibility", context: context, type: "setVisibility", payload: ["showsHiddenFiles": true, "showsGitIgnoredFiles": true]))
        browser.fileBrowser(browser.controller, didRequest: visibility)
        XCTAssertEqual(browser.context?.showsHiddenFiles, true)
        let alternate = iTermFileBrowserContext(rootDirectory: f.root.path, projectIdentifier: "alternate", worktreeIdentifier: "", generation: 4)
        browser.applyContext(alternate)
        XCTAssertEqual(browser.context?.showsHiddenFiles, true); XCTAssertEqual(browser.context?.showsGitIgnoredFiles, true)
        _ = try evaluate("window.task5UndoReady=new Promise(resolve => { const original=window.fileWorkspace.receive; window.fileWorkspace.receive=async function(message) { await original.call(this,message); if(message.type==='operationState' && message.payload.canUndo) { window.fileWorkspace.receive=original; resolve(true); } }; }); return true;")
        browser.applyContext(context)
        XCTAssertEqual(browser.context?.projectIdentifier, "project"); XCTAssertEqual(browser.context?.showsHiddenFiles, true)
        // The actual page receives this root's journal state after the renderer's new context is ready.
        XCTAssertEqual(try evaluate("return window.task5UndoReady;") as? Bool, true)
        browser.shutdown()
        other.applyContext(context); other.setVisible(true)
        let reused = try XCTUnwrap(other.controller.preferredFirstResponder as? iTermFileWorkspaceWebView)
        XCTAssertTrue(reused === web)
        let newOwnerReady = expectation(description: "new explorer lease ready")
        let otherGate = BrowserGate(original: other.controller, ready: { newOwnerReady.fulfill() }); reused.fileDelegate = otherGate
        wait(for: [newOwnerReady], timeout: 20)
        XCTAssertEqual(try evaluate("return document.querySelector('[data-query=names]').value;") as? String, "")
    }

    func testWorkspaceOpenCoalescesPinReusesDefaultAndExplicitSplitSharesDocument() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let policy = iTermFileOpenCoordinator(coordinator: f.coordinator)
        let context = iTermFileBrowserContext(rootDirectory: f.root.path, projectIdentifier: "project", worktreeIdentifier: "", generation: 1)
        func request(_ style: iTermOpenStyle, _ activation: iTermFileActivation) -> iTermFileOpenRequest {
            iTermFileOpenRequest(context: context, path: f.file.path, placement: style, activation: activation)
        }
        var installed = [iTermFileSessionPane](), activated = [String]()
        let install: (iTermFileSessionPane, @escaping (Bool) -> Void) -> Void = { pane, done in installed.append(pane); f.panes.append(pane); done(true) }
        let activate: (iTermFileSessionPane) -> Void = { activated.append($0.viewIdentifier) }
        f.wait { done in
            policy.open(request(.tab, .preview), candidates: [], isCurrent: { true }, install: install, activate: activate) { success in XCTAssertTrue(success); done() }
            policy.open(request(.tab, .pinned), candidates: [], isCurrent: { true }, install: install, activate: activate) { success in XCTAssertTrue(success) }
        }
        XCTAssertEqual(installed.count, 1)
        let first = try XCTUnwrap(installed.first)
        XCTAssertFalse(first.controller.status.isPreview)
        f.wait { done in policy.open(request(.tab, .preview), candidates: installed, isCurrent: { true }, install: install, activate: activate) { _ in done() } }
        XCTAssertEqual(installed.count, 1); XCTAssertEqual(activated.count, 2)
        for style in [iTermOpenStyle.verticalSplit, .horizontalSplit, .window] {
            let count = installed.count
            f.wait { done in policy.open(request(style, .pinned), candidates: installed, isCurrent: { true }, install: install, activate: activate) { _ in done() } }
            XCTAssertEqual(installed.count, count + 1)
            XCTAssertEqual(first.documentIdentifier, installed.last?.documentIdentifier)
            XCTAssertNotEqual(first.viewIdentifier, installed.last?.viewIdentifier)
        }
    }

    func testWorkspacePendingPreviewEditPinsBeforeReplacement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = f.open("preview"); first.controller.setPreview(true)
        let web = try makeVisible(first, fixture: f)
        let edited = expectation(description: "renderer edit queued")
        web.callAsyncJavaScript("monaco.editor.getEditors()[0].executeEdits('typing', [{ range: new monaco.Range(1,1,1,1), text:'pending-' }]); return true;", arguments: [:], in: nil, in: .page) { _ in edited.fulfill() }
        wait(for: [edited], timeout: 10)
        let next = f.root.appendingPathComponent("next.txt"); try "next".write(to: next, atomically: true, encoding: .utf8)
        let request = iTermFileOpenRequest(context: first.descriptor.context, path: next.path, placement: .tab, activation: .preview)
        let policy = iTermFileOpenCoordinator(coordinator: f.coordinator)
        var replacement: iTermFileSessionPane?
        f.wait { done in policy.open(request, candidates: [first], isCurrent: { true }, install: { pane, installed in replacement = pane; f.panes.append(pane); installed(true) }, activate: { _ in }) { success in XCTAssertTrue(success); done() } }
        XCTAssertNotNil(replacement); XCTAssertFalse(first.controller.status.isPreview)
        XCTAssertEqual(first.descriptor.filePath, f.file.path); XCTAssertEqual(f.snapshot(first)?.text, "pending-original")
    }

    func testWorkspaceDirectoryMoveUpdatesFailedPaneMetadataWithoutCreatingAFile() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let directory = f.root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("missing.txt")
        let context = iTermFileBrowserContext(rootDirectory: f.root.path, projectIdentifier: "project", worktreeIdentifier: "tree", generation: 1)
        var pane: iTermFileSessionPane?
        f.wait { done in f.coordinator.openFile(atPath: missing.path, context: context, viewIdentifier: "failed", preview: false) { result, error in
            XCTAssertNotNil(error); pane = result; done()
        } }
        let failed = try XCTUnwrap(pane); f.panes.append(failed)
        let backend = iTermFileBrowserService(); backend.activate(context)
        f.wait { done in backend.rename(directory.path, newName: "new", context: context) { result in
            XCTAssertNil(result.error)
            f.coordinator.applyCommittedPathMappings(result.mappings) { done() }
        } }
        XCTAssertEqual(failed.viewIdentifier, "failed")
        XCTAssertEqual(failed.descriptor.filePath, f.root.appendingPathComponent("new/missing.txt").path)
        XCTAssertNotNil(failed.controller.status.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.descriptor.filePath))
    }

    func testWorkspaceStaleOpenNeverInstallsOrFocuses() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let policy = iTermFileOpenCoordinator(coordinator: f.coordinator)
        let context = iTermFileBrowserContext(rootDirectory: f.root.path, projectIdentifier: "p", worktreeIdentifier: "w", generation: 1)
        let request = iTermFileOpenRequest(context: context, path: f.file.path, placement: .tab, activation: .preview)
        var current = true
        f.wait { done in
            policy.open(request, candidates: [], isCurrent: { current }, install: { _, _ in XCTFail("stale insertion") }, activate: { _ in XCTFail("stale focus") }) { success in
                XCTAssertFalse(success); done()
            }
            current = false
        }
        XCTAssertTrue(f.coordinator.panes.isEmpty)
    }

    func testWorkspaceDirtyCancelAndCommittedDirectoryMovePreserveSharedIdentityAndDraftPath() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = f.open("first"), second = f.open("second"); f.edit(first, "unsaved")
        f.coordinator.delegate = f; f.decision = .cancel
        f.wait { done in f.coordinator.prepareFileMutation(paths: [f.file.path], isCurrent: { true }) { allowed in XCTAssertFalse(allowed); done() } }
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "original"); XCTAssertEqual(f.snapshot(second)?.text, "unsaved")
        let moved = f.root.appendingPathComponent("moved"); try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let target = moved.appendingPathComponent("file.txt"); try FileManager.default.moveItem(at: f.file, to: target)
        f.wait { done in f.store.applyPathMappings([iTermFilePathMapping(oldPath: f.file.path, newPath: target.path, isDirectory: false)]) { done() } }
        f.wait { done in f.store.flushDrafts { error in XCTAssertNil(error); done() } }
        XCTAssertEqual(first.descriptor.filePath, target.path); XCTAssertEqual(second.descriptor.filePath, target.path)
        XCTAssertEqual(f.snapshot(first)?.text, "unsaved"); XCTAssertEqual(first.documentIdentifier, second.documentIdentifier)
        let recovery = iTermFileDocumentStore(storageDirectory: f.drafts)
        f.wait { done in recovery.recoverDrafts { values, error in XCTAssertNil(error); XCTAssertEqual(values.first?.filePath, target.path); done() } }
    }

    func testPreviewRebindPinsDirtyBufferAndRejectsStaleOrigin() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("preview"); pane.controller.setPreview(true)
        fixture.edit(pane, "unsaved")
        let next = fixture.file.deletingLastPathComponent().appendingPathComponent("next.txt")
        try "next".write(to: next, atomically: true, encoding: .utf8)
        let request = iTermFileOpenRequest(context: pane.descriptor.context, path: next.path, placement: .tab, activation: .preview)
        fixture.wait { done in
            fixture.coordinator.replacePreview(pane, request: request, isCurrent: { true }) { replaced, error in
                XCTAssertFalse(replaced); XCTAssertNil(error); done()
            }
        }
        XCTAssertFalse(pane.controller.status.isPreview)
        XCTAssertEqual(fixture.snapshot(pane)?.text, "unsaved")
        pane.controller.setPreview(true)
        fixture.wait { done in
            fixture.coordinator.replacePreview(pane, request: request, isCurrent: { false }) { replaced, _ in
                XCTAssertFalse(replaced); done()
            }
        }
        XCTAssertEqual(pane.descriptor.filePath, fixture.file.path)
    }

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

    func testNativeCloseCancellationPreservesDirtyBufferHistoryAndDraft() throws {
        for nativeAllows in [false, true] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let pane = fixture.open("close-entry"); fixture.edit(pane, "dirty")
            fixture.wait { done in fixture.store.persistDraft(documentIdentifier: pane.documentIdentifier!) { error in XCTAssertNil(error); done() } }
            fixture.coordinator.delegate = fixture; fixture.decision = .discard
            var committed = 0, askedNative = 0
            let revision = fixture.snapshot(pane)!.revision
            fixture.wait { done in fixture.coordinator.performNativeClose([pane], canClose: { true }, confirmClose: {
                askedNative += 1; return nativeAllows
            }, commit: { committed += 1 }, completion: { allowed in XCTAssertEqual(allowed, nativeAllows); done() }) }
            XCTAssertEqual(askedNative, 1); XCTAssertEqual(committed, nativeAllows ? 1 : 0)
            XCTAssertEqual(fixture.snapshot(pane)?.text, nativeAllows ? "original" : "dirty")
            XCTAssertEqual(fixture.snapshot(pane)?.revision, revision + (nativeAllows ? 1 : 0))
            if !nativeAllows {
                let recovery = iTermFileDocumentStore(storageDirectory: fixture.drafts)
                fixture.wait { done in recovery.recoverDrafts { values, error in
                    XCTAssertNil(error); XCTAssertEqual(values.first?.text, "dirty"); done()
                } }
                fixture.wait { done in fixture.store.undo(documentIdentifier: pane.documentIdentifier!) { value, error in
                    XCTAssertNil(error); XCTAssertEqual(value?.text, "original"); done()
                } }
            }
        }
    }

    func testNativeCloseLayoutRefusalDoesNotAskOrMutate() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("locked"); fixture.edit(pane, "dirty")
        fixture.coordinator.delegate = fixture; fixture.decision = .discard
        fixture.wait { done in fixture.coordinator.performNativeClose([pane], canClose: { false },
            confirmClose: { XCTFail("Locked layout asked for confirmation"); return true },
            commit: { XCTFail("Locked layout closed") }, completion: { allowed in XCTAssertFalse(allowed); done() }) }
        XCTAssertEqual(fixture.prompts, 0); XCTAssertEqual(fixture.snapshot(pane)?.text, "dirty")
    }

    func testNativeMixedRevivalMapKeepsTerminalAndReconstructsFileLeaves() throws {
        let terminal = NSObject()
        for malformed in [false, true] {
            let file: [String: Any] = ["Session GUID": "file", "File Session": malformed ? "invalid" : ["version": 1, "filePath": "/tmp/a", "rootDirectory": "/tmp", "projectIdentifier": "owner", "viewState": ["scrollTop": 17.0]]]
            let root: [String: Any] = ["View Type": "Splitter", "isVertical": true, "Subviews": [
                ["View Type": "SessionView", "Session": ["Session GUID": "terminal"]],
                ["View Type": "SessionView", "Session": file]]]
            let tab: [String: Any] = ["Root": root, "Floating Panes": [["Node": ["View Type": "SessionView", "Session": file]]]]
            for consumer in ["tab", "window"] {
                let map = try XCTUnwrap(iTermSessionRevivalMap.build(tab, sessions: ["terminal": terminal]), consumer)
                XCTAssertTrue(map["terminal"] === terminal)
                XCTAssertEqual(map.count, 1)
                XCTAssertNil(map["file"], "File leaf must be reconstructed by the existing fail-closed native file restore branch")
                XCTAssertEqual((tab["Root"] as? NSDictionary), root as NSDictionary)
            }
        }
        let missingTerminal: [String: Any] = ["Root": ["View Type": "SessionView", "Session": ["Session GUID": "unavailable"]]]
        XCTAssertNil(iTermSessionRevivalMap.build(missingTerminal, sessions: [:]))
    }

    func testHistoryMutationReservesAdmissionThroughWriterAcknowledgment() throws {
        for redo in [false, true] {
            for ending in ["success", "error", "retired"] {
                let fixture = try Fixture(); defer { fixture.cleanup() }
                let writer = fixture.open("writer"), target = fixture.open("history")
                fixture.edit(writer, "after")
                if redo { fixture.wait { done in fixture.store.undo(documentIdentifier: writer.documentIdentifier!) { _, error in XCTAssertNil(error); done() } } }
                let before = fixture.snapshot(writer)!
                let web = try makeVisible(writer, fixture: fixture)
                let gate = FlushGate(original: web.fileDelegate!); web.fileDelegate = gate
                defer { web.fileDelegate = gate.original }
                let held = expectation(description: "history writer flush held"); gate.onHeld = { held.fulfill() }
                let finished = expectation(description: "history mutation finished")
                fixture.coordinator.undo(target, redo: redo) { error in
                    if ending == "success" { XCTAssertNil(error) } else { XCTAssertNotNil(error) }
                    finished.fulfill()
                }
                wait(for: [held], timeout: 8)
                fixture.wait { done in fixture.coordinator.beginOperation { error in XCTAssertNotNil(error); done() } }
                fixture.wait { done in fixture.coordinator.prepareClose([writer, target], quitting: false) { allowed in XCTAssertFalse(allowed); done() } }
                fixture.wait { done in fixture.coordinator.rebind(target, descriptor: target.descriptor, context: target.descriptor.context) { error in XCTAssertNotNil(error); done() } }
                if ending == "retired" { fixture.coordinator.abandon(target) }
                gate.release(failed: ending == "error")
                wait(for: [finished], timeout: 8)
                let after = fixture.snapshot(writer)!
                XCTAssertEqual(after.text, ending == "success" ? (redo ? "after" : "original") : before.text)
                XCTAssertEqual(after.revision, before.revision + (ending == "success" ? 1 : 0))
                fixture.wait { done in fixture.coordinator.beginOperation { error in XCTAssertNil(error); done() } }
                fixture.wait { done in fixture.coordinator.finishOperation { error in XCTAssertNil(error); done() } }
            }
        }
    }

    func testStaleCloseDurabilityErrorDoesNotCancelNewOperation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let live = fixture.open("live"), closing = fixture.open("closing-copy")
        _ = try makeVisible(live, fixture: fixture)
        fixture.edit(live, "durable dirty")
        fixture.wait { done in fixture.store.persistDraft(documentIdentifier: live.documentIdentifier!) { error in XCTAssertNil(error); done() } }
        let blockedFile = fixture.root.appendingPathComponent("blocked.txt")
        try Data("block".utf8).write(to: blockedFile)
        let entered = expectation(description: "owned coordinator lock")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: blockedFile, options: .forReplacing, error: &error) { _ in
                entered.fulfill(); _ = release.wait(timeout: .now() + 15)
            }
        }
        wait(for: [entered], timeout: 5)
        let queued = expectation(description: "final durability queued")
        let oldDone = expectation(description: "old close retired")
        fixture.coordinator.performNativeClose([closing], canClose: { true }, confirmClose: {
            fixture.store.openFile(atPath: blockedFile.path) { _, _ in }
            DispatchQueue.main.async { queued.fulfill() }
            return true
        }, commit: { XCTFail("Canceled close committed") }, completion: { allowed in XCTAssertFalse(allowed); oldDone.fulfill() })
        wait(for: [queued], timeout: 5)
        fixture.coordinator.cancelOperation()
        fixture.wait { done in fixture.coordinator.beginOperation { error in XCTAssertNil(error); done() } }
        let backup = fixture.root.appendingPathComponent("old-drafts")
        try FileManager.default.moveItem(at: fixture.drafts, to: backup)
        try Data("not a directory".utf8).write(to: fixture.drafts)
        release.signal()
        wait(for: [oldDone], timeout: 10)
        XCTAssertTrue(fixture.coordinator.operationInProgress)
        XCTAssertFalse(live.controller.canPerform(.paste))
        try FileManager.default.removeItem(at: fixture.drafts)
        try FileManager.default.moveItem(at: backup, to: fixture.drafts)
        fixture.wait { done in fixture.coordinator.finishOperation { error in XCTAssertNil(error); done() } }
        XCTAssertTrue(live.controller.canPerform(.paste))
    }

    private func makeVisible(_ pane: iTermFileSessionPane, fixture: Fixture) throws -> iTermFileWorkspaceWebView {
        pane.delegate = fixture
        let ready = expectation(description: "editor ready")
        fixture.changed = { value in if value === pane && value.controller.status.isReady { fixture.changed = nil; ready.fulfill() } }
        pane.controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        pane.controller.setVisible(true); pane.controller.focusEditor(); wait(for: [ready], timeout: 20)
        var failure: NSError?
        fixture.wait { done in pane.controller.flushEdits(reason: .save) { error in failure = error; done() } }
        if let failure { throw failure }
        return try XCTUnwrap(pane.controller.view.subviews.compactMap { $0 as? iTermFileWorkspaceWebView }.first)
    }

    private final class FlushGate: FileUIWebViewDelegate {
        let original: FileUIWebViewDelegate
        var onHeld: (() -> Void)?
        private var pending: ((Bool) -> Void)?
        private var captured = false
        init(original: FileUIWebViewDelegate) { self.original = original }
        func release(failed: Bool) { let action = pending; pending = nil; action?(failed) }
        func fileUIWebViewReady(_ web: iTermFileWorkspaceWebView) { original.fileUIWebViewReady(web) }
        func fileUIWebView(_ web: iTermFileWorkspaceWebView, failed error: NSError) { original.fileUIWebView(web, failed: error) }
        func fileUIWebView(_ web: iTermFileWorkspaceWebView, received type: String, payload: [String: Any], identifier: String) {
            if type == "flushResult" && !captured {
                captured = true
                pending = { failed in
                    var value = payload; if failed { value["error"] = 3 }
                    self.original.fileUIWebView(web, received: type, payload: value, identifier: identifier)
                }
                onHeld?()
            } else { original.fileUIWebView(web, received: type, payload: payload, identifier: identifier) }
        }
    }

    func testActualMainMenuRoutesSaveUndoRedoAndPreservesOtherResponders() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("menu"), copy = fixture.open("copy")
        // Make the next lease synchronous while its JS page is still unbootstrapped.
        let owner = NSObject()
        var lease: FileUIAcquisition?
        fixture.wait { done in lease = fixture.runtime.acquire(owner: owner) { renderer, error in
            XCTAssertNil(error)
            if let renderer { fixture.runtime.release(renderer) }
            done()
        } }
        withExtendedLifetime((owner, lease)) {}
        let web = try makeVisible(pane, fixture: fixture)
        let originalHost = NSView(); originalHost.addSubview(pane.controller.view)
        let actions = iTermFileMenuActions(pane: pane)
        iTermFileMenuActions.register(actions, rootView: pane.controller.view)
        var saveAsRequests = 0; actions.requestSaveAs = { saveAsRequests += 1 }
        let save = try nativeMenuItem("692"), undo = try nativeMenuItem("1061"), redo = try nativeMenuItem("1063")
        XCTAssertEqual(save.keyEquivalent, "s")
        fixture.edit(pane, "menu edit")
        XCTAssertTrue(pane.controller.status.isReady, "native file ready")
        XCTAssertFalse(pane.controller.status.isReadOnly, "native file editable")
        XCTAssertFalse(pane.controller.status.isComposing, "no composition")
        XCTAssertNil(pane.controller.status.error)
        XCTAssertFalse(fixture.coordinator.operationInProgress)
        for item in [save, undo, redo] { XCTAssertEqual(iTermFileMenuActions.validate(item, firstResponder: web)?.boolValue, true) }
        let saved = expectation(description: "native menu save")
        XCTAssertEqual(iTermFileMenuActions.perform(save, firstResponder: web) { command, error in XCTAssertNil(error); XCTAssertEqual(command, .save); saved.fulfill() }?.boolValue, true)
        wait(for: [saved], timeout: 8)
        XCTAssertEqual(saveAsRequests, 0)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), "menu edit")
        for (item, command, text) in [(undo, iTermFileViewCommand.undo, "original"), (redo, .redo, "menu edit")] {
            let done = expectation(description: "native menu history")
            XCTAssertEqual(iTermFileMenuActions.perform(item, firstResponder: web) { actual, error in XCTAssertNil(error); XCTAssertEqual(actual, command); done.fulfill() }?.boolValue, true)
            wait(for: [done], timeout: 8); XCTAssertEqual(fixture.snapshot(copy)?.text, text)
        }
        let saveAs = try nativeMenuItem("FileSaveAsNative")
        XCTAssertEqual(iTermFileMenuActions.perform(saveAs, firstResponder: web)?.boolValue, true)
        XCTAssertEqual(saveAsRequests, 1)
        fixture.wait { done in fixture.coordinator.beginOperation { error in XCTAssertNil(error); done() } }
        for item in [save, undo, redo, saveAs] {
            XCTAssertEqual(iTermFileMenuActions.validate(item, firstResponder: web)?.boolValue, false)
            XCTAssertEqual(iTermFileMenuActions.perform(item, firstResponder: web)?.boolValue, false)
        }
        fixture.coordinator.cancelOperation()
        let ordinary = NSTextView(); ordinary.isEditable = true
        let field = NSTextField(); field.isEditable = true
        for responder: NSResponder in [ordinary, field, NSView()] {
            XCTAssertNil(iTermFileMenuActions.validate(save, firstResponder: responder))
            XCTAssertNil(iTermFileMenuActions.perform(undo, firstResponder: responder))
        }
        let newHost = NSView(); newHost.addSubview(pane.controller.view)
        XCTAssertEqual(iTermFileMenuActions.validate(undo, firstResponder: web)?.boolValue, true)
        pane.controller.view.addSubview(ordinary)
        XCTAssertNil(iTermFileMenuActions.perform(undo, firstResponder: ordinary))
        web.fileDelegate?.fileUIWebView(web, received: "status", payload: ["isComposing": true], identifier: "composition")
        for item in [save, undo, redo, saveAs] {
            XCTAssertEqual(iTermFileMenuActions.validate(item, firstResponder: web)?.boolValue, false)
            XCTAssertEqual(iTermFileMenuActions.perform(item, firstResponder: web)?.boolValue, false)
        }
        web.fileDelegate?.fileUIWebView(web, received: "status", payload: ["isComposing": false], identifier: "composition")
    }

    func testNativePreviewMenuResolvesDocumentHistory() throws {
        let fixture = try Fixture(fileName: "preview.md"); defer { fixture.cleanup() }
        let pane = fixture.open("preview"), copy = fixture.open("copy")
        fixture.edit(pane, "changed markdown")
        pane.controller.restoreViewState(iTermFileViewState(dictionary: ["showsMarkdownPreview": true]))
        pane.controller.setVisible(true)
        let actions = iTermFileMenuActions(pane: pane)
        iTermFileMenuActions.register(actions, rootView: pane.controller.view)
        let preview = pane.controller.preferredFirstResponder
        let undo = try nativeMenuItem("1061")
        XCTAssertEqual(iTermFileMenuActions.validate(undo, firstResponder: preview)?.boolValue, true)
        let done = expectation(description: "preview native undo")
        XCTAssertEqual(iTermFileMenuActions.perform(undo, firstResponder: preview) { command, error in
            XCTAssertEqual(command, .undo); XCTAssertNil(error); done.fulfill()
        }?.boolValue, true)
        wait(for: [done], timeout: 8)
        XCTAssertEqual(fixture.snapshot(copy)?.text, "original")
    }

    func testWarmLoadingPaneDemotionCancelsDeferredFocus() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pane = fixture.open("demoted")
        let owner = NSObject(); var lease: FileUIAcquisition?
        fixture.wait { done in lease = fixture.runtime.acquire(owner: owner) { renderer, error in
            XCTAssertNil(error); if let renderer { fixture.runtime.release(renderer) }; done()
        } }
        withExtendedLifetime((owner, lease)) {}
        pane.delegate = fixture
        let ready = expectation(description: "demoted page ready")
        fixture.changed = { value in if value === pane && value.controller.status.isReady { fixture.changed = nil; ready.fulfill() } }
        pane.controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        pane.controller.setVisible(true)
        pane.controller.focusEditor()
        pane.controller.cancelPendingFocus()
        pane.controller.restoreViewState(iTermFileViewState(dictionary: ["selectionStartLine": 1, "selectionStartColumn": 3]))
        pane.controller.setPreview(true)
        pane.controller.reveal(lineNumber: 1, utf16Column: 3)
        pane.controller.resumeEditing()
        wait(for: [ready], timeout: 15)
        fixture.wait { done in pane.controller.flushEdits(reason: .save) { error in XCTAssertNil(error); done() } }
        XCTAssertNil(pane.controller.status.error)
        XCTAssertFalse(fixture.runtime.hasAuthority(pane.controller))
        XCTAssertTrue(pane.controller.status.isPreview)
        let web = try XCTUnwrap(pane.controller.view.subviews.compactMap { $0 as? iTermFileWorkspaceWebView }.first)
        let untouched = expectation(description: "no late editor focus")
        web.callAsyncJavaScript("const e = monaco.editor.getEditors()[0]; return { readOnly: e.getOption(monaco.editor.EditorOption.readOnly), column: e.getPosition().column };", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result, let state = value as? [String: Any] {
                XCTAssertEqual(state["readOnly"] as? Bool, true); XCTAssertEqual(state["column"] as? Int, 3)
            } else { XCTFail("Deferred editor state was not restored") }
            untouched.fulfill()
        }
        wait(for: [untouched], timeout: 5)
        pane.controller.focusEditor()
        let focused = expectation(description: "explicit later focus")
        web.callAsyncJavaScript("return new Promise(resolve => { const e = monaco.editor.getEditors()[0], k = monaco.editor.EditorOption.readOnly; if (!e.getOption(k)) { resolve(true); return; } const s = e.onDidChangeConfiguration(() => { if (!e.getOption(k)) { s.dispose(); resolve(true); } }); })", arguments: [:], in: nil, in: .page) { result in
            XCTAssertEqual(try? result.get() as? Bool, true); focused.fulfill()
        }
        wait(for: [focused], timeout: 5)
    }

    private func nativeMenuItem(_ identifier: String) throws -> NSMenuItem {
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["FILE_SESSION_MAIN_MENU"].map { URL(fileURLWithPath: $0) })
        let xml = try XMLDocument(contentsOf: url)
        let node = try XCTUnwrap(xml.nodes(forXPath: "//menuItem[@id='\(identifier)']").first as? XMLElement)
        let connection = try XCTUnwrap(node.nodes(forXPath: "connections/action").first as? XMLElement)
        let targetID = try XCTUnwrap(connection.attribute(forName: "target")?.stringValue)
        let target = try XCTUnwrap(xml.nodes(forXPath: "//*[@id='\(targetID)']").first as? XMLElement)
        XCTAssertEqual(target.attribute(forName: "customClass")?.stringValue, "iTermApplicationDelegate")
        let item = NSMenuItem(title: node.attribute(forName: "title")?.stringValue ?? "", action: NSSelectorFromString(try XCTUnwrap(connection.attribute(forName: "selector")?.stringValue)), keyEquivalent: node.attribute(forName: "keyEquivalent")?.stringValue ?? "")
        return item
    }

    private final class BrowserGate: FileUIWebViewDelegate {
        let original: FileUIWebViewDelegate
        var ready: (() -> Void)?
        init(original: FileUIWebViewDelegate, ready: @escaping () -> Void) { self.original = original; self.ready = ready }
        func fileUIWebViewReady(_ web: iTermFileWorkspaceWebView) { original.fileUIWebViewReady(web); let callback = ready; ready = nil; callback?() }
        func fileUIWebView(_ web: iTermFileWorkspaceWebView, received type: String, payload: [String: Any], identifier: String) { original.fileUIWebView(web, received: type, payload: payload, identifier: identifier) }
        func fileUIWebView(_ web: iTermFileWorkspaceWebView, failed error: NSError) { XCTFail("Explorer renderer failed: \(error)"); original.fileUIWebView(web, failed: error) }
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

        init(testing: Bool = true, fileName: String = "file.txt") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent(fileName); drafts = root.appendingPathComponent("drafts")
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
