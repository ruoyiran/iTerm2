import Foundation
import CoreFoundation

@objc enum iTermFileActivation: Int { case preview, pinned }
@objc enum iTermFileViewCommand: Int {
    case save, saveAs, undo, redo, cut, copy, paste, selectAll, find, findNext, findPrevious, toggleMarkdownPreview, pin
    var wireName: String { ["save", "saveAs", "undo", "redo", "cut", "copy", "paste", "selectAll", "find", "findNext", "findPrevious", "toggleMarkdownPreview", "pin"][rawValue] }
    init?(wireName: String) {
        guard let value = (0...13).compactMap({ Self(rawValue: $0) }).first(where: { $0.wireName == wireName }) else { return nil }; self = value
    }
}
@objc enum iTermFileFlushReason: Int { case save, focusTransfer, close, quit, suspend }
@objc enum iTermFileBrowserRequestKind: Int {
    case listDirectory, searchNames, searchContents, cancelSearch, refresh, setVisibility, openFile, openTerminal
    case revealInFinder, openExternally, copyFiles, copyAbsolutePaths, copyRelativePaths, addFolderAsProject
    case createFile, createFolder, rename, duplicateFile, trash, move, undo, redo, findInFolder, returnToRoot
    var wireName: String { ["listDirectory", "searchNames", "searchContents", "cancelSearch", "refresh", "setVisibility", "openFile", "openTerminal", "revealInFinder", "openExternally", "copyFiles", "copyAbsolutePaths", "copyRelativePaths", "addFolderAsProject", "createFile", "createFolder", "rename", "duplicateFile", "trash", "move", "undo", "redo", "findInFolder", "returnToRoot"][rawValue] }
    init?(wireName: String) { guard let value = (0...23).compactMap({ Self(rawValue: $0) }).first(where: { $0.wireName == wireName }) else { return nil }; self = value }
}

// Localization unneeded: these strings are protocol tags, never displayed.
func fileUIOpenStyle(_ name: String) -> iTermOpenStyle? {
    switch name { case "tab": return .tab; case "verticalSplit": return .verticalSplit; case "horizontalSplit": return .horizontalSplit; case "window": return .window; default: return nil }
}
func fileUIInteger(_ value: Any?, minimum: Int = 0, maximum: Int = Int.max) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
          number.doubleValue >= Double(minimum), number.doubleValue < Double(Int.max),
          number.intValue <= maximum else { return nil }; return number.intValue
}

@objcMembers final class iTermFileOpenRequest: NSObject {
    let context: iTermFileBrowserContext
    let ownerContext: iTermFileBrowserContext
    let path: String
    let placement: iTermOpenStyle
    let activation: iTermFileActivation
    let lineNumber: Int
    let utf16Column: Int
    convenience init(context: iTermFileBrowserContext, path: String, placement: iTermOpenStyle, activation: iTermFileActivation,
                     lineNumber: Int = 0, utf16Column: Int = 0) {
        self.init(context: context, ownerContext: context, path: path, placement: placement, activation: activation,
                  lineNumber: lineNumber, utf16Column: utf16Column)
    }
    init(context: iTermFileBrowserContext, ownerContext: iTermFileBrowserContext, path: String,
         placement: iTermOpenStyle, activation: iTermFileActivation, lineNumber: Int = 0, utf16Column: Int = 0) {
        self.ownerContext = ownerContext
        self.context = context; self.path = path; self.placement = placement; self.activation = activation
        self.lineNumber = lineNumber; self.utf16Column = utf16Column
    }
}
@objcMembers final class iTermFileBrowserRequest: NSObject {
    let identifier: String
    let context: iTermFileBrowserContext
    let kind: iTermFileBrowserRequestKind
    let paths: [String]
    let directoryPath: String?
    let name: String?
    let nameQuery: String?
    let contentQuery: iTermFileContentQuery?
    private(set) var openRequest: iTermFileOpenRequest?
    let terminalPlacement: iTermOpenStyle
    let showsHiddenFiles: Bool
    let showsGitIgnoredFiles: Bool
    let cancelledRequestIdentifier: String?

