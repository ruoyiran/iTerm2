import Foundation
import CoreFoundation

/// Small per-pane arrangement data. Document bytes live only in the document/draft stores.
@objcMembers final class iTermFileSessionDescriptor: NSObject {
    static let arrangementKey = "File Session"
    let filePath: String
    let documentIdentifier: String?
    let rootDirectory: String
    let projectIdentifier: String
    let worktreeIdentifier: String
    let preview: Bool
    let kind: Int
    let viewState: iTermFileViewState

    init(filePath: String, documentIdentifier: String?, rootDirectory: String,
         projectIdentifier: String, worktreeIdentifier: String, preview: Bool, viewState: iTermFileViewState, kind: Int = 0) {
        self.filePath = filePath; self.documentIdentifier = documentIdentifier; self.rootDirectory = rootDirectory
        self.projectIdentifier = projectIdentifier; self.worktreeIdentifier = worktreeIdentifier
        self.preview = preview; self.viewState = viewState; self.kind = kind
    }

    convenience init?(dictionary: [String: Any]) {
        guard let version = dictionary["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let path = dictionary["filePath"] as? String, Self.validPath(path),
              let root = dictionary["rootDirectory"] as? String, Self.validPath(root) else { return nil }
        let identifier = dictionary["documentIdentifier"] as? String
        if dictionary["documentIdentifier"] != nil && (identifier == nil || UUID(uuidString: identifier!) == nil) { return nil }
        let kind = dictionary["kind"] as? Int ?? 0
        guard iTermFileDocumentKind(rawValue: kind) != nil else { return nil }
        self.init(filePath: path, documentIdentifier: identifier, rootDirectory: root,
                  projectIdentifier: dictionary["projectIdentifier"] as? String ?? "",
                  worktreeIdentifier: dictionary["worktreeIdentifier"] as? String ?? "",
                  preview: dictionary["preview"] as? Bool ?? false,
                  viewState: iTermFileViewState(dictionary: dictionary["viewState"] as? [String: Any] ?? [:]), kind: kind)
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = ["version": 1, "filePath": filePath, "rootDirectory": rootDirectory,
            "projectIdentifier": projectIdentifier, "worktreeIdentifier": worktreeIdentifier,
            "preview": preview, "viewState": viewState.dictionary, "kind": kind]
        if let documentIdentifier { result["documentIdentifier"] = documentIdentifier }
        return result
    }
    var context: iTermFileBrowserContext {
        iTermFileBrowserContext(rootDirectory: rootDirectory, projectIdentifier: projectIdentifier,
                                worktreeIdentifier: worktreeIdentifier, generation: 0)
    }
    private static func validPath(_ path: String) -> Bool {
        (path as NSString).isAbsolutePath && !path.contains("\0") && path.utf8.count <= 32768
    }
}

/// File admission uses points, not the terminal splitter's historical cell-size heuristic.
@objcMembers final class iTermFilePaneGeometry: NSObject {
    static func canSplit(size: NSSize, targetMinimum: NSSize, fileMinimum: NSSize, divider: CGFloat, vertical: Bool) -> Bool {
        let values = [size.width, size.height, targetMinimum.width, targetMinimum.height,
                      fileMinimum.width, fileMinimum.height, divider]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        if vertical {
            return size.width >= targetMinimum.width + fileMinimum.width + divider &&
                size.height >= max(targetMinimum.height, fileMinimum.height)
        }
        return size.height >= targetMinimum.height + fileMinimum.height + divider &&
            size.width >= max(targetMinimum.width, fileMinimum.width)
    }
}
