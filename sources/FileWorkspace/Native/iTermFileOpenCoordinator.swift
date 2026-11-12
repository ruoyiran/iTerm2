import Foundation

/// Per-window admission policy. Native containers supply identity fences and insertion/activation only.
@objcMembers final class iTermFileOpenCoordinator: NSObject {
    private let coordinator: iTermFileSessionCoordinator
    private var pending: Pending?
    private var queued: (() -> Void)?
    private final class Pending {
        let request: iTermFileOpenRequest
        var pinned: Bool
        var superseded = false
        init(_ request: iTermFileOpenRequest) { self.request = request; pinned = request.activation == .pinned }
    }
    init(coordinator: iTermFileSessionCoordinator) { self.coordinator = coordinator }
    func open(_ request: iTermFileOpenRequest, candidates: [iTermFileSessionPane],
              isCurrent: @escaping () -> Bool,
              install: @escaping (iTermFileSessionPane, @escaping (Bool) -> Void) -> Void,
              activate: @escaping (iTermFileSessionPane) -> Void, completion: @escaping (Bool) -> Void) {
        if let pending, !pending.superseded, isCurrent(), request.placement == .tab, pending.request.placement == .tab,
           request.context === pending.request.context, request.path == pending.request.path {
            pending.pinned = pending.pinned || request.activation == .pinned; completion(true); return
        }
        if let pending {
            pending.superseded = true
            queued = { [weak self] in self?.open(request, candidates: candidates, isCurrent: isCurrent, install: install, activate: activate, completion: completion) }
            return
        }
        let intent = Pending(request); pending = intent
        let ended: (Bool) -> Void = { [weak self] success in
            guard let self else { completion(false); return }
            if self.pending === intent { self.pending = nil }
            let next = self.queued; self.queued = nil
            completion(success); next?()
        }
        let current = { [weak self, weak intent] in self?.pending === intent && intent?.superseded == false && isCurrent() }
        let finish: (iTermFileSessionPane) -> Void = { pane in
            guard current() else { pane.controller.cancelPendingFocus(); ended(false); return }
            if intent.pinned { pane.pin() }
            activate(pane); ended(true)
        }
        if request.placement == .tab,
           let pane = candidates.first(where: { !$0.closed && $0.descriptor.filePath == request.path }) {
            finish(pane); return
        }
        let admit = { [weak self] in
            guard let self, current() else { ended(false); return }
            self.coordinator.openFile(atPath: request.path, context: request.context,
                viewIdentifier: UUID().uuidString, preview: !intent.pinned) { pane, error in
                guard let pane else {
                    if current(), let error { self.coordinator.delegate?.fileSessionCoordinator(self.coordinator, didFail: error) }
                    ended(false); return
                }
                guard current() else { self.coordinator.abandon(pane); ended(false); return }
                // Canonical aliases still share one default view in this workspace/group.
                if request.placement == .tab, let existing = candidates.first(where: {
                    !$0.closed && $0.documentIdentifier != nil && $0.documentIdentifier == pane.documentIdentifier
                }) { self.coordinator.abandon(pane); finish(existing); return }
                install(pane) { installed in
                    guard installed else { self.coordinator.abandon(pane); ended(false); return }
                    // Insertion itself changes native selection. Its native callback already rechecked the origin.
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
