import Foundation
import Darwin

@objcMembers final class iTermFileBrowserContext: NSObject {
    let rootDirectory: String
    let projectIdentifier: String
    let worktreeIdentifier: String
    let generation: UInt64
    let showsHiddenFiles: Bool
    let showsGitIgnoredFiles: Bool
    init(rootDirectory: String, projectIdentifier: String, worktreeIdentifier: String, generation: UInt64,
         showsHiddenFiles: Bool = false, showsGitIgnoredFiles: Bool = false) {
        self.rootDirectory = rootDirectory; self.projectIdentifier = projectIdentifier
        self.worktreeIdentifier = worktreeIdentifier; self.generation = generation
        self.showsHiddenFiles = showsHiddenFiles; self.showsGitIgnoredFiles = showsGitIgnoredFiles
    }
}
@objcMembers final class iTermFileBrowserEntry: NSObject {
    let path: String
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isExpandable: Bool
    init(path: String, relativePath: String, isDirectory: Bool, isSymbolicLink: Bool) {
        self.path = path; self.relativePath = relativePath; name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink
        isExpandable = isDirectory && !isSymbolicLink
    }
}
@objcMembers final class iTermFileContentQuery: NSObject {
    let text: String
    let regularExpression: Bool
    let caseSensitive: Bool
    let wholeWord: Bool
    let includeGlobs: [String]
    let excludeGlobs: [String]
    init(text: String, regularExpression: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false,
         includeGlobs: [String] = [], excludeGlobs: [String] = []) {
        self.text = text; self.regularExpression = regularExpression; self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord; self.includeGlobs = includeGlobs; self.excludeGlobs = excludeGlobs
    }
}
@objcMembers final class iTermFileContentLine: NSObject {
    let lineNumber: Int
    let snippet: String
    let ranges: [NSValue]
    let snippetColumn: Int
    init(lineNumber: Int, snippet: String, ranges: [NSValue], snippetColumn: Int = 0) {
        self.lineNumber = lineNumber; self.snippet = snippet; self.ranges = ranges; self.snippetColumn = snippetColumn
    }
}
@objcMembers final class iTermFileContentMatch: NSObject {
    let path: String
    let relativePath: String
    let lines: [iTermFileContentLine]
    init(path: String, relativePath: String, lines: [iTermFileContentLine]) {
        self.path = path; self.relativePath = relativePath; self.lines = lines
    }
}
@objcMembers final class iTermFileSearchBatch: NSObject {
    let requestIdentifier: String
    let context: iTermFileBrowserContext
    let entries: [iTermFileBrowserEntry]
    let matches: [iTermFileContentMatch]
    let isComplete: Bool
    let isTruncated: Bool
    let skippedFileCount: Int
    let error: NSError?
    init(requestIdentifier: String, context: iTermFileBrowserContext, entries: [iTermFileBrowserEntry] = [],
         matches: [iTermFileContentMatch] = [], isComplete: Bool, isTruncated: Bool = false,
         skippedFileCount: Int = 0, error: NSError? = nil) {
        self.requestIdentifier = requestIdentifier; self.context = context; self.entries = entries
        self.matches = matches; self.isComplete = isComplete; self.isTruncated = isTruncated
        self.skippedFileCount = skippedFileCount; self.error = error
    }
}
@objcMembers final class iTermFilePathMapping: NSObject {
    let oldPath: String?
    let newPath: String?
    let isDirectory: Bool
    let trashPath: String?
    init(oldPath: String?, newPath: String?, isDirectory: Bool, trashPath: String? = nil) {
        self.oldPath = oldPath; self.newPath = newPath; self.isDirectory = isDirectory; self.trashPath = trashPath
    }
}
@objcMembers final class iTermFileOperationResult: NSObject {
    let context: iTermFileBrowserContext
    let mappings: [iTermFilePathMapping]
    let canUndo: Bool
    let canRedo: Bool
    let error: NSError?
    init(context: iTermFileBrowserContext, mappings: [iTermFilePathMapping], canUndo: Bool, canRedo: Bool, error: NSError?) {
        self.context = context; self.mappings = mappings; self.canUndo = canUndo; self.canRedo = canRedo; self.error = error
    }
}
// Mutable cache/history belong to one utility worker; context and cancellation use a short lock.
@objcMembers final class iTermFileBrowserService: NSObject {
    static let maximumFileBytes = 10 * 1024 * 1024
    static let maximumSearchResults = 5000
    private let worker = DispatchQueue(label: "com.iterm2.file-browser", qos: .utility)
    private let lock = NSLock()
    private var active: iTermFileBrowserContext?
    private var requests = Set<String>()
    private var cacheContext: iTermFileBrowserContext?
    private var cache = [String: [iTermFileBrowserEntry]]()
    private var gitRepository: Bool?
    private var capturedRoot: FileBrowserRoot?
    private var history = [String: FileBrowserHistory]()

