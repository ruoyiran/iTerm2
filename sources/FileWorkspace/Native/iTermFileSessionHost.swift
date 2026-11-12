import AppKit

/// The only adapter that knows PTYSession. The injected coordinator remains hostless-testable.
@objcMembers final class iTermFileSessionHost: NSObject, iTermFileSessionPaneDelegate, iTermFileSessionCoordinatorDelegate {
    private static let prompts = iTermFileSessionHost(session: nil)
    private weak var session: PTYSession?
    private var loading = false
    private var pendingClose: (() -> Void)?
    init(session: PTYSession?) { self.session = session; super.init() }

    static func installCoordinator(_ coordinator: iTermFileSessionCoordinator) {
        iTermFileSessionCoordinator.installed = coordinator
        coordinator.delegate = prompts
    }
    static func attach(_ pane: iTermFileSessionPane, to session: PTYSession) {
        session.fileSessionDescriptor = pane.descriptor.dictionary
        session.fileSessionPane = pane
        let host = iTermFileSessionHost(session: session)
        session.fileSessionHost = host; pane.delegate = host
        session.view?.fileViewController = pane.controller
        host.fileSessionPaneDidChange(pane)
        host.updateVisibility()
    }
    static func restoreSession(_ session: PTYSession) {
        let host = iTermFileSessionHost(session: session); session.fileSessionHost = host
        let placeholder = NSViewController()
        let label = NSTextField(wrappingLabelWithString: String(localized: "FileSession.Loading",
            defaultValue: "Opening file…", comment: "Placeholder while a native file pane restores"))
        label.frame = NSRect(x: 20, y: 20, width: 300, height: 60)
        placeholder.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        placeholder.view.addSubview(label); session.view?.fileViewController = placeholder
        guard let raw = session.fileSessionDescriptor as? [String: Any],
              let descriptor = iTermFileSessionDescriptor(dictionary: raw),
              let coordinator = iTermFileSessionCoordinator.installed else {
            label.stringValue = String(localized: "FileSession.RestoreUnavailable", defaultValue: "This file view could not be restored.", comment: "Missing file workspace service or invalid saved file descriptor")
            session.setUntrustedIconName(label.stringValue); return
        }
        host.loading = true
        coordinator.restore(descriptor, viewIdentifier: session.stableID, context: nil) { [weak session, weak host] pane, error in
            host?.loading = false
            let pendingClose = host?.pendingClose; host?.pendingClose = nil
            guard let session, !session.exited else {
                if let pane { coordinator.abandon(pane) }
                return
            }
            guard let pane else {
                label.stringValue = (error ?? iTermFileSessionCoordinator.error(1)).localizedDescription
                pendingClose?(); return
            }
            attach(pane, to: session)
            pendingClose?()
        }
    }
    func updateVisibility() {
        guard let session, let pane = session.fileSessionPane else { return }
        let visible = session.view?.window != nil && session.delegate?.sessionBelongsToVisibleTab() == true
        if visible && pane.coordinator?.operationInProgress == false { pane.controller.resumeEditing() }
        pane.controller.setVisible(visible)
    }
    func fileSessionPaneDidChange(_ pane: iTermFileSessionPane) {
        guard let session else { return }
        let previousOwner = session.fileSessionDescriptor?["projectIdentifier"] as? String
        session.fileSessionDescriptor = pane.descriptor.dictionary
        // A rebind changes the pane owner. Routine status updates must not undo a later
        // explicit project assignment made through the native session menu.
        if previousOwner != pane.descriptor.projectIdentifier { session.projectIdentifier = pane.descriptor.projectIdentifier }
        session.setUntrustedIconName(pane.title)
        session.nameController.setNeedsUpdate()
        session.view?.window?.invalidateRestorableState()
    }
    func fileSessionPaneDidReceiveFocus(_ pane: iTermFileSessionPane) {
        session?.textViewDidBecomeFirstResponder()
    }
    func fileSessionPane(_ pane: iTermFileSessionPane, request command: iTermFileViewCommand) {
        guard let coordinator = pane.coordinator else { return }
        if command == .undo || command == .redo {
            coordinator.undo(pane, redo: command == .redo) { error in
                if let error { Self.prompts.fileSessionCoordinator(coordinator, didFail: error) }
            }; return
        }
        guard command == .save || command == .saveAs else { return }
        if command == .saveAs {
            let panel = NSSavePanel(); panel.nameFieldStringValue = (pane.descriptor.filePath as NSString).lastPathComponent
            panel.directoryURL = URL(fileURLWithPath: pane.descriptor.filePath).deletingLastPathComponent()
            guard let window = session?.view?.window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let path = panel.url?.path else { return }
                Self.save(pane, coordinator: coordinator, path: path, overwrite: false)
            }
        } else { Self.save(pane, coordinator: coordinator, path: nil, overwrite: false) }
    }
    private static func save(_ pane: iTermFileSessionPane, coordinator: iTermFileSessionCoordinator, path: String?, overwrite: Bool) {
        coordinator.save(pane, toPath: path, overwrite: overwrite) { outcome, error in
            if outcome == .saved { return }
            if outcome == .conflict && !overwrite {
                let answer = iTermWarning.show(withTitle: String(localized: "FileSession.OverwriteQuestion",
                    defaultValue: "The file changed on disk. Replace it with the editor contents?", comment: "Explicit overwrite confirmation after a file save conflict"),
                    actions: [String(localized: "FileSession.Replace", defaultValue: "Replace", comment: "Button to overwrite a conflicting disk file"), iTermLocalizedCancel()],
                    accessory: nil, identifier: nil, silenceable: .kiTermWarningTypePersistent, heading: nil, window: pane.controller.view.window)
                if answer == .kiTermWarningSelection0 { save(pane, coordinator: coordinator, path: path, overwrite: true) }
            } else { prompts.fileSessionCoordinator(coordinator, didFail: error ?? iTermFileSessionCoordinator.error(3)) }
        }
    }
    func fileSessionCoordinator(_ coordinator: iTermFileSessionCoordinator, decideFor documents: [iTermFileDocumentSnapshot],
                                quitting: Bool, completion: @escaping (iTermFileCloseDecision) -> Void) {
        let names = documents.map { ($0.filePath as NSString).lastPathComponent }.joined(separator: "\n")
        let title = quitting ? String(localized: "FileSession.QuitDirty", defaultValue: "Save the edited files before quitting?", comment: "Quit confirmation for unsaved file documents") :
            String(localized: "FileSession.CloseDirty", defaultValue: "Save changes before closing these files?", comment: "Confirmation before closing the last views of edited documents")
        let save = quitting ? String(localized: "FileSession.SaveAll", defaultValue: "Save All", comment: "Save every edited file before quitting") :
            String(localized: "FileSession.Save", defaultValue: "Save", comment: "Save edited files before closing")
        let second = quitting ? String(localized: "FileSession.KeepDraftsQuit", defaultValue: "Keep Drafts and Quit", comment: "Quit preserving file drafts without saving source files") :
            String(localized: "FileSession.Discard", defaultValue: "Discard", comment: "Discard unsaved edits and delete their recovery drafts")
        let answer = iTermWarning.show(withTitle: title + "\n\n" + names, actions: [save, second, iTermLocalizedCancel()],
            accessory: nil, identifier: nil, silenceable: .kiTermWarningTypePersistent, heading: nil, window: NSApp.keyWindow)
        switch answer { case .kiTermWarningSelection0: completion(.save)
        case .kiTermWarningSelection1: completion(quitting ? .keepDrafts : .discard)
        default: completion(.cancel) }
    }
    func fileSessionCoordinator(_ coordinator: iTermFileSessionCoordinator, didFail error: NSError) {
        _ = iTermWarning.show(withTitle: error.localizedDescription, actions: [iTermLocalizedOK()], accessory: nil,
            identifier: nil, silenceable: .kiTermWarningTypePersistent, heading: nil, window: NSApp.keyWindow)
    }
    static func deferClosing(_ sessions: [PTYSession], continuation: @escaping () -> Void) -> Bool {
        guard !iTermController.sharedInstance().applicationIsQuitting else { return false }
        let files = sessions.filter { $0.isFileSession }
        if let waiting = files.first(where: { $0.fileSessionHost?.loading == true }) {
            waiting.fileSessionHost?.pendingClose = continuation
            return true
        }
        let panes = files.compactMap(\.fileSessionPane)
        guard !panes.isEmpty, let coordinator = iTermFileSessionCoordinator.installed else { return false }
        if panes.allSatisfy({ coordinator.isCloseApproved($0) }) { return false }
        coordinator.prepareClose(panes, quitting: false) { allowed in
            guard allowed else { return }
            continuation()
            coordinator.completeClose(quitting: false)
        }
        return true
    }
    static func sessionWillTerminate(_ session: PTYSession) {
        guard let pane = session.fileSessionPane else { return }
        pane.coordinator?.didClose(pane, quitting: iTermController.sharedInstance().applicationIsQuitting)
    }
    static func beginQuit(completion: @escaping (Bool) -> Void) -> Bool {
        guard let coordinator = iTermFileSessionCoordinator.installed, coordinator.hasResources else { return false }
        coordinator.prepareClose(coordinator.panes, quitting: true, completion: completion); return true
    }
    static func cancelQuit() { iTermFileSessionCoordinator.installed?.cancelOperation() }
    static func finishQuit() { iTermFileSessionCoordinator.installed?.completeClose(quitting: true) }
}

extension PTYSession {
    @objc func filePerformCommand(_ command: iTermFileViewCommand) {
        guard isFileSession, let controller = fileSessionPane?.controller, controller.canPerform(command) else { return }
        controller.perform(command)
    }
    @objc func saveDocument(_ sender: Any?) { filePerformCommand(.save) }
    @objc func saveDocumentAs(_ sender: Any?) { filePerformCommand(.saveAs) }
    @objc func undo(_ sender: Any?) { filePerformCommand(.undo) }
    @objc func redo(_ sender: Any?) { filePerformCommand(.redo) }
    @objc func copy(_ sender: Any?) { filePerformCommand(.copy) }
    @objc func cut(_ sender: Any?) { filePerformCommand(.cut) }
}
