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

    func prepare() throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else { throw fileDocumentError(11) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw fileDocumentError(11) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString == id else { throw fileDocumentError(11) }
        return directory.appendingPathComponent(id + ".json")
    }

    func remove(_ id: String) throws {
        try prepare()
        let file = try url(id)
        if unlink(file.path) != 0 && errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    func write(_ draft: FileDocumentDraft) throws {
        try prepare()
        let file = try url(draft.identifier)
        let data = try JSONEncoder().encode(draft)
        guard data.count <= Self.maximumDraftBytes else { throw fileDocumentError(4) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var total = UInt64(data.count)
        var count = 1
        for entry in files where entry.path != file.path && entry.pathExtension == "json" {
            var info = stat()
            if lstat(entry.path, &info) == 0 && info.st_size >= 0 { total += UInt64(info.st_size); count += 1 }
        }
        guard total <= Self.maximumTotalBytes, count <= Self.maximumDraftCount else { throw fileDocumentError(4) }
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

    func readAll() throws -> ([FileDocumentDraft], NSError?) {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        var drafts: [FileDocumentDraft] = []
        var issue: NSError?
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
