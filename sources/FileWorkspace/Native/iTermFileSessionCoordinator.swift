import AppKit

@objc enum iTermFileCloseDecision: Int { case save, discard, keepDrafts, cancel }

@objc protocol iTermFileSessionCoordinatorDelegate: AnyObject {
    func fileSessionCoordinator(_ coordinator: iTermFileSessionCoordinator, decideFor documents: [iTermFileDocumentSnapshot],
                                quitting: Bool, completion: @escaping (iTermFileCloseDecision) -> Void)
    func fileSessionCoordinator(_ coordinator: iTermFileSessionCoordinator, didFail error: NSError)
}

@objc protocol iTermFileSessionPaneDelegate: AnyObject {
    func fileSessionPaneDidChange(_ pane: iTermFileSessionPane)
    func fileSessionPaneDidReceiveFocus(_ pane: iTermFileSessionPane)
    func fileSessionPane(_ pane: iTermFileSessionPane, request command: iTermFileViewCommand)
}

@objcMembers final class iTermFileSessionPane: NSObject, iTermFileViewControllerDelegate {
    static let didChangeNotification = "iTermFileSessionPaneDidChange"
    let viewIdentifier: String
    let controller: iTermFileViewController
    weak var delegate: iTermFileSessionPaneDelegate?
    weak var coordinator: iTermFileSessionCoordinator?
    private var original: iTermFileSessionDescriptor
    private(set) var closed = false
    fileprivate var kind = 0
    var documentIdentifier: String? { controller.documentIdentifier ?? original.documentIdentifier }
    var descriptor: iTermFileSessionDescriptor {
        iTermFileSessionDescriptor(filePath: controller.status.filePath ?? original.filePath,
            documentIdentifier: documentIdentifier, rootDirectory: original.rootDirectory,
            projectIdentifier: original.projectIdentifier, worktreeIdentifier: original.worktreeIdentifier,
            preview: controller.status.isPreview, viewState: controller.cachedViewState, kind: kind)
    }
    var title: String {
        let name = controller.status.title.isEmpty ? (original.filePath as NSString).lastPathComponent : controller.status.title
        return name + (controller.status.isDirty ? " •" : "") + (controller.status.isPreview ? " ◇" : "")
    }
    init(descriptor: iTermFileSessionDescriptor, viewIdentifier: String, runtime: iTermFileWorkspaceUIRuntime) {
        self.original = descriptor; self.viewIdentifier = viewIdentifier; self.kind = descriptor.kind
        controller = iTermFileViewController(runtime: runtime, viewIdentifier: viewIdentifier)
        super.init()
        controller.delegate = self; controller.applyContext(descriptor.context)
        controller.restoreViewState(descriptor.viewState); controller.setPreview(descriptor.preview)
    }
    fileprivate func rebind(descriptor: iTermFileSessionDescriptor, context: iTermFileBrowserContext,
                            snapshot: iTermFileDocumentSnapshot?, error: NSError?) {
        original = descriptor
        controller.applyContext(context)
        if let snapshot { kind = snapshot.kind.rawValue; controller.applyDocumentChanges(snapshot, edits: nil) }
        else { controller.showOpenFailure(path: descriptor.filePath, documentIdentifier: descriptor.documentIdentifier,
                                         error: error ?? iTermFileSessionCoordinator.error(2)) }
        controller.restoreViewState(descriptor.viewState); controller.setPreview(descriptor.preview)
        notifyChange()
    }
    fileprivate func applyCommittedMappings(_ mappings: [iTermFilePathMapping]) {
        for mapping in mappings {
            guard let old = mapping.oldPath, let new = mapping.newPath else { continue }
            let path = descriptor.filePath
            guard path == old || (mapping.isDirectory && path.hasPrefix(old + "/")) else { continue }
            // Live documents were already updated by the store notification. This covers metadata-only
            // failed/restored panes, which still need their saved path and title to follow directory moves.
            let updated = iTermFileSessionDescriptor(filePath: new + path.dropFirst(old.count), documentIdentifier: documentIdentifier,
                rootDirectory: original.rootDirectory, projectIdentifier: original.projectIdentifier,
                worktreeIdentifier: original.worktreeIdentifier, preview: controller.status.isPreview,
                viewState: controller.cachedViewState, kind: kind)
            rebind(descriptor: updated, context: updated.context, snapshot: nil, error: controller.status.error)
        }
    }
    private func notifyChange() {
        delegate?.fileSessionPaneDidChange(self)
        NotificationCenter.default.post(name: NSNotification.Name(Self.didChangeNotification), object: self)
    }
    func pin() { controller.setPreview(false); notifyChange() }
    func shutdown() { guard !closed else { return }; closed = true; controller.shutdown(); delegate = nil }
    func fileViewDidReceiveFocus(_ controller: iTermFileViewController) { delegate?.fileSessionPaneDidReceiveFocus(self) }
    func fileView(_ controller: iTermFileViewController, didChangeStatus status: iTermFileViewStatus) {
        if status.isDirty && status.isPreview { controller.setPreview(false) }
        notifyChange()
    }
    func fileView(_ controller: iTermFileViewController, didChangeViewState state: iTermFileViewState) { notifyChange() }
    func fileViewDidRequestPin(_ controller: iTermFileViewController) { pin() }
    func fileView(_ controller: iTermFileViewController, didRequest command: iTermFileViewCommand) { delegate?.fileSessionPane(self, request: command) }
}

