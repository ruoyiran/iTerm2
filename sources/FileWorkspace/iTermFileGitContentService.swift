import Foundation
import Darwin

// Read-only Git adapters emit the Orca renderer's file/status contracts.
final class FileGitContentService {
    private let content: FileContentService
    private let repository: String
    private let root: FileBrowserRoot
    private let ownerFiles: FileContentService
    private let prefix: String
    private static let maximumDiffBytes = 10 * 1024 * 1024

    init(rootDirectory: String) throws {
        root = try FileBrowserRoot(rootDirectory)
        let result = try fileBrowserGit(["rev-parse", "--show-toplevel"], root: root.canonical)
        guard result.0 == 0, let path = String(data: result.1, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !path.isEmpty else { throw fileBrowserError(5) }
        repository = URL(fileURLWithPath: path).standardizedFileURL.path
        content = try FileContentService(rootDirectory: repository)
        ownerFiles = try FileContentService(rootDirectory: rootDirectory)
        let relative = try content.root.relative(root.canonical)
        prefix = relative.isEmpty ? "" : relative + "/"
    }
    private func git(_ arguments: [String]) throws -> Data {
        // Reject root replacement before executing in a path supplied by a web renderer.
        let descriptor = try root.openDirectory(root.display); Darwin.close(descriptor)
        let result = try fileBrowserGit(["-c", "diff.external=", "-c", "core.pager=cat"] + arguments,
                                        root: repository, timeout: 10)
        guard result.0 == 0 else { throw fileBrowserError(5) }
        return result.1
    }
    private func commit(_ reference: String) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 1024, !reference.hasPrefix("-"),
              !reference.contains("\0"), !reference.contains("\n") else { throw fileBrowserError(2) }
        let data = try git(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"])
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              [40, 64].contains(value.count), value.allSatisfy({ $0.isHexDigit }) else { throw fileBrowserError(5) }
        return value
    }
    private func head() -> String? { try? commit("HEAD") }
    private func comparison(_ source: String, baseRef: String?, commit requested: String?) throws -> (String?, String?) {
        switch source {
        case "head": return (head(), nil)
        case "staged", "unstaged": return (head(), nil)
        case "branch":
            let base = try commit(baseRef ?? "HEAD")
            guard let head = head() else { return (nil, nil) }
            let data = try git(["merge-base", head, base])
            guard let ancestor = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) else { throw fileBrowserError(5) }
            return (ancestor, nil)
        case "commit":
            let target = try commit(requested ?? baseRef ?? "HEAD")
            return (try? commit(target + "^"), target)
        default: throw fileBrowserError(2)
        }
    }
    private func differenceArguments(_ source: String, original: String?, modified: String?) -> [String] {
        var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--name-status", "-z"]
        if source == "staged" { arguments.append("--cached") }
        if source != "unstaged", let original { arguments.append(original) }
        if let modified {
            if original == nil { return ["diff-tree", "--root", "--no-commit-id", "-r", "--find-renames", "--name-status", "-z", modified, "--"] }
            arguments.append(modified)
        }
        arguments.append("--")
        return arguments
    }
    private func statusName(_ code: Character) -> String {
        switch code {
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        case "?": return "untracked"
        default: return "modified"
        }
    }
    func status() throws -> [[String: Any]] {
        try scoped(try repositoryStatus())
    }
    private func repositoryStatus() throws -> [[String: Any]] {
        let data = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard let text = String(data: data, encoding: .utf8) else { throw fileBrowserError(5) }
        let fields = text.components(separatedBy: "\0")
        var index = 0, entries = [[String: Any]]()
        while index < fields.count {
            let field = fields[index]; index += 1
            if field.isEmpty { continue }
            guard field.utf8.count >= 4 else { throw fileBrowserError(5) }
            let chars = Array(field.prefix(2)), path = String(field.dropFirst(3))
            var oldPath: String?
            if chars.contains("R") || chars.contains("C") {
                guard index < fields.count else { throw fileBrowserError(5) }; oldPath = fields[index]; index += 1
            }
            for (code, area) in [(chars[0], "staged"), (chars[1], "unstaged")] where code != " " && code != "!" {
                if code == "?" && area == "unstaged" { continue }
                var entry: [String: Any] = ["path": path, "status": statusName(code), "area": code == "?" ? "untracked" : area]
                if let oldPath { entry["oldPath"] = oldPath }
                let pair = String(chars)
                if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair) {
                    let conflicts = ["DD": "both_deleted", "AU": "added_by_us", "UD": "deleted_by_them", "UA": "added_by_them", "DU": "deleted_by_us", "AA": "both_added", "UU": "both_modified"]
                    entry["conflictKind"] = conflicts[pair]; entry["conflictStatus"] = "unresolved"; entry["conflictStatusSource"] = "git"
                }
                entries.append(entry)
            }
        }
        return entries
    }
    func changes(source: String, baseRef: String? = nil, commit requested: String? = nil) throws -> [[String: Any]] {
        try scoped(try repositoryChanges(source: source, baseRef: baseRef, commit: requested))
    }
    private func repositoryChanges(source: String, baseRef: String? = nil, commit requested: String? = nil) throws -> [[String: Any]] {
        let pair = try comparison(source, baseRef: baseRef, commit: requested)
        let fields = String(data: try git(differenceArguments(source, original: pair.0, modified: pair.1)), encoding: .utf8)?.components(separatedBy: "\0")
        guard let fields else { throw fileBrowserError(5) }
        var index = 0, entries = [[String: Any]]()
        while index < fields.count, !fields[index].isEmpty {
            guard let code = fields[index].first, index + 1 < fields.count else { throw fileBrowserError(5) }
            var path = fields[index + 1], oldPath: String?; index += 2
            if code == "R" || code == "C" {
                guard index < fields.count else { throw fileBrowserError(5) }
                oldPath = path; path = fields[index]; index += 1
            }
            var entry: [String: Any] = ["path": path, "status": statusName(code)]
            if let oldPath { entry["oldPath"] = oldPath }; entries.append(entry)
        }
        if source == "head" || source == "unstaged" || source == "branch" {
            for item in try repositoryStatus() where item["area"] as? String == "untracked" || (source == "head" && pair.0 == nil) {
                if !entries.contains(where: { $0["path"] as? String == item["path"] as? String }) { entries.append(item) }
            }
        }
        return entries
    }
    private func scoped(_ entries: [[String: Any]]) throws -> [[String: Any]] {
        entries.compactMap { entry in
            guard let path = entry["path"] as? String else { return nil }
            var value = entry
            let oldPath = entry["oldPath"] as? String
            if prefix.isEmpty || path.hasPrefix(prefix) {
                value["path"] = String(path.dropFirst(prefix.count))
                if let oldPath {
                    if prefix.isEmpty || oldPath.hasPrefix(prefix) { value["oldPath"] = String(oldPath.dropFirst(prefix.count)) }
                    else { value.removeValue(forKey: "oldPath"); value["status"] = "added" }
                }
                return value
            }
            if let oldPath, oldPath.hasPrefix(prefix) {
                value["path"] = String(oldPath.dropFirst(prefix.count)); value["status"] = "deleted"; value.removeValue(forKey: "oldPath")
                return value
            }
            return nil
        }
    }
    private func blob(_ tree: String, path: String) throws -> Data {
        let result = try fileBrowserGit(["show", "--no-ext-diff", "--no-textconv", tree + ":" + path], root: repository, timeout: 10)
        if result.0 != 0 {
            let existence = try git(["ls-tree", "-z", tree, "--", path])
            if existence.isEmpty { return Data() }
            throw fileBrowserError(5)
        }
        guard result.1.count <= Self.maximumDiffBytes else { throw fileBrowserError(8) }
        return result.1
    }
    private func indexBlob(_ path: String) throws -> Data {
        let result = try fileBrowserGit(["show", ":" + path], root: repository, timeout: 10)
        if result.0 != 0 {
            if try git(["ls-files", "--stage", "-z", "--", path]).isEmpty { return Data() }
            throw fileBrowserError(5)
        }
        guard result.1.count <= Self.maximumDiffBytes else { throw fileBrowserError(8) }
        return result.1
    }
    func diff(_ path: String, source: String, baseRef: String? = nil, commit requested: String? = nil) throws -> [String: Any] {
        do { return try readDiff(path, source: source, baseRef: baseRef, commit: requested) }
        catch let error as NSError where error.domain == "iTermFileBrowser" && error.code == 8 {
            return ["kind": "binary", "originalContent": "", "modifiedContent": "", "originalIsBinary": true,
                    "modifiedIsBinary": true, "tooLarge": true]
        }
    }
    private func readDiff(_ path: String, source: String, baseRef: String?, commit requested: String?) throws -> [String: Any] {
        let ownerRelative = try root.relative(path)
        let relative = prefix + ownerRelative
        let pair = try comparison(source, baseRef: baseRef, commit: requested)
        let change = try repositoryChanges(source: source, baseRef: baseRef, commit: requested).first { $0["path"] as? String == relative || $0["oldPath"] as? String == relative }
        let oldPath = change?["oldPath"] as? String ?? relative
        let original = try source == "unstaged" ? indexBlob(relative) : (prefix.isEmpty || oldPath.hasPrefix(prefix) ? pair.0.map { try blob($0, path: oldPath) } ?? Data() : Data())
        let modified: Data
        var deleted = false
        let renamedAway = change?["oldPath"] as? String == relative && change?["path"] as? String != relative
        if source == "staged" { modified = try indexBlob(relative); deleted = change?["status"] as? String == "deleted" || renamedAway }
        else if let target = pair.1 { modified = try blob(target, path: relative); deleted = change?["status"] as? String == "deleted" || renamedAway }
        else {
            do {
                modified = try ownerFiles.root.withParent(path) { parent, name in
                    var info = stat()
                    guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    guard info.st_size <= Self.maximumDiffBytes else { throw fileBrowserError(8) }
                    if info.st_mode & S_IFMT == S_IFLNK {
                        var buffer = [UInt8](repeating: 0, count: 16385)
                        let count = readlinkat(parent, name, &buffer, buffer.count)
                        guard count >= 0, count < buffer.count else { throw fileBrowserError(5) }
                        return Data(buffer.prefix(count))
                    }
                    return try ownerFiles.readBytes(path, maximum: Self.maximumDiffBytes)
                }
            }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { modified = Data(); deleted = true }
        }
        let originalText = FileTextFormat.decode(original)?.0, modifiedText = FileTextFormat.decode(modified)?.0
        if let originalText, let modifiedText {
            return ["kind": "text", "originalContent": originalText, "modifiedContent": modifiedText,
                    "originalIsBinary": false, "modifiedIsBinary": false]
        }
        let mime = FileContentService.mimeType(path)
        let previewable = mime.hasPrefix("image/") || mime == "application/pdf"
        return ["kind": "binary", "originalContent": previewable ? original.base64EncodedString() : "",
                "modifiedContent": previewable ? modified.base64EncodedString() : "", "originalIsBinary": originalText == nil,
                "modifiedIsBinary": modifiedText == nil, "isImage": previewable, "mimeType": mime, "modifiedDeleted": deleted]
    }
}
