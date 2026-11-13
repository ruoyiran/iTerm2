import Foundation
import Darwin

// These dictionaries contain technical metadata, not user-visible strings.
final class FileContentService {
    let root: FileBrowserRoot
    static let maximumRangeBytes = 256 * 1024
    init(rootDirectory: String) throws { root = try FileBrowserRoot(rootDirectory) }

    func withFile<T>(_ path: String, _ body: (Int32, stat) throws -> T) throws -> T {
        try root.withParent(path) { parent, name in
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o444 != 0, info.st_size >= 0 else { throw fileBrowserError(5) }
            return try body(descriptor, info)
        }
    }

    static func identity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }
    func metadata(_ path: String) throws -> [String: Any] {
        let checked = try root.checked(path)
        let item = try FileBrowserIdentity.read(checked)
        guard !item.symlink else { throw fileBrowserError(2) }
        if item.directory {
            let descriptor = try root.openDirectory(path); defer { close(descriptor) }
            var info = stat(); guard fstat(descriptor, &info) == 0 else { throw fileBrowserError(5) }
            return Self.metadata(info)
        }
        return try withFile(path) { _, info in Self.metadata(info) }
    }
    private static func metadata(_ info: stat) -> [String: Any] {
        ["size": info.st_size, "mtime": Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000,
         "isDirectory": info.st_mode & S_IFMT == S_IFDIR, "fileIdentity": identity(info)]
    }
    func readRange(_ path: String, position: Int64, length: Int) throws -> [String: Any] {
        guard position >= 0, length > 0, length <= Self.maximumRangeBytes,
              position <= Int64.max - Int64(length) else { throw fileBrowserError(2) }
        return try withFile(path) { descriptor, info in
            let count = Int(min(Int64(length), max(0, info.st_size - position)))
            var bytes = [UInt8](repeating: 0, count: count), offset = 0
            while offset < count {
                let readCount = bytes.withUnsafeMutableBytes { buffer in
                    pread(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, position + Int64(offset))
                }
                if readCount < 0 && errno == EINTR { continue }
                guard readCount >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if readCount == 0 { break }; offset += readCount
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, Self.identity(after) == Self.identity(info), offset == count else { throw fileBrowserError(9) }
            return ["data": Data(bytes).base64EncodedString(), "byteLength": count, "size": info.st_size,
                    "fileIdentity": Self.identity(info)]
        }
    }
    func readBytes(_ path: String, maximum: Int) throws -> Data {
        try withFile(path) { descriptor, info in
            guard info.st_size <= maximum else { throw fileBrowserError(5) }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, Int64(offset))
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw fileBrowserError(9) }; offset += count
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, Self.identity(after) == Self.identity(info) else { throw fileBrowserError(9) }
            return Data(bytes)
        }
    }
    func readText(_ path: String) throws -> [String: Any] {
        let data = try readBytes(path, maximum: iTermFileDocumentStore.maximumFileBytes)
        guard let decoded = FileTextFormat.decode(data) else { throw fileBrowserError(5) }
        return ["content": decoded.0, "byteLength": data.count]
    }
    func markdownDocuments(_ directory: String) throws -> [[String: Any]] {
        let descriptor = try root.openDirectory(directory); close(descriptor)
        var pending = [directory], documents = [[String: Any]](), scanned = 0
        while let current = pending.popLast(), scanned < 10000 {
            scanned += 1
            for (name, identity, hidden) in try root.children(current) where !hidden && !name.hasPrefix(".") {
                let path = (current as NSString).appendingPathComponent(name)
                if identity.directory { pending.append(path) }
                else if identity.regular && iTermFileDocumentKind.forExtension((name as NSString).pathExtension) == .markdown {
                    documents.append(["filePath": path, "relativePath": try root.relative(path),
                                      "basename": name, "name": (name as NSString).deletingPathExtension])
                }
            }
        }
        return documents.sorted { ($0["relativePath"] as? String ?? "") < ($1["relativePath"] as? String ?? "") }
    }
    static func mimeType(_ path: String) -> String {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp", "ico": "image/x-icon",
                     "avif": "image/avif", "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic",
                     "heif": "image/heif", "pdf": "application/pdf", "mp3": "audio/mpeg", "wav": "audio/wav",
                     "m4a": "audio/mp4", "aac": "audio/aac", "ogg": "audio/ogg", "oga": "audio/ogg",
                     "flac": "audio/flac", "opus": "audio/ogg", "mp4": "video/mp4", "m4v": "video/mp4",
                     "mov": "video/quicktime", "webm": "video/webm"]
        return types[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