    func activate(_ context: iTermFileBrowserContext) {
        lock.lock(); active = context; requests.removeAll(); lock.unlock()
    }
    @nonobjc private func isCurrent(_ context: iTermFileBrowserContext, request: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active === context && (request == nil || requests.contains(request!))
    }
    @nonobjc private func prepare(_ context: iTermFileBrowserContext) throws -> FileBrowserRoot {
        guard isCurrent(context) else { throw fileBrowserError(1) }
        if cacheContext !== context {
            cacheContext = context; cache.removeAll(); gitRepository = nil
            capturedRoot = nil
            capturedRoot = try FileBrowserRoot(context.rootDirectory)
        }
        guard let root = capturedRoot else { throw fileBrowserError(9) }
        let descriptor = try root.openDirectory(root.display); close(descriptor)
        return root
    }
    func invalidate(_ context: iTermFileBrowserContext, directoryPaths: [String]) {
        worker.async { [weak self] in
            guard let self, self.cacheContext === context else { return }
            self.gitRepository = nil
            // Ancestor directories stay cached, but DFS visits the invalidated subtree anew.
            for path in directoryPaths {
                for key in self.cache.keys where key == path || key.hasPrefix(path + "/") { self.cache.removeValue(forKey: key) }
            }
        }
    }
    @nonobjc private func entries(_ path: String, root: FileBrowserRoot, context: iTermFileBrowserContext, request: String? = nil) throws -> [iTermFileBrowserEntry] {
        if let value = cache[path] { return value }
        _ = try root.checked(path, directory: true)
        var entries = [iTermFileBrowserEntry]()
        for (name, identity, hidden) in try root.children(path) {
            let child = (path as NSString).appendingPathComponent(name)
            guard identity.regular || identity.directory || identity.symlink else { continue }
            if !context.showsHiddenFiles && (hidden || name.hasPrefix(".")) { continue }
            entries.append(iTermFileBrowserEntry(path: child, relativePath: try root.relative(child),
                                                isDirectory: identity.directory, isSymbolicLink: identity.symlink))
        }
        if !context.showsGitIgnoredFiles && !entries.isEmpty {
            if gitRepository == nil { gitRepository = try fileBrowserGit(["rev-parse", "--is-inside-work-tree"], root: root.canonical, isCancelled: { !self.isCurrent(context, request: request) }).0 == 0 }
            if gitRepository == true {
                var input = Data()
                for entry in entries { input.append(contentsOf: entry.relativePath.utf8); input.append(0) }
                let (status, output) = try fileBrowserGit(["check-ignore", "--stdin", "-z"], root: root.canonical, input: input, isCancelled: { !self.isCurrent(context, request: request) })
                guard status == 0 || status == 1 else { throw fileBrowserError(8) }
                let ignored = Set(output.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
                entries.removeAll { ignored.contains($0.relativePath) }
            }
        }
        entries.sort {
            if $0.isExpandable != $1.isExpandable { return $0.isExpandable }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
        cache[path] = entries
        return entries
    }
    func listDirectory(atPath path: String, context: iTermFileBrowserContext,
                       completion: @escaping ([iTermFileBrowserEntry]?, NSError?) -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            let values: [iTermFileBrowserEntry]?
            let error: NSError?
            do { values = try self.entries(path, root: self.prepare(context), context: context); error = nil }
            catch let failure { values = nil; error = failure as NSError }
            DispatchQueue.main.async {
                guard self.isCurrent(context) else { completion(nil, fileBrowserError(1)); return }
                completion(values, error)
            }
        }
    }
    @nonobjc private func begin(_ context: iTermFileBrowserContext) -> String {
        let id = UUID().uuidString
        lock.lock(); if active === context { requests.insert(id) }; lock.unlock()
        return id
    }
    func cancel(_ requestIdentifier: String) {
        lock.lock(); requests.remove(requestIdentifier); lock.unlock()
    }
    @nonobjc private func publish(_ value: iTermFileSearchBatch, callback: @escaping (iTermFileSearchBatch) -> Void) {
        DispatchQueue.main.async {
            guard self.isCurrent(value.context, request: value.requestIdentifier) else { return }
            if value.isComplete { self.cancel(value.requestIdentifier) }
            callback(value)
        }
    }
    @nonobjc private func walk(_ root: FileBrowserRoot, context: iTermFileBrowserContext, id: String,
                              visit: (iTermFileBrowserEntry) throws -> Bool) throws {
        var pending = [root.display]
        while let directory = pending.popLast() {
            guard isCurrent(context, request: id) else { throw fileBrowserError(1) }
            let children: [iTermFileBrowserEntry]
            do { children = try entries(directory, root: root, context: context, request: id) }
            catch { if directory == root.display { throw error }; continue }
            for child in children {
                guard isCurrent(context, request: id) else { throw fileBrowserError(1) }
                if try !visit(child) { return }
            }
            pending.append(contentsOf: children.filter(\.isExpandable).reversed().map(\.path))
        }
    }
    @discardableResult func searchNames(_ query: String, context: iTermFileBrowserContext,
                                        batch: @escaping (iTermFileSearchBatch) -> Void) -> String {
        let id = begin(context)
        worker.async { [weak self] in
            guard let self else { return }
            var pending = [iTermFileBrowserEntry](); var count = 0; var truncated = false; var error: NSError?
            do {
                guard query.utf8.count <= 2048 else { throw fileBrowserError(6) }
                let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
                try self.walk(self.prepare(context), context: context, id: id) { entry in
                    guard tokens.allSatisfy({ entry.relativePath.lowercased().contains($0) }) else { return true }
                    if count == Self.maximumSearchResults { truncated = true; return false }
                    pending.append(entry); count += 1
                    if pending.count == 128 {
                        self.publish(iTermFileSearchBatch(requestIdentifier: id, context: context, entries: pending, isComplete: false), callback: batch)
                        pending.removeAll(keepingCapacity: true)
                    }
                    return true
                }
            } catch let failure { error = failure as NSError }
            self.publish(iTermFileSearchBatch(requestIdentifier: id, context: context, entries: pending, isComplete: true,
                                             isTruncated: truncated, error: error), callback: batch)
        }
        return id
    }
    @discardableResult func searchContents(_ query: iTermFileContentQuery, context: iTermFileBrowserContext,
                                           batch: @escaping (iTermFileSearchBatch) -> Void) -> String {
        let id = begin(context)
        worker.async { [weak self] in
            guard let self else { return }
            var pending = [iTermFileContentMatch](); var count = 0; var skipped = 0; var truncated = false; var error: NSError?
            do {
                guard query.text.utf8.count <= 2048, !query.text.isEmpty,
                      query.includeGlobs.count + query.excludeGlobs.count <= 128 else { throw fileBrowserError(6) }
                var pattern = query.regularExpression ? query.text : NSRegularExpression.escapedPattern(for: query.text)
                if query.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])" }
                let regex = try NSRegularExpression(pattern: pattern, options: query.caseSensitive ? [] : [.caseInsensitive])
                let includes = try query.includeGlobs.map(fileBrowserGlob)
                let excludes = try query.excludeGlobs.map(fileBrowserGlob)
                let root = try self.prepare(context)
                try self.walk(root, context: context, id: id) { entry in
                    if entry.isDirectory { return true }
                    if entry.isSymbolicLink { skipped += 1; return true }
                    var remainingWork = 4_000_000
                    let cancelled = { !self.isCurrent(context, request: id) }
                    var included = includes.isEmpty
                    for glob in includes {
                        if try glob.matches(entry.relativePath, isCancelled: cancelled, remainingWork: &remainingWork) { included = true; break }
                    }
                    var excluded = false
                    for glob in excludes {
                        if try glob.matches(entry.relativePath, isCancelled: cancelled, remainingWork: &remainingWork) { excluded = true; break }
                    }
                    if !included || excluded { return true }
                    let text: String
                    do { text = try fileBrowserReadText(entry.path, root: root, maximumBytes: Self.maximumFileBytes) }
                    catch { skipped += 1; return true }
                    var lines = [iTermFileContentLine](); var lineNumber = 0
                    text.enumerateLines { line, stop in
                        lineNumber += 1
                        guard self.isCurrent(context, request: id) else { stop = true; return }
                        var ranges = [NSValue]()
                        regex.enumerateMatches(in: line, options: [.reportProgress], range: NSRange(location: 0, length: line.utf16.count)) { match, _, stopMatching in
                            if !self.isCurrent(context, request: id) { stopMatching.pointee = true; return }
                            guard let match else { return }
                            if count == Self.maximumSearchResults { truncated = true; stopMatching.pointee = true; return }
                            // Zero-length regex matches cannot navigate to a character; skip them.
                            guard match.range.length > 0 else { return }
                            ranges.append(NSValue(range: match.range)); count += 1
                        }
                        if !ranges.isEmpty {
                            // Center the bounded snippet on the first match. Ranges retain full-line UTF16 coordinates.
                            let source = line as NSString
                            let start = max(0, ranges[0].rangeValue.location - 128)
                            var offset = start
                            if offset > 0, (0xdc00...0xdfff).contains(source.character(at: offset)) { offset -= 1 }
                            var length = min(1024, source.length - offset)
                            if length > 0, (0xd800...0xdbff).contains(source.character(at: offset + length - 1)) { length -= 1 }
                            let range = NSRange(location: offset, length: length)
                            let snippet = source.substring(with: range)
                            lines.append(iTermFileContentLine(lineNumber: lineNumber, snippet: snippet,
                                                              ranges: ranges, snippetColumn: range.location))
                        }
                        if lines.count == 128 {
                            pending.append(iTermFileContentMatch(path: entry.path, relativePath: entry.relativePath, lines: lines))
                            self.publish(iTermFileSearchBatch(requestIdentifier: id, context: context, matches: pending, isComplete: false,
                                                             skippedFileCount: skipped), callback: batch)
                            pending.removeAll(keepingCapacity: true); lines.removeAll(keepingCapacity: true)
                        }
                        if truncated { stop = true }
                    }
                    if !lines.isEmpty { pending.append(iTermFileContentMatch(path: entry.path, relativePath: entry.relativePath, lines: lines)) }
                    if pending.count >= 16 {
                        self.publish(iTermFileSearchBatch(requestIdentifier: id, context: context, matches: pending, isComplete: false,
                                                         skippedFileCount: skipped), callback: batch)
                        pending.removeAll(keepingCapacity: true)
                    }
                    return !truncated
                }
            } catch let failure { error = failure as NSError }
            self.publish(iTermFileSearchBatch(requestIdentifier: id, context: context, matches: pending, isComplete: true,
                                             isTruncated: truncated, skippedFileCount: skipped, error: error), callback: batch)
        }
        return id
    }

    @nonobjc private func historyKey(_ context: iTermFileBrowserContext) -> String {
        [context.projectIdentifier, context.worktreeIdentifier, context.rootDirectory].map { "\($0.utf8.count):\($0)" }.joined()
    }
    @nonobjc private func mutate(_ context: iTermFileBrowserContext, historyDirection: Int = 0,
                                completion: @escaping (iTermFileOperationResult) -> Void,
                                makeSteps: @escaping (FileBrowserRoot) throws -> [FileBrowserStep]) {
        worker.async { [weak self] in
            guard let self else { return }
            var mappings = [iTermFilePathMapping](); var inverse = [FileBrowserStep](); var error: NSError?
            var plannedSteps = [FileBrowserStep](); var completedSteps = 0
            let key = self.historyKey(context)
            var journal = self.history[key] ?? FileBrowserHistory()
            do {
                let root = try self.prepare(context)
                let steps: [FileBrowserStep]
                if historyDirection < 0 { guard let previous = journal.undo.last else { throw fileBrowserError(7) }; steps = previous }
                else if historyDirection > 0 { guard let previous = journal.redo.last else { throw fileBrowserError(7) }; steps = previous }
                else { steps = try makeSteps(root) }
                plannedSteps = steps
                try self.preflight(steps, root: root)
                // Authorization is captured once, immediately before the first native mutation. A root
                // switch after authorization cannot suppress mappings for changes that already happened.
                guard self.isCurrent(context) else { throw fileBrowserError(1) }
                for step in steps {
                    do {
                        let result = try self.execute(step, root: root)
                        if let undo = result.0 { inverse.insert(undo, at: 0) }; mappings.append(result.1); completedSteps += 1
                    } catch let partial as FileBrowserPartialMutation {
                        if let undo = partial.inverse { inverse.insert(undo, at: 0) }; mappings.append(partial.mapping); completedSteps += 1
                        throw partial.underlying
                    }
                }
                if historyDirection < 0 { journal.undo.removeLast(); if !inverse.isEmpty { journal.redo.append(inverse) } }
                else if historyDirection > 0 { journal.redo.removeLast(); if !inverse.isEmpty { journal.undo.append(inverse) } }
                else if !mappings.isEmpty { if !inverse.isEmpty { journal.undo.append(inverse) }; journal.redo.removeAll() }
            } catch let failure {
                error = failure as NSError
                // Keep only unexecuted suffixes in the original history; successful prefixes remain reversible.
                if !mappings.isEmpty {
                    let remaining = Array(plannedSteps.dropFirst(completedSteps))
                    if historyDirection < 0 {
                        journal.undo.removeLast()
                        if !remaining.isEmpty { journal.undo.append(remaining) }
                        if !inverse.isEmpty { journal.redo.append(inverse) }
                    } else if historyDirection > 0 {
                        journal.redo.removeLast()
                        if !remaining.isEmpty { journal.redo.append(remaining) }
                        if !inverse.isEmpty { journal.undo.append(inverse) }
                    } else { if !inverse.isEmpty { journal.undo.append(inverse) }; journal.redo.removeAll() }
                }
            }
            self.history[key] = journal
            if !mappings.isEmpty { self.cache.removeAll(); self.gitRepository = nil }
            let result = iTermFileOperationResult(context: context, mappings: mappings, canUndo: !journal.undo.isEmpty,
                                                 canRedo: !journal.redo.isEmpty, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }
    @nonobjc private func source(_ path: String, root: FileBrowserRoot) throws -> FileBrowserIdentity {
        guard path != root.display else { throw fileBrowserError(2) }
        let native = try root.checked(path, writableParent: true)
        let item = try FileBrowserIdentity.read(native)
        guard item.regular || item.directory || item.symlink else { throw fileBrowserError(5) }
        return item
    }
    @nonobjc private func preflight(_ steps: [FileBrowserStep], root: FileBrowserRoot) throws {
        let sources = steps.compactMap(\.source)
        let destinations = steps.compactMap(\.destination)
        guard Set(sources).count == sources.count, Set(destinations).count == destinations.count else { throw fileBrowserError(3) }
        for a in sources { for b in sources where a != b && b.hasPrefix(a + "/") { throw fileBrowserError(2) } }
        for step in steps {
            if let source = step.source, let expected = step.identity {
                let actual = try FileBrowserIdentity.read(step.trashSource ? source : root.checked(source, writableParent: true))
                guard expected.sameItem(actual) else { throw fileBrowserError(9) }
                if let destination = step.destination, actual.directory && destination.hasPrefix(source + "/") { throw fileBrowserError(2) }
            }
            if let destination = step.destination {
                _ = try root.destination(inDirectory: (destination as NSString).deletingLastPathComponent,
                                         name: (destination as NSString).lastPathComponent)
            }
        }
    }
    @nonobjc private func committed(_ result: (FileBrowserStep?, iTermFilePathMapping), root: FileBrowserRoot,
                                   expected: FileBrowserIdentity, error: NSError? = nil) throws -> (FileBrowserStep?, iTermFilePathMapping) {
        do {
#if FILE_BROWSER_TESTING
            try FileBrowserFaultGate.committed?(result.1.oldPath == nil ? "create" : "move", result.1.oldPath, result.1.newPath)
#endif
            if let error { throw error }
            if let path = result.1.newPath {
                guard expected.sameItem(try FileBrowserIdentity.read(root.checked(path))) else { throw fileBrowserError(9) }
            }
        } catch {
            throw FileBrowserPartialMutation(inverse: result.0, mapping: result.1, underlying: error as NSError)
        }
        return result
    }
    @nonobjc private func execute(_ step: FileBrowserStep, root: FileBrowserRoot) throws -> (FileBrowserStep?, iTermFilePathMapping) {
        try preflight([step], root: root)
        switch step.kind {
        case .createFile, .createFolder, .copy:
            let display = step.destination!
            _ = try root.checked(display, writableParent: true)
            let identity: FileBrowserIdentity = try root.withParent(display) { parent, name in
                let staging = ".file-browser-create-" + UUID().uuidString
                let directory = step.kind == .createFolder
                let output: Int32
                if directory {
                    guard mkdirat(parent, staging, 0o755) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    output = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                } else { output = openat(parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, step.kind == .copy ? 0o600 : 0o644) }
                defer { if output >= 0 { close(output) }; unlinkat(parent, staging, directory ? AT_REMOVEDIR : 0) }
                guard output >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if step.kind == .copy {
                    try root.withParent(step.source!) { sourceParent, sourceName in
                        let source = openat(sourceParent, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                        guard source >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                        defer { close(source) }
                        var info = stat()
                        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                              UInt64(info.st_dev) == step.identity!.device, UInt64(info.st_ino) == step.identity!.inode,
                              info.st_mode & 0o444 != 0 else { throw fileBrowserError(9) }
                        guard fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                }
                // Bind history before publishing. Any failure here affects only the owned staging object.
                var info = stat()
                guard fstat(output, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let identity = FileBrowserIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), mode: info.st_mode, size: info.st_size)
                guard renameatx_np(parent, staging, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return identity
            }
            return try committed((FileBrowserStep(kind: .trash, source: display, identity: identity),
                                  iTermFilePathMapping(oldPath: nil, newPath: display, isDirectory: identity.directory)),
                                 root: root, expected: identity)
        case .move:
            let source = step.source!, destination = step.destination!, expected = step.identity!
            let from = step.trashSource ? source : try root.checked(source, writableParent: true)
            _ = try root.checked(destination, writableParent: true)
            try root.withParent(destination) { toParent, toName in
                let relocate: (Int32, String) throws -> Void = { fromParent, fromName in
                    var info = stat()
                    guard fstatat(fromParent, fromName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          UInt64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode else { throw fileBrowserError(9) }
                    guard renameatx_np(fromParent, fromName, toParent, toName, UInt32(RENAME_EXCL)) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
                if step.trashSource {
                    guard expected.sameItem(try FileBrowserIdentity.read(from)) else { throw fileBrowserError(9) }
                    guard renameatx_np(AT_FDCWD, from, toParent, toName, UInt32(RENAME_EXCL)) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                } else { try root.withParent(source, relocate) }
            }
            let inverse = step.trashSource ? FileBrowserStep(kind: .trash, source: destination, identity: expected) :
                FileBrowserStep(kind: .move, source: destination, destination: source, identity: expected)
            return try committed((inverse, iTermFilePathMapping(oldPath: step.trashSource ? nil : source, newPath: destination,
                                                               isDirectory: expected.directory)), root: root, expected: expected)
        case .trash:
            let display = step.source!, expected = step.identity!
            let receipt = try fileBrowserTrash(display, root: root, expected: expected)
            let inverse = receipt.path.map { FileBrowserStep(kind: .move, source: $0, destination: display, identity: expected, trashSource: true) }
            let mapping = iTermFilePathMapping(oldPath: display, newPath: nil, isDirectory: expected.directory, trashPath: receipt.path)
            return try committed((inverse, mapping), root: root, expected: expected, error: receipt.error)
        }
    }
    func createFile(inDirectory path: String, name: String, context: iTermFileBrowserContext,
                    completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, completion: completion) { root in
            [FileBrowserStep(kind: .createFile, destination: try root.destination(inDirectory: path, name: name))]
        }
    }
    func createFolder(inDirectory path: String, name: String, context: iTermFileBrowserContext,
                      completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, completion: completion) { root in
            [FileBrowserStep(kind: .createFolder, destination: try root.destination(inDirectory: path, name: name))]
        }
    }
    func rename(_ path: String, newName: String, context: iTermFileBrowserContext,
                completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, completion: completion) { root in
            [FileBrowserStep(kind: .move, source: path,
                             destination: try root.destination(inDirectory: (path as NSString).deletingLastPathComponent, name: newName),
                             identity: try self.source(path, root: root))]
        }
    }
    func duplicateFile(_ path: String, newName: String, context: iTermFileBrowserContext,
                       completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, completion: completion) { root in
            let identity = try self.source(path, root: root)
            guard identity.regular else { throw fileBrowserError(5) }
            return [FileBrowserStep(kind: .copy, source: path,
                                    destination: try root.destination(inDirectory: (path as NSString).deletingLastPathComponent, name: newName),
                                    identity: identity)]
        }
    }
    func trash(_ paths: [String], context: iTermFileBrowserContext,
               completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, completion: completion) { root in
            try paths.map { FileBrowserStep(kind: .trash, source: $0, identity: try self.source($0, root: root)) }
        }
    }
    func move(_ paths: [String], toDirectory path: String, context: iTermFileBrowserContext,
              completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, completion: completion) { root in
            try paths.map { FileBrowserStep(kind: .move, source: $0,
                                           destination: try root.destination(inDirectory: path, name: ($0 as NSString).lastPathComponent),
                                           identity: try self.source($0, root: root)) }
        }
    }
    func undo(_ context: iTermFileBrowserContext, completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, historyDirection: -1, completion: completion) { _ in [] }
    }
    func redo(_ context: iTermFileBrowserContext, completion: @escaping (iTermFileOperationResult) -> Void) {
        mutate(context, historyDirection: 1, completion: completion) { _ in [] }
    }
}

private struct FileBrowserStep {
    enum Kind { case createFile, createFolder, copy, move, trash }
    let kind: Kind
    var source: String? = nil
    var destination: String? = nil
    var identity: FileBrowserIdentity? = nil
    var trashSource = false
}
private struct FileBrowserHistory {
    var undo = [[FileBrowserStep]]()
    var redo = [[FileBrowserStep]]()
}

private struct FileBrowserPartialMutation: Error {
    let inverse: FileBrowserStep?
    let mapping: iTermFilePathMapping
    let underlying: NSError
}
