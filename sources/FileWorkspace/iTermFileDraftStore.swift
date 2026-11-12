// Localization unneeded: these Foundation APIs use stable technical identifiers and storage metadata.
import Foundation
import Darwin

// A versioned, bounded local recovery record. Never used in window arrangements.
struct FileDocumentDraft: Codable {
    var version = 1
    var identifier: String
    var path: String
    var canonicalPath: String
    var kind: Int
    var text: String
    var format: FileTextFormat
    var baseline: FileSignature

    init?(_ document: FileDocument) {
        guard document.isDirty, let text = document.text, let format = document.format else { return nil }
        identifier = document.identifier
        path = document.path
        canonicalPath = document.canonicalPath
        kind = document.kind.rawValue
        self.text = text
        self.format = format
        baseline = document.baseline
    }

    func validate(filename: String) throws {
        guard version == 1, UUID(uuidString: identifier)?.uuidString == identifier,
              filename == identifier + ".json", path.hasPrefix("/"), canonicalPath.hasPrefix("/"),
              !path.utf8.contains(0), !canonicalPath.utf8.contains(0),
              kind == iTermFileDocumentKind.text.rawValue || kind == iTermFileDocumentKind.markdown.rawValue,
              format.data(text).count <= iTermFileDocumentStore.maximumFileBytes,
              baseline.size <= UInt64(iTermFileDocumentStore.maximumFileBytes),
              baseline.hash?.count == 64, baseline.hash?.allSatisfy({ $0.isHexDigit }) == true else { throw fileDocumentError(11) }
    }
}

struct FileDraftStorage {
    let directory: URL
    // JSON may expand each source byte to a six-character escape sequence.
    static let maximumDraftBytes = 6 * iTermFileDocumentStore.maximumFileBytes + 8192
    static let maximumTotalBytes: UInt64 = 128 * 1024 * 1024
    static let maximumDraftCount = 100

    private func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(".draft-") else { return false }
        let identifier = String(name.dropFirst(7))
        return UUID(uuidString: identifier)?.uuidString == identifier
    }

    private func withPreparedStorage<T>(_ body: () throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else { throw fileDocumentError(11) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw fileDocumentError(11) }
        guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(fd, LOCK_UN) }
        guard fchmod(fd, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Shared-directory stores/processes hold the same lock throughout cleanup and writing,
        // so another store can never mistake an in-progress private temporary file for an orphan.
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where isTemporaryName(entry.lastPathComponent) {
            var orphan = stat()
            guard fstatat(fd, entry.lastPathComponent, &orphan, AT_SYMLINK_NOFOLLOW) == 0,
                  orphan.st_mode & S_IFMT == S_IFREG, orphan.st_uid == getuid(),
                  orphan.st_mode & 0o077 == 0, orphan.st_nlink == 1 else { continue }
            guard unlinkat(fd, entry.lastPathComponent, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return try body()
    }

    func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString == id else { throw fileDocumentError(11) }
        return directory.appendingPathComponent(id + ".json")
    }

    func remove(_ id: String) throws {
        try withPreparedStorage {
            let file = try url(id)
            if unlink(file.path) != 0 && errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    private func ownedUsage(excluding replacedFile: URL? = nil) throws -> (bytes: UInt64, count: Int) {
        var total: UInt64 = 0
        var count = 0
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where (entry.pathExtension == "json" || isTemporaryName(entry.lastPathComponent)) &&
                  entry.lastPathComponent != replacedFile?.lastPathComponent {
            var info = stat()
            guard lstat(entry.path, &info) == 0, info.st_size >= 0 else { throw fileDocumentError(11) }
            let size = UInt64(info.st_size)
            guard size <= Self.maximumTotalBytes - total else { throw fileDocumentError(4) }
            total += size
            count += 1
            guard count <= Self.maximumDraftCount else { throw fileDocumentError(4) }
        }
        return (total, count)
    }

    func write(_ draft: FileDocumentDraft) throws {
        try withPreparedStorage {
            let file = try url(draft.identifier)
            let data = try JSONEncoder().encode(draft)
            guard data.count <= Self.maximumDraftBytes else { throw fileDocumentError(4) }
            // Check final steady usage, excluding the record this write replaces. The directory
            // lock permits only one staging file, separately bounded by maximumDraftBytes above.
            let usage = try ownedUsage(excluding: file)
            guard UInt64(data.count) <= Self.maximumTotalBytes - usage.bytes,
                  usage.count < Self.maximumDraftCount else { throw fileDocumentError(4) }
            let temp = directory.appendingPathComponent(".draft-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temp) }
            let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temp.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    func readAll() throws -> ([FileDocumentDraft], NSError?) {
        try withPreparedStorage {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            var drafts: [FileDocumentDraft] = []
            var issue: NSError?
            // Unsafe owned-name entries cannot be deleted, but still consume the storage budget.
            // Report the violation while returning independently bounded valid recovery records.
            do { _ = try ownedUsage() } catch { issue = error as NSError }
            var total: UInt64 = 0
            for (index, file) in files.enumerated() {
                do {
                    guard index < Self.maximumDraftCount else { throw fileDocumentError(4) }
                    let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard fd >= 0 else { throw fileDocumentError(11) }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          info.st_size >= 0, info.st_size <= Self.maximumDraftBytes else { throw fileDocumentError(11) }
                    total += UInt64(info.st_size)
                    guard total <= Self.maximumTotalBytes else { throw fileDocumentError(4) }
                    let data = try handle.read(upToCount: Self.maximumDraftBytes + 1) ?? Data()
                    guard data.count <= Self.maximumDraftBytes else { throw fileDocumentError(4) }
                    let draft = try JSONDecoder().decode(FileDocumentDraft.self, from: data)
                    try draft.validate(filename: file.lastPathComponent)
                    drafts.append(draft)
                } catch { issue = error as NSError }
            }
            return (drafts, issue)
        }
    }
}