    /// Bound by the native browser coordinator, never accepted from web payloads.
    @nonobjc func setFileOwnerContext(_ owner: iTermFileBrowserContext) -> Bool {
        guard let open = openRequest, owner.projectIdentifier == context.projectIdentifier,
              owner.worktreeIdentifier == context.worktreeIdentifier,
              context.rootDirectory == owner.rootDirectory || context.rootDirectory.hasPrefix(owner.rootDirectory == "/" ? "/" : owner.rootDirectory + "/") else { return false }
        openRequest = iTermFileOpenRequest(context: open.context, ownerContext: owner, path: open.path,
            placement: open.placement, activation: open.activation, lineNumber: open.lineNumber, utf16Column: open.utf16Column)
        return true
    }

    @nonobjc init?(identifier: String, context: iTermFileBrowserContext, type: String, payload: [String: Any]) {
        guard let kind = iTermFileBrowserRequestKind(wireName: type) else { return nil }
        func validPath(_ value: String) -> Bool {
            value.utf8.count <= 16384 && !value.contains("\0") && (value as NSString).standardizingPath == value &&
            (value == context.rootDirectory || value.hasPrefix(context.rootDirectory == "/" ? "/" : context.rootDirectory + "/"))
        }
        let paths = payload["paths"] as? [String] ?? []
        guard paths.count <= 512, paths.allSatisfy(validPath) else { return nil }
        let directory = payload["directoryPath"] as? String
        if let directory = directory, !validPath(directory) { return nil }
        let name = payload["name"] as? String
        if let name = name, name.isEmpty || name.utf8.count > 255 || name.contains("/") || name.contains("\0") || name == "." || name == ".." { return nil }
        var query: iTermFileContentQuery?
        if kind == .searchContents {
            guard let q = payload["query"] as? [String: Any], let text = q["text"] as? String, !text.isEmpty, text.utf8.count <= 2048,
                  let include = q["includeGlobs"] as? [String], let exclude = q["excludeGlobs"] as? [String],
                  include.count + exclude.count <= 128, (include + exclude).allSatisfy({ $0.utf8.count <= 2048 }) else { return nil }
            query = iTermFileContentQuery(text: text, regularExpression: q["regularExpression"] as? Bool ?? false,
                                         caseSensitive: q["caseSensitive"] as? Bool ?? false, wholeWord: q["wholeWord"] as? Bool ?? false,
                                         includeGlobs: include, excludeGlobs: exclude)
        }
        let nameQuery = payload["query"] as? String
        if kind == .searchNames, nameQuery == nil || nameQuery!.utf8.count > 2048 { return nil }
        let placement = fileUIOpenStyle(payload["placement"] as? String ?? "tab")
        guard let placement = placement else { return nil }
        var open: iTermFileOpenRequest?
        if kind == .openFile {
            guard let path = payload["path"] as? String, validPath(path),
                  let activation = payload["activation"] as? String, ["preview", "pinned"].contains(activation),
                  let line = fileUIInteger(payload["lineNumber"] ?? 0, maximum: Int32.max.intValue),
                  let column = fileUIInteger(payload["utf16Column"] ?? 0, maximum: Int32.max.intValue) else { return nil }
            open = iTermFileOpenRequest(context: context, path: path, placement: placement, activation: activation == "preview" ? .preview : .pinned, lineNumber: line, utf16Column: column)
        }
        if [.listDirectory, .refresh, .openTerminal, .createFile, .createFolder, .move, .findInFolder, .addFolderAsProject].contains(kind), directory == nil { return nil }
        if [.rename, .duplicateFile, .trash, .move, .copyFiles, .copyAbsolutePaths, .copyRelativePaths, .revealInFinder, .openExternally].contains(kind), paths.isEmpty { return nil }
        if [.rename, .duplicateFile].contains(kind), paths.count != 1 { return nil }
        if [.rename, .duplicateFile, .createFile, .createFolder].contains(kind), name == nil { return nil }
        let cancelled = payload["identifier"] as? String
        if kind == .cancelSearch, cancelled == nil || cancelled!.utf8.count > 128 { return nil }
        self.identifier = identifier; self.context = context; self.kind = kind; self.paths = paths; directoryPath = directory
        self.name = name; self.nameQuery = nameQuery; contentQuery = query; openRequest = open; terminalPlacement = placement
        showsHiddenFiles = payload["showsHiddenFiles"] as? Bool ?? context.showsHiddenFiles
        showsGitIgnoredFiles = payload["showsGitIgnoredFiles"] as? Bool ?? context.showsGitIgnoredFiles
        cancelledRequestIdentifier = cancelled
    }
}