/// Injected by the active preference-suite service. All entry points and completions are on main.
@objcMembers final class iTermFileSessionCoordinator: NSObject {
    static var installed: iTermFileSessionCoordinator?
    let documentStore: iTermFileDocumentStore
    let runtime: iTermFileWorkspaceUIRuntime
    weak var delegate: iTermFileSessionCoordinatorDelegate?
    private let registry = NSHashTable<iTermFileSessionPane>.weakObjects()
    private var recovering = false, recovered = false
    private var recoveryWaiters = [() -> Void]()
    private var pendingOpens = 0
    private var reservedViewIdentifiers = Set<String>()
    private var pendingMutations = 0
    private var operation = false
    private var operationGeneration: UInt64 = 0
    private var approved = Set<String>()
    private var releasePending = Set<String>()
    private var cleanup = Set<String>()
    var panes: [iTermFileSessionPane] { registry.allObjects.filter { !$0.closed } }
    var operationInProgress: Bool { operation }
    var hasResources: Bool { !panes.isEmpty || pendingOpens > 0 || pendingMutations > 0 || !releasePending.isEmpty }

    init(documentStore: iTermFileDocumentStore, runtime: iTermFileWorkspaceUIRuntime) {
        self.documentStore = documentStore; self.runtime = runtime; super.init()
    }
    func openFile(atPath path: String, context: iTermFileBrowserContext, viewIdentifier: String, preview: Bool,
                  completion: @escaping (iTermFileSessionPane?, NSError?) -> Void) {
        let descriptor = iTermFileSessionDescriptor(filePath: path, documentIdentifier: nil,
            rootDirectory: context.rootDirectory, projectIdentifier: context.projectIdentifier,
            worktreeIdentifier: context.worktreeIdentifier, preview: preview, viewState: iTermFileViewState())
        restore(descriptor, viewIdentifier: viewIdentifier, context: context, completion: completion)
    }
    func restore(_ descriptor: iTermFileSessionDescriptor, viewIdentifier: String, context: iTermFileBrowserContext?,
                 completion: @escaping (iTermFileSessionPane?, NSError?) -> Void) {
        guard !operation, releasePending.isEmpty, !reservedViewIdentifiers.contains(viewIdentifier), !panes.contains(where: { $0.viewIdentifier == viewIdentifier }) else {
            completion(nil, Self.error(1)); return
        }
        reservedViewIdentifiers.insert(viewIdentifier)
        pendingOpens += 1
        afterRecovery { [self] in
            let finish: (iTermFileDocumentSnapshot?, NSError?) -> Void = { [self] snapshot, error in
                pendingOpens -= 1; reservedViewIdentifiers.remove(viewIdentifier)
                let pane = iTermFileSessionPane(descriptor: descriptor, viewIdentifier: viewIdentifier, runtime: runtime)
                pane.coordinator = self
                if let context { pane.controller.applyContext(context) }
                if let snapshot { pane.kind = snapshot.kind.rawValue; pane.controller.applyDocumentChanges(snapshot, edits: nil) }
                else { pane.controller.showOpenFailure(path: descriptor.filePath, documentIdentifier: descriptor.documentIdentifier, error: error ?? Self.error(2)) }
                registry.add(pane); completion(pane, error)
                performCleanup()
            }
            if let identifier = descriptor.documentIdentifier {
                documentStore.snapshot(documentIdentifier: identifier) { [self] snapshot in
                    if let snapshot { finish(snapshot, nil) }
                    else { documentStore.openFile(atPath: descriptor.filePath, completion: finish) }
                }
            } else { documentStore.openFile(atPath: descriptor.filePath, completion: finish) }
        }
    }
    private func afterRecovery(_ action: @escaping () -> Void) {
        if recovered { action(); return }
        recoveryWaiters.append(action)
        guard !recovering else { return }; recovering = true
        documentStore.recoverDrafts { [self] _, error in
            recovered = true; recovering = false
            if let error { delegate?.fileSessionCoordinator(self, didFail: error) }
            let callbacks = recoveryWaiters; recoveryWaiters.removeAll(); callbacks.forEach { $0() }
        }
    }
    func save(_ pane: iTermFileSessionPane, toPath: String?, overwrite: Bool,
              completion: @escaping (iTermFileSaveOutcome, NSError?) -> Void) {
        guard !operation, !pane.closed, let identifier = pane.documentIdentifier else { completion(.missing, Self.error(2)); return }
        pendingMutations += 1
        let generation = operationGeneration
        let finished: (iTermFileSaveOutcome, NSError?) -> Void = { [self] outcome, error in
            pendingMutations -= 1; performCleanup(); completion(outcome, error)
        }
        // Drain every controller, including a different pane that still owns write authority.
        runtime.flushAllEdits(reason: .save) { [self] error in
            guard error == nil else { finished(.failed, error); return }
            guard !pane.closed, pane.coordinator === self, pane.documentIdentifier == identifier,
                  generation == operationGeneration, !operation else { finished(.stale, Self.error(1)); return }
            if let toPath { documentStore.saveAs(documentIdentifier: identifier, toPath: toPath, overwrite: overwrite, completion: finished) }
            else { documentStore.save(documentIdentifier: identifier, overwrite: overwrite, completion: finished) }
        }
    }
    func undo(_ pane: iTermFileSessionPane, redo: Bool, completion: @escaping (NSError?) -> Void) {
        guard !operation, !pane.closed, pane.coordinator === self, let id = pane.documentIdentifier else { completion(Self.error(1)); return }
        pendingMutations += 1
        let generation = operationGeneration
        let finish: (NSError?) -> Void = { [self] error in
            pendingMutations -= 1; performCleanup(); completion(error)
        }
        runtime.flushAllEdits(reason: .save) { [self] error in
            guard error == nil else { finish(error); return }
            guard !operation, generation == operationGeneration, !pane.closed,
                  pane.coordinator === self, pane.documentIdentifier == id else { finish(Self.error(1)); return }
            let done: (iTermFileDocumentSnapshot?, NSError?) -> Void = { _, error in finish(error) }
            if redo { documentStore.redo(documentIdentifier: id, completion: done) }
            else { documentStore.undo(documentIdentifier: id, completion: done) }
        }
    }
    func rebind(_ pane: iTermFileSessionPane, descriptor: iTermFileSessionDescriptor,
                context: iTermFileBrowserContext, completion: @escaping (NSError?) -> Void) {
        guard !pane.closed, pane.coordinator === self else { completion(Self.error(1)); return }
        prepareClose([pane], quitting: false) { [self] allowed in
            guard allowed else { completion(Self.error(1)); return }
            let generation = operationGeneration
            let oldIdentifier = pane.documentIdentifier
            documentStore.openFile(atPath: descriptor.filePath) { [self] snapshot, error in
                guard operation, operationGeneration == generation, !pane.closed else {
                    if let id = snapshot?.documentIdentifier { cleanup.insert(id); performCleanup() }
                    completion(Self.error(1)); return
                }
                pane.rebind(descriptor: descriptor, context: context, snapshot: snapshot, error: error)
                if let oldIdentifier, oldIdentifier != pane.documentIdentifier { cleanup.insert(oldIdentifier) }
                completeClose(quitting: false)
                completion(error)
            }
        }
    }
    /// Preview replacement drains the actual writer before deciding whether this slot is reusable.
    func replacePreview(_ pane: iTermFileSessionPane, request: iTermFileOpenRequest,
                        isCurrent: @escaping () -> Bool, completion: @escaping (Bool, NSError?) -> Void) {
        guard isCurrent(), !pane.closed, pane.controller.status.isPreview else { completion(false, nil); return }
        beginOperation { [self] error in
            guard error == nil else { completion(false, error); return }
            guard isCurrent(), !pane.closed else { cancelOperation(); completion(false, Self.error(1)); return }
            if pane.controller.status.isDirty || !pane.controller.status.isPreview {
                pane.pin(); cancelOperation(); completion(false, nil); return
            }
            let generation = operationGeneration
            let old = pane.documentIdentifier
            documentStore.openFile(atPath: request.path) { [self] snapshot, error in
                guard operation, generation == operationGeneration else { completion(false, Self.error(1)); return }
                guard isCurrent(), !pane.closed else {
                    if let id = snapshot?.documentIdentifier { cleanup.insert(id) }
                    cancelOperation(); completion(false, Self.error(1)); return
                }
                let descriptor = iTermFileSessionDescriptor(filePath: request.path, documentIdentifier: snapshot?.documentIdentifier,
                    rootDirectory: request.context.rootDirectory, projectIdentifier: request.context.projectIdentifier,
                    worktreeIdentifier: request.context.worktreeIdentifier, preview: request.activation == .preview, viewState: iTermFileViewState())
                pane.rebind(descriptor: descriptor, context: request.context, snapshot: snapshot, error: error)
                if let old, old != pane.documentIdentifier { cleanup.insert(old) }
                cancelOperation(); completion(true, error)
            }
        }
    }
    func applyCommittedPathMappings(_ mappings: [iTermFilePathMapping], completion: @escaping () -> Void) {
        documentStore.applyPathMappings(mappings) { [self] in
            documentStore.allSnapshots { [self] snapshots in
                let live = Set(snapshots.map(\.documentIdentifier))
                for pane in panes where pane.documentIdentifier.map({ !live.contains($0) }) ?? true {
                    pane.applyCommittedMappings(mappings)
                }
                completion()
            }
        }
    }
    /// Filesystem transactions include every affected document, even when another pane also owns it.
    func prepareFileMutation(paths: [String], isCurrent: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        beginOperation { [self] error in
            guard error == nil else { completion(false); return }
            let generation = operationGeneration
            documentStore.allSnapshots { [self] values in
                guard operation, generation == operationGeneration else { completion(false); return }
                let dirty = values.filter { value in value.isDirty && paths.contains { value.filePath == $0 || value.filePath.hasPrefix($0 + "/") } }
                let decide: (iTermFileCloseDecision) -> Void = { [self] decision in
                    guard operation, generation == operationGeneration else { completion(false); return }
                    guard isCurrent(), decision == .save || decision == .discard else { cancelOperation(); completion(false); return }
                    persist(dirty, decision: decision, generation: generation) { [self] error in
                        guard operation, generation == operationGeneration else { completion(false); return }
                        guard error == nil else { fail(error!, completion: completion); return }
                        completion(true)
                    }
                }
                if dirty.isEmpty { decide(.save) }
                else if let delegate { delegate.fileSessionCoordinator(self, decideFor: dirty, quitting: false, completion: decide) }
                else { decide(.cancel) }
            }
        }
    }
    func beginOperation(completion: @escaping (NSError?) -> Void) {
        guard !operation, pendingOpens == 0, pendingMutations == 0, releasePending.isEmpty else { completion(Self.error(1)); return }
        operation = true; operationGeneration &+= 1
        let generation = operationGeneration
        runtime.flushAllEdits(reason: .suspend) { [self] error in
            guard operation, generation == operationGeneration else { completion(Self.error(1)); return }
            if error != nil { cancelOperation() }; completion(error)
        }
    }
    func finishOperation(completion: @escaping (NSError?) -> Void) {
        guard operation else { completion(Self.error(1)); return }
        let generation = operationGeneration
        documentStore.flushDrafts { [self] error in
            guard operation, operationGeneration == generation else { completion(Self.error(1)); return }
            cancelOperation(); completion(error)
        }
    }
    func cancelOperation() { operationGeneration &+= 1; approved.removeAll(); operation = false; runtime.resumeEditing(); performCleanup() }
    /// Real native close entry: native cancellation is resolved before file effects, never afterward.
    func performNativeClose(_ closing: [iTermFileSessionPane], canClose: @escaping () -> Bool,
                            confirmClose: @escaping () -> Bool, commit: @escaping () -> Void,
                            completion: @escaping (Bool) -> Void) {
        guard canClose() else { completion(false); return }
        prepareClose(closing, quitting: false, nativeConfirmation: { canClose() && confirmClose() && canClose() }) { [self] allowed in
            guard allowed else { completion(false); return }
            commit()
            completeClose(quitting: false)
            completion(true)
        }
    }
    func prepareClose(_ closing: [iTermFileSessionPane], quitting: Bool, completion: @escaping (Bool) -> Void) {
        prepareClose(closing, quitting: quitting, nativeConfirmation: { true }, completion: completion)
    }
    func prepareClose(_ closing: [iTermFileSessionPane], quitting: Bool, nativeConfirmation: @escaping () -> Bool,
                      completion: @escaping (Bool) -> Void) {
        guard !operation, pendingOpens == 0, pendingMutations == 0, releasePending.isEmpty else { completion(false); return }
        operation = true; operationGeneration &+= 1
        let generation = operationGeneration
        let closingIDs = Set(closing.map(\.viewIdentifier))
        runtime.flushAllEdits(reason: quitting ? .quit : .close) { [self] error in
            guard operation, generation == operationGeneration else { completion(false); return }
            guard error == nil else { fail(error!, completion: completion); return }
            let remaining = panes.filter { !closingIDs.contains($0.viewIdentifier) }
            let survivingDocuments = Set(remaining.compactMap(\.documentIdentifier))
            let ids = Set(closing.compactMap(\.documentIdentifier)).subtracting(quitting ? [] : survivingDocuments)
            snapshots(Array(ids)) { [self] snapshots in
                guard operation, generation == operationGeneration else { completion(false); return }
                let dirty = snapshots.filter(\.isDirty)
                let decide: (iTermFileCloseDecision) -> Void = { [self] decision in
                    guard operation, generation == operationGeneration else { completion(false); return }
                    guard decision != .cancel, quitting || decision != .keepDrafts else { cancelOperation(); completion(false); return }
                    guard nativeConfirmation(), operation, generation == operationGeneration else {
                        if operation && generation == operationGeneration { cancelOperation() }
                        completion(false); return
                    }
                    persist(dirty, decision: decision, generation: generation) { [self] error in
                        guard operation, generation == operationGeneration else { completion(false); return }
                        guard error == nil else { fail(error!, completion: completion); return }
                        documentStore.flushDrafts { [self] error in
                            guard operation, generation == operationGeneration else { completion(false); return }
                            guard error == nil else { fail(error!, completion: completion); return }
                            approved = closingIDs; completion(true)
                        }
                    }
                }
                if dirty.isEmpty { decide(.save) }
                else if let delegate { delegate.fileSessionCoordinator(self, decideFor: dirty, quitting: quitting, completion: decide) }
                else { decide(.cancel) }
            }
        }
    }
    func isCloseApproved(_ pane: iTermFileSessionPane) -> Bool { approved.contains(pane.viewIdentifier) }
    /// Retire a prepared pane that was never installed. This does not own another operation's gate.
    func abandon(_ pane: iTermFileSessionPane) {
        didClose(pane, quitting: false)
    }
    func didClose(_ pane: iTermFileSessionPane, quitting: Bool) {
        let identifier = pane.documentIdentifier
        pane.shutdown(); registry.remove(pane); approved.remove(pane.viewIdentifier)
        NotificationCenter.default.post(name: NSNotification.Name(iTermFileSessionPane.didChangeNotification), object: pane)
        if !quitting, let identifier { cleanup.insert(identifier) }
        // A batch remains gated until the native host explicitly finishes its commit.
        // Failed, never-installed admissions need cleanup without canceling another gate.
        performCleanup()
    }
    func completeClose(quitting: Bool) {
        approved.removeAll(); operation = false
        if quitting { runtime.shutdown() } else { runtime.resumeEditing(); performCleanup() }
    }
    private func performCleanup() {
        guard !operation, pendingOpens == 0, pendingMutations == 0 else { return }
        let live = Set(panes.compactMap(\.documentIdentifier))
        for id in cleanup.subtracting(live).subtracting(releasePending) {
            cleanup.remove(id); releasePending.insert(id)
            documentStore.releaseDocument(documentIdentifier: id) { [weak self] error in
                guard let self else { return }; self.releasePending.remove(id)
                if let error { self.cleanup.insert(id); self.delegate?.fileSessionCoordinator(self, didFail: error) }
            }
        }
    }
    private func snapshots(_ identifiers: [String], completion: @escaping ([iTermFileDocumentSnapshot]) -> Void) {
        guard let first = identifiers.first else { completion([]); return }
        documentStore.snapshot(documentIdentifier: first) { [self] snapshot in
            snapshots(Array(identifiers.dropFirst())) { rest in completion(snapshot.map { [$0] + rest } ?? rest) }
        }
    }
    private func persist(_ documents: [iTermFileDocumentSnapshot], decision: iTermFileCloseDecision, generation: UInt64, completion: @escaping (NSError?) -> Void) {
        guard operation, generation == operationGeneration else { completion(Self.error(1)); return }
        guard let first = documents.first else { completion(nil); return }
        let next: (NSError?) -> Void = { [self] error in
            if let error { completion(error) } else { persist(Array(documents.dropFirst()), decision: decision, generation: generation, completion: completion) }
        }
        switch decision {
        case .save: documentStore.save(documentIdentifier: first.documentIdentifier, overwrite: false) { outcome, error in next(outcome == .saved ? nil : error ?? Self.error(3)) }
        case .discard: documentStore.discardChanges(documentIdentifier: first.documentIdentifier) { _, error in next(error) }
        case .keepDrafts: documentStore.persistDraft(documentIdentifier: first.documentIdentifier, completion: next)
        case .cancel: completion(Self.error(1))
        }
    }
    private func fail(_ error: NSError, completion: (Bool) -> Void) {
        cancelOperation(); delegate?.fileSessionCoordinator(self, didFail: error); completion(false)
    }
    static func error(_ code: Int) -> NSError {
        NSError(domain: "iTermFileSession", code: code, userInfo: [NSLocalizedDescriptionKey:
            String(localized: "FileSession.OperationFailed", defaultValue: "The file operation could not finish. Your open editor has been kept.", comment: "Error when native file session operation cannot safely finish")])
    }
}
