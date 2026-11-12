import AppKit

/// A browser backend belongs to one explorer. Only documents/runtime/native admission are suite shared.
@objcMembers final class iTermFileBrowserCoordinator: NSObject, iTermFileBrowserViewControllerDelegate {
    let controller: iTermFileBrowserViewController
    let backend = iTermFileBrowserService()
    private let native: iTermFileSessionCoordinator
    private(set) var context: iTermFileBrowserContext?
    private var base: iTermFileBrowserContext?
    private var visibilityPreference: (hidden: Bool, ignored: Bool)?
    private var searches = [String: String]()
    private var visible = false
    private var stopped = false
    var nativeRequest: ((iTermFileBrowserRequest) -> Void)?
    init(native: iTermFileSessionCoordinator) {
        self.native = native; controller = iTermFileBrowserViewController(runtime: native.runtime)
        super.init(); controller.delegate = self
    }
    func applyContext(_ value: iTermFileBrowserContext?) {
        guard context !== value else { return }
        let selected = value.map { value -> iTermFileBrowserContext in
            guard let preference = visibilityPreference,
                  preference.hidden != value.showsHiddenFiles || preference.ignored != value.showsGitIgnoredFiles else { return value }
            return iTermFileBrowserContext(rootDirectory: value.rootDirectory, projectIdentifier: value.projectIdentifier,
                worktreeIdentifier: value.worktreeIdentifier, generation: value.generation,
                showsHiddenFiles: visibilityPreference?.hidden ?? value.showsHiddenFiles,
                showsGitIgnoredFiles: visibilityPreference?.ignored ?? value.showsGitIgnoredFiles)
        }
        base = selected; switchContext(selected)
    }
    private func switchContext(_ value: iTermFileBrowserContext?) {
        cancel(); context = value
        if let value { backend.activate(value) } else { backend.deactivate() }
        controller.applyContext(value, title: value.map { ($0.rootDirectory as NSString).lastPathComponent } ?? "")
        if let value {
            backend.operationState(value) { [weak self] undo, redo in
                self?.controller.applyOperationState(canUndo: undo, canRedo: redo, context: value)
            }
        }
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }; visible = value
        if !value { cancel(); backend.deactivate() }
        else if let context { backend.activate(context) }
        controller.setVisible(value)
    }
    func refresh() {
        guard visible, let context else { return }
        backend.invalidate(context, directoryPaths: [context.rootDirectory]); controller.refresh()
        if !native.operationInProgress {
            native.documentStore.allSnapshots { [weak self] values in
                guard let self, !self.native.operationInProgress else { return }
                for value in values where value.filePath.hasPrefix(context.rootDirectory + "/") {
                    self.native.documentStore.fileDidChange(atPath: value.filePath) { _, _ in }
                }
            }
        }
    }
    private func cancel() { searches.values.forEach { backend.cancel($0) }; searches.removeAll() }
    func shutdown() { stopped = true; cancel(); backend.deactivate(); controller.shutdown(); nativeRequest = nil }
    func fileBrowserDidReceiveFocus(_ controller: iTermFileBrowserViewController) {}
    func fileBrowser(_ controller: iTermFileBrowserViewController, didRequest request: iTermFileBrowserRequest) {
        guard !stopped, visible, request.context === context else { return }
        let context = request.context
        switch request.kind {
        case .listDirectory:
            backend.listDirectory(atPath: request.directoryPath!, context: context) { [weak self] entries, error in
                self?.controller.applyListing(entries, directoryPath: request.directoryPath!, requestIdentifier: request.identifier, context: context, error: error)
            }
        case .searchNames, .searchContents:
            let publish: (iTermFileSearchBatch) -> Void = { [weak self] batch in
                self?.controller.applySearch(batch, requestIdentifier: request.identifier)
                if batch.isComplete { self?.searches.removeValue(forKey: request.identifier) }
            }
            searches[request.identifier] = request.kind == .searchNames ? backend.searchNames(request.nameQuery!, context: context, batch: publish) : backend.searchContents(request.contentQuery!, context: context, batch: publish)
        case .cancelSearch:
            if let identifier = request.cancelledRequestIdentifier, let id = searches.removeValue(forKey: identifier) { backend.cancel(id) }
        case .refresh: backend.invalidate(context, directoryPaths: [request.directoryPath!])
        case .setVisibility:
            visibilityPreference = (request.showsHiddenFiles, request.showsGitIgnoredFiles)
            let value = iTermFileBrowserContext(rootDirectory: context.rootDirectory, projectIdentifier: context.projectIdentifier,
                worktreeIdentifier: context.worktreeIdentifier, generation: context.generation &+ 1,
                showsHiddenFiles: request.showsHiddenFiles, showsGitIgnoredFiles: request.showsGitIgnoredFiles)
            if let base {
                self.base = iTermFileBrowserContext(rootDirectory: base.rootDirectory, projectIdentifier: base.projectIdentifier,
                    worktreeIdentifier: base.worktreeIdentifier, generation: value.generation,
                    showsHiddenFiles: value.showsHiddenFiles, showsGitIgnoredFiles: value.showsGitIgnoredFiles)
            }
            switchContext(value)
        case .findInFolder:
            // Listing validates the directory with the backend's root-fenced openat traversal before scoping it.
            backend.listDirectory(atPath: request.directoryPath!, context: context) { [weak self] _, error in
                guard let self, self.context === context, error == nil else { return }
                self.switchContext(iTermFileBrowserContext(rootDirectory: request.directoryPath!, projectIdentifier: context.projectIdentifier,
                    worktreeIdentifier: context.worktreeIdentifier, generation: context.generation &+ 1,
                    showsHiddenFiles: context.showsHiddenFiles, showsGitIgnoredFiles: context.showsGitIgnoredFiles))
                self.controller.focusQuery(contents: true)
            }
        case .returnToRoot: switchContext(base)
        case .openFile:
            guard request.setFileOwnerContext(base ?? context) else { return }
            nativeRequest?(request)
        case .createFile, .createFolder, .rename, .duplicateFile, .trash, .move, .undo, .redo:
            performMutation(request) { _ in }
        default: nativeRequest?(request)
        }
    }
    func performMutation(_ request: iTermFileBrowserRequest, completion: @escaping (NSError?) -> Void) {
        guard !stopped, visible, request.context === context,
              [.createFile, .createFolder, .rename, .duplicateFile, .trash, .move, .undo, .redo].contains(request.kind) else {
            completion(iTermFileSessionCoordinator.error(1)); return
        }
        let context = request.context
        // Undo/redo may affect any path in this backend journal. Conservatively guard the entire owner root.
        let affected = [.undo, .redo].contains(request.kind) ? [context.rootDirectory] :
            ([.rename, .trash, .move].contains(request.kind) ? request.paths : [])
        native.prepareFileMutation(paths: affected, preservingChanges: [.rename, .move].contains(request.kind), isCurrent: { [weak self] in self?.context === context && self?.visible == true }) { [self] allowed in
            guard allowed else {
                let error = iTermFileSessionCoordinator.error(1)
                controller.completeRequest(request.identifier, context: context, error: error); completion(error); return
            }
            let done: (iTermFileOperationResult) -> Void = { [self] result in
                // Do not check display context until every committed mapping and draft path has been applied.
                native.applyCommittedPathMappings(result.mappings, completionWithError: { [self] mappingError in
                    native.finishOperation { [self] error in
                        controller.completeRequest(request.identifier, context: context, error: result.error ?? mappingError ?? error)
                        controller.applyOperationState(canUndo: result.canUndo, canRedo: result.canRedo, context: context)
                        if self.context === context { refresh() }
                        completion(result.error ?? mappingError ?? error)
                    }
                })
            }
            switch request.kind {
            case .createFile: backend.createFile(inDirectory: request.directoryPath!, name: request.name!, context: context, completion: done)
            case .createFolder: backend.createFolder(inDirectory: request.directoryPath!, name: request.name!, context: context, completion: done)
            case .rename: backend.rename(request.paths[0], newName: request.name!, context: context, completion: done)
            case .duplicateFile: backend.duplicateFile(request.paths[0], newName: request.name!, context: context, completion: done)
            case .trash: backend.trash(request.paths, context: context, completion: done)
            case .move: backend.move(request.paths, toDirectory: request.directoryPath!, context: context, completion: done)
            case .undo: backend.undo(context, completion: done)
            case .redo: backend.redo(context, completion: done)
            default: native.cancelOperation()
            }
        }
    }
}