@objcMembers final class iTermFileViewState: NSObject {
    let schemaVersion = 1
    let selectionStartLine: Int
    let selectionStartColumn: Int
    let selectionEndLine: Int
    let selectionEndColumn: Int
    let scrollTop: Double
    let scrollLeft: Double
    let showsMarkdownPreview: Bool
    init(dictionary: [String: Any] = [:]) {
        selectionStartLine = fileUIInteger(dictionary["selectionStartLine"], minimum: 1, maximum: 100000000) ?? 1
        selectionStartColumn = fileUIInteger(dictionary["selectionStartColumn"], minimum: 1, maximum: 100000000) ?? 1
        selectionEndLine = fileUIInteger(dictionary["selectionEndLine"], minimum: 1, maximum: 100000000) ?? 1
        selectionEndColumn = fileUIInteger(dictionary["selectionEndColumn"], minimum: 1, maximum: 100000000) ?? 1
        let top = dictionary["scrollTop"] as? Double ?? 0, left = dictionary["scrollLeft"] as? Double ?? 0
        scrollTop = top.isFinite ? min(1e9, max(0, top)) : 0; scrollLeft = left.isFinite ? min(1e9, max(0, left)) : 0
        showsMarkdownPreview = dictionary["showsMarkdownPreview"] as? Bool ?? false
    }
    var dictionary: [String: Any] {
        ["schemaVersion": 1, "selectionStartLine": selectionStartLine, "selectionStartColumn": selectionStartColumn,
         "selectionEndLine": selectionEndLine, "selectionEndColumn": selectionEndColumn, "scrollTop": scrollTop,
         "scrollLeft": scrollLeft, "showsMarkdownPreview": showsMarkdownPreview]
    }
}
@objcMembers final class iTermFileViewStatus: NSObject {
    let documentIdentifier: String?
    let filePath: String?
    let title: String
    let isDirty: Bool
    let isReadOnly: Bool
    let hasDiskConflict: Bool
    let hasPendingEdits: Bool
    let isComposing: Bool
    let hasSelection: Bool
    let isPreview: Bool
    let isReady: Bool
    let error: NSError?
    @nonobjc init(snapshot: iTermFileDocumentSnapshot?, path: String?, recoveredIdentifier: String?, pending: Bool, composing: Bool,
                  selection: Bool, preview: Bool, ready: Bool, error: NSError?) {
        documentIdentifier = snapshot?.documentIdentifier ?? recoveredIdentifier; filePath = snapshot?.filePath ?? path
        title = ((snapshot?.filePath ?? path ?? "") as NSString).lastPathComponent
        isDirty = snapshot?.isDirty == true || pending; isReadOnly = snapshot?.isReadOnly ?? true
        hasDiskConflict = snapshot?.hasDiskConflict ?? false; hasPendingEdits = pending; isComposing = composing
        hasSelection = selection; isPreview = preview; isReady = ready; self.error = error
    }
}

extension Int32 { fileprivate var intValue: Int { Int(self) } }
extension iTermFileBrowserContext {
    func fileUIDictionary(token: String, title: String) -> [String: Any] {
        ["token": token, "rootDirectory": rootDirectory, "projectIdentifier": projectIdentifier, "worktreeIdentifier": worktreeIdentifier, "title": title, "showsHiddenFiles": showsHiddenFiles,
         "showsGitIgnoredFiles": showsGitIgnoredFiles]
    }
}
extension iTermFileDocumentSnapshot {
    func fileUIDictionary(includeText: Bool) -> [String: Any] {
        var value: [String: Any] = ["documentIdentifier": documentIdentifier, "filePath": filePath, "revision": String(revision),
                                   "isDirty": isDirty, "isReadOnly": isReadOnly, "hasDiskConflict": hasDiskConflict,
                                   "kind": kind.rawValue, "isTooLarge": isTooLarge]
        if includeText { value["text"] = text ?? "" }; return value
    }
}
extension iTermFileTextEdit { var fileUIDictionary: [String: Any] { ["location": range.location, "length": range.length, "replacement": replacement] } }
