import Foundation

// A view owns this session. Queued reads retain their original path authority.
final class FileUIHostSession {
    private let queue = DispatchQueue(label: "com.iterm2.file-ui.host", qos: .userInitiated)
    private let context: iTermFileBrowserContext?
    private let workspace: FileContentService?
    private var document: iTermFileDocumentSnapshot
    private let documentFiles: FileContentService?
    init(context: iTermFileBrowserContext?, document: iTermFileDocumentSnapshot) {
        self.context = context; self.document = document
        workspace = context.flatMap { try? FileContentService(rootDirectory: $0.rootDirectory) }
        documentFiles = try? FileContentService(rootDirectory: (document.canonicalPath as NSString).deletingLastPathComponent)
    }
    func update(_ snapshot: iTermFileDocumentSnapshot) { document = snapshot }
    func path(_ value: Any?) throws -> String {
        guard let input = value as? String, !input.contains("\0"), input.utf8.count <= 16384 else { throw fileBrowserError(2) }
        let base = context?.rootDirectory ?? (document.filePath as NSString).deletingLastPathComponent
        let path = (input as NSString).isAbsolutePath ? input : (base as NSString).appendingPathComponent(input)
        let normalized = (path as NSString).standardizingPath
        if normalized == document.filePath || normalized == document.canonicalPath { return normalized }
        guard let workspace else { throw fileBrowserError(2) }
        _ = try workspace.root.relative(normalized)
        return normalized
    }
    func openPath(_ value: Any?) throws -> String {
        let path = try self.path(value)
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if (path == document.filePath || path == document.canonicalPath) && target == document.canonicalPath { return path }
        guard let workspace else { throw fileBrowserError(2) }
        _ = try workspace.root.checked(path)
        let root = workspace.root.canonical
        guard target == root || target.hasPrefix(root == "/" ? "/" : root + "/") else { throw fileBrowserError(2) }
        return path
    }
    func readScope(for path: String) -> FileDocumentReadScope? {
        if let workspace, document.canonicalPath.hasPrefix(workspace.root.canonical == "/" ? "/" : workspace.root.canonical + "/") {
            return FileDocumentReadScope(root: workspace.root, canonicalPath: nil)
        }
        if path == document.filePath || path == document.canonicalPath, let documentFiles {
            return FileDocumentReadScope(root: documentFiles.root, canonicalPath: document.canonicalPath)
        }
        return workspace.map { FileDocumentReadScope(root: $0.root, canonicalPath: nil) }
    }
    var ownerIdentifier: String {
        let parts = [context?.rootDirectory ?? "", context?.projectIdentifier ?? "", context?.worktreeIdentifier ?? ""]
        return String(data: (try? JSONSerialization.data(withJSONObject: parts)) ?? Data(), encoding: .utf8) ?? ""
    }
    func read(_ operation: String, args: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        let snapshot = document
        do {
            let requested = try path(args["path"] ?? args["directoryPath"] ?? snapshot.filePath)
            let ownDocument = requested == snapshot.filePath || requested == snapshot.canonicalPath
            let path = ownDocument ? snapshot.canonicalPath : requested
            guard let files = ownDocument ? documentFiles : workspace else { throw fileBrowserError(2) }
            let root = workspace?.root.display
            queue.async {
                let result: Result<Any, Error> = Result {
                    switch operation {
                    case "stat": return try files.metadata(path)
                    case "readText":
                        if ownDocument, let text = snapshot.text { return ["content": text, "byteLength": snapshot.byteCount] as [String: Any] }
                        return try files.readText(path)
                    case "readRange":
                        guard let position = fileUIInteger(args["position"], maximum: Int.max - FileContentService.maximumRangeBytes),
                              let length = fileUIInteger(args["length"], minimum: 1, maximum: FileContentService.maximumRangeBytes) else { throw fileBrowserError(2) }
                        return try files.readRange(path, position: Int64(position), length: length)
                    case "listMarkdownDocuments":
                        guard let workspace = self.workspace else { throw fileBrowserError(2) }
                        return try workspace.markdownDocuments(requested)
                    case "gitDiff", "gitStatus", "gitChanges":
                        guard let root else { throw fileBrowserError(2) }
                        let git = try FileGitContentService(rootDirectory: root)
                        if operation == "gitStatus" { return try git.status() }
                        let source = args["source"] as? String ?? "head"
                        let base = args["baseRef"] as? String, commit = args["commit"] as? String
                        if operation == "gitChanges" { return try git.changes(source: source, baseRef: base, commit: commit) }
                        return try git.diff(requested, source: source, baseRef: base, commit: commit)
                    default: throw fileBrowserError(2)
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }
        } catch { completion(.failure(error)) }
    }
}
