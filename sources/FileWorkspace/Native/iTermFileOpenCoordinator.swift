import Foundation

/// Per-window admission policy. Native containers supply identity fences and insertion/activation only.
@objcMembers final class iTermFileOpenCoordinator: NSObject {
    private let coordinator: iTermFileSessionCoordinator
    private var pending: Pending?
    private var queued: (run: () -> Void, cancel: () -> Void)?
    private final class Pending {
        let request: iTermFileOpenRequest
        var pinned: Bool
        var superseded = false
        weak var admittedPane: iTermFileSessionPane?
        init(_ request: iTermFileOpenRequest) { self.request = request; pinned = request.activation == .pinned }
    }
    init(coordinator: iTermFileSessionCoordinator) { self.coordinator = coordinator }
    func open(_ request: iTermFileOpenRequest, candidates: [iTermFileSessionPane],
              isCurrent: @escaping () -> Bool,
              install: @escaping (iTermFileSessionPane, @escaping (Bool) -> Void) -> Void,
              activate: @escaping (iTermFileSessionPane) -> Void, completion: @escaping (Bool) -> Void) {
        if let pending, !pending.superseded, isCurrent(), request.placement == .tab, pending.request.placement == .tab,
           request.context === pending.request.context, request.path == pending.request.path, request.viewMode == pending.request.viewMode {
            pending.pinned = pending.pinned || request.activation == .pinned
            if pending.pinned { pending.admittedPane?.pin() }; completion(true); return
        }
        if let pending {
            pending.superseded = true
            let previous = queued
            queued = ({ [weak self] in self?.open(request, candidates: candidates, isCurrent: isCurrent, install: install, activate: activate, completion: completion) }, { completion(false) })
            previous?.cancel()
            return
        }
        let intent = Pending(request); pending = intent
        let ended: (Bool) -> Void = { [weak self] success in
            guard let self else { completion(false); return }
            self.coordinator.afterPendingDocumentReleases { [weak self] in
                guard let self else { completion(false); return }
                if self.pending === intent { self.pending = nil }
                let next = self.queued; self.queued = nil
                next?.run(); completion(success)
            }
        }
        let current = { [weak self, weak intent] in self?.pending === intent && intent?.superseded == false && isCurrent() }
        let finish: (iTermFileSessionPane) -> Void = { pane in
            guard current() else { pane.controller.cancelPendingFocus(); ended(false); return }
            intent.admittedPane = pane
            if let viewMode = request.viewMode {
                var state = pane.controller.cachedViewState.dictionary; state["viewMode"] = viewMode
                if let anchor = request.anchor { state["viewerState"] = ["anchor": anchor] }
                pane.controller.restoreViewState(iTermFileViewState(dictionary: state))
            }
            if intent.pinned { pane.pin() }
            activate(pane); ended(true)
        }
        if request.placement == .tab,
           let pane = candidates.first(where: { !$0.closed && $0.descriptor.filePath == request.path &&
               $0.controller.cachedViewState.showsMarkdownPreview == (request.viewMode == "preview") }) {
            finish(pane); return
        }
        let admit = { [weak self] in
            guard let self, current() else { ended(false); return }
            let owner = request.ownerContext
            let descriptor = iTermFileSessionDescriptor(filePath: request.path, documentIdentifier: nil,
                rootDirectory: owner.rootDirectory, projectIdentifier: owner.projectIdentifier,
                worktreeIdentifier: owner.worktreeIdentifier, preview: !intent.pinned, viewState: request.initialViewState)
            self.coordinator.restore(descriptor, viewIdentifier: StableSessionID.generate(), context: request.context, readScope: request.readScope) { pane, error in
                guard let pane else {
                    if current(), let error { self.coordinator.delegate?.fileSessionCoordinator(self.coordinator, didFail: error) }
                    ended(false); return
                }
                guard current() else { self.coordinator.abandon(pane); ended(false); return }
                // Canonical aliases still share one default view in this workspace/group.
                if request.placement == .tab, let existing = candidates.first(where: {
                    !$0.closed && $0.documentIdentifier != nil && $0.documentIdentifier == pane.documentIdentifier &&
                    $0.controller.cachedViewState.showsMarkdownPreview == (request.viewMode == "preview")
                }) { self.coordinator.abandon(pane); finish(existing); return }
                install(pane) { installed in
                    guard installed else { self.coordinator.abandon(pane); ended(false); return }
                    // Insertion itself changes native selection. Its native callback already rechecked the origin.
                    intent.admittedPane = pane
                    if intent.pinned { pane.pin() }
                    if !intent.superseded { activate(pane) }
                    else { pane.controller.cancelPendingFocus() }
                    ended(true)
                }
            }
        }
        if request.placement == .tab, let preview = candidates.first(where: { !$0.closed && $0.controller.status.isPreview }) {
            coordinator.replacePreview(preview, request: request, isCurrent: current) { replaced, error in
                if replaced { finish(preview) } else if error == nil { admit() } else {
                    if current(), let error { self.coordinator.delegate?.fileSessionCoordinator(self.coordinator, didFail: error) }
                    ended(false)
                }
            }
        } else { admit() }
    }
}
