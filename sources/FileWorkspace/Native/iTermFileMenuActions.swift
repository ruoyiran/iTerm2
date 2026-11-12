import AppKit

/// Shared AppKit menu and controller command path. Focus resolution uses the actual file root,
/// so reparenting keeps working without changing WebKit's responder chain or its undo manager.
@objcMembers final class iTermFileMenuActions: NSObject, NSMenuItemValidation {
    private static let roots = NSMapTable<NSView, iTermFileMenuActions>.weakToWeakObjects()
    private weak var pane: iTermFileSessionPane?
    var requestSaveAs: (() -> Void)?
    var saveFailed: ((iTermFileSaveOutcome, NSError?, String?) -> Void)?
    var didFail: ((NSError) -> Void)?
    init(pane: iTermFileSessionPane) { self.pane = pane; super.init() }

    static func register(_ actions: iTermFileMenuActions, rootView: NSView) { roots.setObject(actions, forKey: rootView) }
    private static func target(_ firstResponder: NSResponder?) -> iTermFileMenuActions? {
        // Ordinary AppKit editors keep their local editing/undo behavior, including field editors.
        if let text = firstResponder as? NSTextView, text.isEditable { return nil }
        if let field = firstResponder as? NSTextField, field.isEditable { return nil }
        var view = (firstResponder as? NSView) ?? (firstResponder as? NSViewController)?.view
        while let current = view {
            if let target = roots.object(forKey: current) { return target }
            view = current.superview
        }
        return nil
    }
    private static func command(_ item: NSMenuItem) -> iTermFileViewCommand? {
        switch item.action.map(NSStringFromSelector) {
        case "saveSelectedTextOrFile:": return .save
        case "saveFileAs:": return .saveAs
        case "undo:": return .undo
        case "redo:": return .redo
        default: return nil
        }
    }
    static func validate(_ item: NSMenuItem, firstResponder: NSResponder?) -> NSNumber? {
        guard command(item) != nil, let target = target(firstResponder) else { return nil }
        if item.action == NSSelectorFromString("saveSelectedTextOrFile:") {
            item.title = String(localized: "FileSession.Save", defaultValue: "Save", comment: "Save the focused file document")
        }
        return NSNumber(value: target.validateMenuItem(item))
    }
    /// Nil means the existing non-file application route owns this item. False means a focused
    /// file owns it but mutation is disabled; callers must not fall through to WebKit undo.
    static func perform(_ item: NSMenuItem, firstResponder: NSResponder?,
                        completion: ((iTermFileViewCommand, NSError?) -> Void)? = nil) -> NSNumber? {
        guard let command = command(item), let target = target(firstResponder) else { return nil }
        guard target.validateMenuItem(item) else { return false }
        target.perform(command) { completion?(command, $0) }
        return true
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = Self.command(menuItem), let pane, !pane.closed, !pane.controller.status.isComposing,
              pane.coordinator?.operationInProgress == false else { return false }
        return pane.controller.canPerform(command)
    }
    func perform(_ command: iTermFileViewCommand, completion: ((NSError?) -> Void)? = nil) {
        guard let pane, let coordinator = pane.coordinator, !pane.closed else { completion?(iTermFileSessionCoordinator.error(1)); return }
        switch command {
        case .save: save(toPath: nil, overwrite: false, completion: completion)
        case .saveAs: requestSaveAs?(); completion?(nil)
        case .undo, .redo:
            coordinator.undo(pane, redo: command == .redo) { [weak self] error in
                if let error { self?.didFail?(error) }; completion?(error)
            }
        default: pane.controller.perform(command); completion?(nil)
        }
    }
    func save(toPath: String?, overwrite: Bool, completion: ((NSError?) -> Void)? = nil) {
        guard let pane, let coordinator = pane.coordinator else { completion?(iTermFileSessionCoordinator.error(1)); return }
        coordinator.save(pane, toPath: toPath, overwrite: overwrite) { [weak self] outcome, error in
            if outcome != .saved { self?.saveFailed?(outcome, error, toPath) }
            completion?(outcome == .saved ? nil : error ?? iTermFileSessionCoordinator.error(3))
        }
    }
}
