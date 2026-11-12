// Localization unneeded: these Foundation APIs use stable technical identifiers and storage metadata.
import Foundation
import Darwin

// Error codes are stable API diagnostics; UI consumers localize their presentation.
func fileDocumentError(_ code: Int) -> NSError {
    NSError(domain: "iTermFileDocumentError", code: code)
}

@objcMembers final class iTermFileDocumentStore: NSObject {
    static let maximumFileBytes = 10 * 1024 * 1024
    static let didChangeNotification = "iTermFileDocumentStoreDidChange"
    private let storageDirectory: URL
    private let state = DispatchQueue(label: "com.iterm2.file-document-state")
    private let io = DispatchQueue(label: "com.iterm2.file-document-io", qos: .userInitiated)
    private var draftScheduled: Set<String> = []
    private var documents: [String: FileDocument] = [:]

    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
        super.init()
    }

    func openFile(atPath path: String, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        io.async {
            do {
                let loaded = try Self.read(path)
                self.state.async {
                    let document = self.documents.values.first { $0.canonicalPath == loaded.canonicalPath } ?? loaded
                    self.documents[document.identifier] = document
                    let snapshot = iTermFileDocumentSnapshot(document)
                    DispatchQueue.main.async { completion(snapshot, nil) }
                }
            } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
        }
    }

    func snapshot(documentIdentifier: String, completion: @escaping (iTermFileDocumentSnapshot?) -> Void) {
        state.async {
            let snapshot = self.documents[documentIdentifier].map(iTermFileDocumentSnapshot.init)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    @nonobjc private static func validatePath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw fileDocumentError(1) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    @nonobjc private static func read(_ path: String) throws -> FileDocument {
        let url = try validatePath(path)
        try validateRegularTarget(url, allowMissing: false)
        var result: Result<FileDocument, Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try readUncoordinated(coordinated, originalPath: url.path) }
        }
        if let error = error { throw error }
        guard let result = result else { throw fileDocumentError(2) }
        return try result.get()
    }

    // NSFileCoordinator may try to access a FIFO before entering its accessor. Reject special files first.
    @nonobjc private static func validateRegularTarget(_ url: URL, allowMissing: Bool) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        if lstat(canonical.path, &info) != 0 {
            if allowMissing && errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw fileDocumentError(3) }
    }

    @nonobjc private static func readUncoordinated(_ url: URL, originalPath: String) throws -> FileDocument {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let fd = Darwin.open(canonical.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o444 != 0, info.st_size >= 0 else { throw fileDocumentError(3) }
        let tooLarge = UInt64(info.st_size) > UInt64(maximumFileBytes)
        var data = Data()
        if !tooLarge {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(fd, &buffer, min(buffer.count, maximumFileBytes + 1 - data.count))
                if count < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximumFileBytes { throw fileDocumentError(4) }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw fileDocumentError(5) }
        }
        let ext = canonical.pathExtension.lowercased()
        let decoded = tooLarge ? nil : FileTextFormat.decode(data)
        let kind: iTermFileDocumentKind
        if ext == "pdf" || data.starts(with: Data("%PDF-".utf8)) { kind = .pdf }
        else if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) ||
                    data.starts(with: [0xff, 0xd8, 0xff]) || data.starts(with: Data("GIF8".utf8)) ||
                    data.starts(with: [0x49, 0x49, 0x2a, 0]) || data.starts(with: [0x4d, 0x4d, 0, 0x2a]) ||
                    (data.starts(with: Data("RIFF".utf8)) && data.dropFirst(8).starts(with: Data("WEBP".utf8))) ||
                    ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "ico"].contains(ext) { kind = .image }
        else if tooLarge && ["md", "markdown", "mdown", "txt", "text"].contains(ext) {
            kind = ["md", "markdown", "mdown"].contains(ext) ? .markdown : .text
        }
        else if decoded != nil { kind = ["md", "markdown", "mdown"].contains(ext) ? .markdown : .text }
        else { kind = .unsupported }
        let editable = kind == .text || kind == .markdown
        return FileDocument(path: originalPath, canonicalPath: canonical.path, kind: kind,
                            text: editable ? decoded?.0 : nil, format: editable ? decoded?.1 : nil,
                            baseline: FileSignature(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino,
                                                    size: UInt64(info.st_size), hash: tooLarge ? nil : fileDocumentHash(data)),
                            readOnly: tooLarge || !editable || info.st_mode & 0o222 == 0 || access(canonical.path, W_OK) != 0,
                            tooLarge: tooLarge)
    }
    func applyEdits(_ edits: [iTermFileTextEdit], documentIdentifier: String, expectedRevision: UInt64,
                    completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        state.async {
            do {
                guard let document = self.documents[documentIdentifier] else { throw fileDocumentError(6) }
                guard document.revision == expectedRevision else { throw fileDocumentError(7) }
                guard !document.readOnly, let text = document.text, let format = document.format else { throw fileDocumentError(8) }
                let (updated, transaction) = try Self.applying(edits, to: text)
                guard format.data(updated).count <= Self.maximumFileBytes else { throw fileDocumentError(4) }
                if !edits.isEmpty {
                    document.text = updated
                    document.revision += 1
                    document.undo.append(transaction)
                    document.redo.removeAll()
                    Self.trimHistory(document)
                    self.changed(document, edits: transaction.forward)
                    self.scheduleDraft(documentIdentifier)
                }
                self.complete(document, completion: completion)
            } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
        }
    }

    @nonobjc private static func applying(_ edits: [iTermFileTextEdit], to text: String) throws -> (String, FileEditTransaction) {
        let units = Array(text.utf16)
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        var previous: NSRange?
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !(0xd800...0xdbff).contains(units[offset - 1]) || !(0xdc00...0xdfff).contains(units[offset])
        }
        for edit in sorted {
            let range = edit.range
            guard range.location >= 0, range.length >= 0, range.location <= units.count,
                  range.length <= units.count - range.location, boundary(range.location),
                  boundary(range.location + range.length) else { throw fileDocumentError(9) }
            if let previous = previous,
               range.location < NSMaxRange(previous) || range.location == previous.location { throw fileDocumentError(10) }
            previous = range
        }
        var offset = 0
        let nsText = text as NSString
        let inversePieces = sorted.map { edit -> iTermFileTextEdit in
            let range = NSRange(location: edit.range.location + offset, length: edit.replacement.utf16.count)
            offset += edit.replacement.utf16.count - edit.range.length
            return iTermFileTextEdit(range: range, replacement: nsText.substring(with: edit.range))
        }
        var inverse: [iTermFileTextEdit] = []
        for piece in inversePieces {
            if let last = inverse.last, NSMaxRange(last.range) == piece.range.location {
                inverse[inverse.count - 1] = iTermFileTextEdit(
                    range: NSRange(location: last.range.location, length: last.range.length + piece.range.length),
                    replacement: last.replacement + piece.replacement)
            } else { inverse.append(piece) }
        }
        let mutable = NSMutableString(string: text)
        for edit in sorted.reversed() { mutable.replaceCharacters(in: edit.range, with: edit.replacement) }
        return (mutable as String, FileEditTransaction(forward: sorted, inverse: inverse))
    }

    @nonobjc private static func trimHistory(_ document: FileDocument) {
        while document.undo.count > 100 || document.undo.reduce(0, { $0 + $1.cost }) > 32 * 1024 * 1024 {
            document.undo.removeFirst()
        }
    }

    func undo(documentIdentifier: String, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        history(documentIdentifier, redo: false, completion: completion)
    }

    func redo(documentIdentifier: String, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        history(documentIdentifier, redo: true, completion: completion)
    }

    @nonobjc private func history(_ id: String, redo: Bool, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        state.async {
            do {
                guard let document = self.documents[id], let text = document.text, !document.readOnly else { throw fileDocumentError(8) }
                if let transaction = redo ? document.redo.last : document.undo.last {
                    let edits = redo ? transaction.forward : transaction.inverse
                    document.text = try Self.applying(edits, to: text).0
                    if redo { document.redo.removeLast(); document.undo.append(transaction) }
                    else { document.undo.removeLast(); document.redo.append(transaction) }
                    document.revision += 1
                    self.changed(document, edits: edits)
                    self.scheduleDraft(id)
                }
                self.complete(document, completion: completion)
            } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
        }
    }

    @nonobjc private func complete(_ document: FileDocument, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        let snapshot = iTermFileDocumentSnapshot(document)
        DispatchQueue.main.async { completion(snapshot, nil) }
    }

    @nonobjc private func changed(_ document: FileDocument, edits: [iTermFileTextEdit]? = nil) {
        let snapshot = iTermFileDocumentSnapshot(document)
        var info: [String: Any] = ["snapshot": snapshot]
        if let edits = edits { info["edits"] = edits }
        let userInfo = info
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name(Self.didChangeNotification), object: self, userInfo: userInfo)
        }
    }

    func save(documentIdentifier: String, overwrite: Bool, completion: @escaping (iTermFileSaveOutcome, NSError?) -> Void) {
        beginSave(documentIdentifier, toPath: nil, overwrite: overwrite, completion: completion)
    }

    func saveAs(documentIdentifier: String, toPath: String, overwrite: Bool,
                completion: @escaping (iTermFileSaveOutcome, NSError?) -> Void) {
        beginSave(documentIdentifier, toPath: toPath, overwrite: overwrite, completion: completion)
    }

    @nonobjc private func beginSave(_ id: String, toPath: String?, overwrite: Bool,
                                   completion: @escaping (iTermFileSaveOutcome, NSError?) -> Void) {
        state.async {
            guard let document = self.documents[id] else {
                DispatchQueue.main.async { completion(.missing, fileDocumentError(6)) }; return
            }
            guard !document.saving else {
                DispatchQueue.main.async { completion(.stale, fileDocumentError(7)) }; return
            }
            guard let text = document.text, let format = document.format, toPath != nil || !document.readOnly else {
                DispatchQueue.main.async { completion(.readOnly, fileDocumentError(8)) }; return
            }
            let target = toPath ?? document.path
            let originalCanonical = document.canonicalPath
            let baseline = document.baseline
            let data = format.data(text)
            document.saving = true
            self.io.async {
                let result = Result {
                    let canonicalTarget = try Self.validatePath(target).resolvingSymlinksInPath().standardizedFileURL.path
                    let occupied = self.state.sync {
                        self.documents.values.contains { $0.identifier != id && $0.canonicalPath == canonicalTarget }
                    }
                    guard !occupied else { throw Self.saveError(.conflict) }
                    return try Self.write(data, target: target, originalCanonical: originalCanonical,
                                          baseline: baseline, saveAs: toPath != nil, overwrite: overwrite)
                }
                self.state.async {
                    document.saving = false
                    let outcome: iTermFileSaveOutcome
                    var error: NSError?
                    switch result {
                    case .success(let written):
                        // The captured bytes become the disk baseline; edits accepted during IO survive.
                        document.path = written.path
                        document.canonicalPath = written.canonicalPath
                        document.baseline = written.baseline
                        document.readOnly = written.readOnly
                        if written.kind == .text || written.kind == .markdown { document.kind = written.kind }
                        document.conflict = false
                        outcome = .saved
                        self.scheduleDraft(id)
                    case .failure(let failure):
                        error = failure as NSError
                        if error?.domain == "iTermFileDocumentSaveError", let raw = error?.code,
                           let value = iTermFileSaveOutcome(rawValue: raw) { outcome = value }
                        else if error?.domain == NSPOSIXErrorDomain && error?.code == Int(ENOENT) { outcome = .missing }
                        else { outcome = .failed }
                        if outcome == .conflict || outcome == .missing { document.conflict = true }
                    }
                    self.changed(document)
                    DispatchQueue.main.async { completion(outcome, error) }
                }
            }
        }
    }

    @nonobjc private static func saveError(_ outcome: iTermFileSaveOutcome) -> NSError {
        NSError(domain: "iTermFileDocumentSaveError", code: outcome.rawValue)
    }

    @nonobjc private static func write(_ data: Data, target: String, originalCanonical: String,
                                      baseline: FileSignature, saveAs: Bool, overwrite: Bool) throws -> FileDocument {
        let url = try validatePath(target)
        try validateRegularTarget(url, allowMissing: saveAs)
        var result: Result<FileDocument, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                let canonical = coordinated.resolvingSymlinksInPath().standardizedFileURL
                let sameTarget = canonical.path == originalCanonical
                if !saveAs && !sameTarget { throw saveError(.conflict) }
                var existsInfo = stat()
                let exists = lstat(canonical.path, &existsInfo) == 0
                if !exists && errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if !exists && (!saveAs || sameTarget) { throw saveError(.missing) }
                if exists && !sameTarget && !overwrite { throw saveError(.conflict) }
                let current = exists ? try readUncoordinated(canonical, originalPath: url.path) : nil
                if let current = current {
                    if current.readOnly && current.kind != .unsupported && current.text != nil { throw saveError(.readOnly) }
                    if existsInfo.st_mode & 0o222 == 0 || access(canonical.path, W_OK) != 0 { throw saveError(.readOnly) }
                    if sameTarget && current.baseline != baseline && !overwrite { throw saveError(.conflict) }
                }
                let temporary = canonical.deletingLastPathComponent().appendingPathComponent(".iterm-save-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                if exists { try FileManager.default.copyItem(at: canonical, to: temporary) }
                else {
                    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    Darwin.close(fd)
                }
                let handle = try FileHandle(forWritingTo: temporary)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                guard url.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path else { throw saveError(.conflict) }
                if let current = current {
                    let rechecked = try readUncoordinated(canonical, originalPath: url.path)
                    guard rechecked.baseline == current.baseline else { throw saveError(.conflict) }
                }
                // Swap requires the destination to exist at the atomic commit, so deletion can never create a new source.
                let status = renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, canonical.path,
                                          UInt32(exists ? RENAME_SWAP : RENAME_EXCL))
                guard status == 0 else {
                    if errno == EEXIST { throw saveError(.conflict) }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return try readUncoordinated(canonical, originalPath: url.path)
            }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw fileDocumentError(2) }
        return try result.get()
    }

    func discardChanges(documentIdentifier: String, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        state.async {
            guard let document = self.documents[documentIdentifier], !document.saving else {
                DispatchQueue.main.async { completion(nil, fileDocumentError(6)) }; return
            }
            let path = document.path
            let revision = document.revision
            let generation = document.lifecycleGeneration
            self.io.async {
                let result = Result { try Self.read(path) }
                self.state.async {
                    do {
                        guard self.documents[documentIdentifier] === document, !document.saving,
                              document.revision == revision, document.lifecycleGeneration == generation else { throw fileDocumentError(7) }
                        switch result {
                        case .success(let loaded):
                            document.text = loaded.text
                            document.format = loaded.format
                            document.canonicalPath = loaded.canonicalPath
                            document.kind = loaded.kind
                            document.baseline = loaded.baseline
                            document.readOnly = loaded.readOnly
                            document.tooLarge = loaded.tooLarge
                            document.conflict = false
                        case .failure(let error):
                            let failure = error as NSError
                            guard (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT)) ||
                                  (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError) else { throw error }
                            // Explicit discard of a deleted source does not recreate it. A nil
                            // buffer is clean, so queued persistence cannot resurrect its draft.
                            document.text = nil
                            document.format = nil
                            document.kind = .unsupported
                            document.readOnly = true
                            document.tooLarge = false
                            document.conflict = true
                        }
                        document.undo.removeAll(); document.redo.removeAll()
                        document.revision += 1
                        self.changed(document)
                        self.removeDraft(documentIdentifier: documentIdentifier) { error in
                            if let error = error { completion(nil, error) }
                            else { self.snapshot(documentIdentifier: documentIdentifier) { completion($0, nil) } }
                        }
                    } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
                }
            }
        }
    }
    @nonobjc private func persistCurrentDraft(_ id: String, clearScheduled: Bool = false) throws {
        // Every persistence entry point captures on the same serial IO executor. An absent cache
        // entry may have been released with a retained dirty draft; it is not a clean document.
        let captured: (identifier: String, draft: FileDocumentDraft?)? = state.sync {
            if clearScheduled { self.draftScheduled.remove(id) }
            guard let document = self.documents[id] else { return nil }
            return (id, FileDocumentDraft(document))
        }
        guard let captured = captured else { return }
        let storage = FileDraftStorage(directory: storageDirectory)
        if let draft = captured.draft { try storage.write(draft) }
        else { try storage.remove(captured.identifier) }
    }

    @nonobjc private func scheduleDraft(_ id: String) {
        guard draftScheduled.insert(id).inserted else { return }
        io.async {
            // Automatic persistence is best effort; explicit flush returns any storage error.
            try? self.persistCurrentDraft(id, clearScheduled: true)
        }
    }

    func persistDraft(documentIdentifier: String, completion: @escaping (NSError?) -> Void) {
        state.async {
            guard self.documents[documentIdentifier] != nil else {
                DispatchQueue.main.async { completion(fileDocumentError(6)) }; return
            }
            self.io.async {
                do {
                    try self.persistCurrentDraft(documentIdentifier)
                    DispatchQueue.main.async { completion(nil) }
                } catch { DispatchQueue.main.async { completion(error as NSError) } }
            }
        }
    }

    func removeDraft(documentIdentifier: String, completion: @escaping (NSError?) -> Void) {
        state.async {
            self.io.async {
                do {
                    try FileDraftStorage(directory: self.storageDirectory).remove(documentIdentifier)
                    DispatchQueue.main.async { completion(nil) }
                } catch { DispatchQueue.main.async { completion(error as NSError) } }
            }
        }
    }

    func recoverDrafts(completion: @escaping ([iTermFileDocumentSnapshot], NSError?) -> Void) {
        io.async {
            do {
                let (drafts, issue) = try FileDraftStorage(directory: self.storageDirectory).readAll()
                var recovered: [FileDocument] = []
                for draft in drafts {
                    // Validate the record before accessing the stored document path.
                    let disk = try? Self.read(draft.path)
                    let document = FileDocument(identifier: draft.identifier, path: draft.path, canonicalPath: draft.canonicalPath,
                                                kind: iTermFileDocumentKind(rawValue: draft.kind) ?? .text,
                                                text: draft.text, format: draft.format, baseline: draft.baseline,
                                                readOnly: disk?.readOnly ?? false, tooLarge: false)
                    document.conflict = disk?.baseline != draft.baseline || disk?.canonicalPath != draft.canonicalPath
                    document.revision = 1
                    recovered.append(document)
                }
                let loaded = recovered
                self.state.async {
                    var snapshots: [iTermFileDocumentSnapshot] = []
                    for document in loaded {
                        // Never replace a live editor with an older recovery record.
                        let live = self.documents[document.identifier] ?? self.documents.values.first { $0.canonicalPath == document.canonicalPath } ?? document
                        self.documents[live.identifier] = live
                        snapshots.append(iTermFileDocumentSnapshot(live))
                        self.changed(live)
                    }
                    DispatchQueue.main.async { completion(snapshots, issue) }
                }
            } catch { DispatchQueue.main.async { completion([], error as NSError) } }
        }
    }
    /// Flush all cached documents before exit. Completion waits for earlier queued draft IO.
    func flushDrafts(completion: @escaping (NSError?) -> Void) {
        state.async {
            self.io.async {
                let identifiers = self.state.sync { Array(self.documents.keys) }
                var issue: NSError?
                for id in identifiers {
                    do { try self.persistCurrentDraft(id) }
                    catch { issue = error as NSError }
                }
                let error = issue
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Watcher hook: clean documents reload; dirty documents retain edits and flag a changed baseline.
    func fileDidChange(atPath: String, completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        io.async {
            let result = Result { try Self.read(atPath) }
            self.state.async {
                let loaded = try? result.get()
                guard let document = self.documents.values.first(where: {
                    $0.path == atPath || $0.canonicalPath == atPath || $0.canonicalPath == loaded?.canonicalPath
                }) else { DispatchQueue.main.async { completion(nil, nil) }; return }
                if document.saving { self.complete(document, completion: completion); return }
                if let loaded = loaded {
                    // Access permissions are not part of the content/identity baseline.
                    document.readOnly = loaded.readOnly
                    if document.isDirty {
                        document.conflict = loaded.baseline != document.baseline || loaded.canonicalPath != document.canonicalPath
                    } else if loaded.baseline != document.baseline {
                        document.text = loaded.text
                        document.format = loaded.format
                        document.kind = loaded.kind
                        document.canonicalPath = loaded.canonicalPath
                        document.baseline = loaded.baseline
                        document.tooLarge = loaded.tooLarge
                        document.conflict = false
                        document.undo.removeAll(); document.redo.removeAll()
                        document.revision += 1
                    }
                    self.changed(document)
                    self.complete(document, completion: completion)
                } else {
                    document.conflict = true
                    self.changed(document)
                    let snapshot = iTermFileDocumentSnapshot(document)
                    let error: NSError
                    switch result { case .failure(let failure): error = failure as NSError
                    case .success: error = fileDocumentError(2) }
                    DispatchQueue.main.async { completion(snapshot, error) }
                }
            }
        }
    }

    /// An explicit watcher move preserves the opaque identity and the unsaved document buffer.
    func fileDidMove(fromPath: String, toPath: String,
                     completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        state.async {
            guard let document = self.documents.values.first(where: { $0.path == fromPath || $0.canonicalPath == fromPath }),
                  !document.saving else { DispatchQueue.main.async { completion(nil, fileDocumentError(6)) }; return }
            let generation = document.lifecycleGeneration
            self.io.async {
                let result = Result { try Self.read(toPath) }
                self.state.async {
                    do {
                        guard self.documents[document.identifier] === document,
                              document.lifecycleGeneration == generation else { throw fileDocumentError(7) }
                        let loaded = try result.get()
                        guard !self.documents.values.contains(where: { $0.identifier != document.identifier && $0.canonicalPath == loaded.canonicalPath }) else { throw Self.saveError(.conflict) }
                        document.path = loaded.path
                        document.canonicalPath = loaded.canonicalPath
                        document.conflict = loaded.baseline != document.baseline
                        document.readOnly = loaded.readOnly
                        self.changed(document)
                        self.scheduleDraft(document.identifier)
                        self.complete(document, completion: completion)
                    } catch { DispatchQueue.main.async { completion(nil, error as NSError) } }
                }
            }
        }
    }

    /// Arrangement consumers store this metadata and reopen the path; contents remain in local drafts.
    func restorableDescriptor(documentIdentifier: String, completion: @escaping ([String: Any]?) -> Void) {
        state.async {
            let descriptor: [String: Any]? = self.documents[documentIdentifier].map {
                ["documentIdentifier": $0.identifier, "filePath": $0.path, "kind": $0.kind.rawValue]
            }
            DispatchQueue.main.async { completion(descriptor) }
        }
    }

    /// Native consumers call after the last view releases its reference. Dirty drafts remain on disk.
    func releaseDocument(documentIdentifier: String, completion: @escaping (NSError?) -> Void) {
        state.async {
            guard let document = self.documents[documentIdentifier] else {
                DispatchQueue.main.async { completion(fileDocumentError(6)) }; return
            }
            guard !document.saving else { DispatchQueue.main.async { completion(fileDocumentError(7)) }; return }
            let revision = document.revision
            let generation = document.lifecycleGeneration
            self.io.async {
                do {
                    let draft: FileDocumentDraft? = try self.state.sync {
                        guard self.documents[documentIdentifier] === document,
                              document.revision == revision, document.lifecycleGeneration == generation,
                              !document.saving else { throw fileDocumentError(7) }
                        return FileDocumentDraft(document)
                    }
                    let storage = FileDraftStorage(directory: self.storageDirectory)
                    if let draft = draft { try storage.write(draft) } else { try storage.remove(documentIdentifier) }
                    self.state.async {
                        guard self.documents[documentIdentifier] === document,
                              document.revision == revision, document.lifecycleGeneration == generation,
                              !document.saving else {
                            DispatchQueue.main.async { completion(fileDocumentError(7)) }; return
                        }
                        self.documents.removeValue(forKey: documentIdentifier)
                        DispatchQueue.main.async { completion(nil) }
                    }
                } catch { DispatchQueue.main.async { completion(error as NSError) } }
            }
        }
    }

}
