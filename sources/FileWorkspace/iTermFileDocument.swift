// Localization unneeded: these Foundation APIs use stable technical identifiers and storage metadata.
import Foundation
import CryptoKit

@objc enum iTermFileDocumentKind: Int {
    case text = 0, markdown = 1, image = 2, pdf = 3, unsupported = 4
    case svg = 5, mermaid = 6, csv = 7, notebook = 8, audio = 9, video = 10

    var isEditable: Bool { [.text, .markdown, .svg, .mermaid, .csv, .notebook].contains(self) }

    static func forExtension(_ ext: String) -> iTermFileDocumentKind? {
        switch ext.lowercased() {
        case "md", "markdown", "mdown": return .markdown
        case "svg": return .svg
        case "mmd", "mermaid": return .mermaid
        case "csv", "tsv": return .csv
        case "ipynb": return .notebook
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "ico", "avif": return .image
        case "mp3", "wav", "ogg", "oga", "m4a", "aac", "flac", "opus": return .audio
        case "mp4", "m4v", "mov", "webm": return .video
        default: return nil
        }
    }
}

struct FileDocumentReadScope {
    let root: FileBrowserRoot
    let canonicalPath: String?
}

@objc enum iTermFileSaveOutcome: Int {
    case saved, conflict, readOnly, failed, stale, missing
}

@objcMembers final class iTermFileTextEdit: NSObject {
    let range: NSRange
    let replacement: String

    init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Shared preflight/mapping predicate. Resolve ancestors, not the final component: moving a
/// symlink itself must not be mistaken for moving its target. The same calculation works
/// before and after the affected leaf has moved, including /var versus /private/var aliases.
func fileDocumentAffectedSuffix(displayPath: String, canonicalPath: String, affectedPath: String,
                                includingDescendants: Bool) -> String? {
    let url = URL(fileURLWithPath: affectedPath)
    let canonicalSource = url.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    for (path, source) in [(displayPath, affectedPath), (canonicalPath, canonicalSource)] {
        if path == source { return "" }
        let prefix = source == "/" ? "/" : source + "/"
        if includingDescendants && path.hasPrefix(prefix) { return String(path.dropFirst(source == "/" ? 0 : source.count)) }
    }
    return nil
}

@objcMembers final class iTermFileDocumentSnapshot: NSObject {
    let documentIdentifier: String
    let filePath: String
    let canonicalPath: String
    let kind: iTermFileDocumentKind
    let text: String?
    let revision: UInt64
    let isDirty: Bool
    let isReadOnly: Bool
    let hasDiskConflict: Bool
    let byteCount: UInt64
    let isTooLarge: Bool

    @nonobjc init(_ document: FileDocument) {
        documentIdentifier = document.identifier
        filePath = document.path
        canonicalPath = document.canonicalPath
        kind = document.kind
        text = document.text
        revision = document.revision
        isDirty = document.isDirty
        isReadOnly = document.readOnly
        hasDiskConflict = document.conflict
        byteCount = document.byteCount
        isTooLarge = document.tooLarge
    }
}

// These values are storage metadata and technical identifiers, not UI strings.
struct FileTextFormat: Codable {
    enum Encoding: String, Codable { case utf8, utf16LE, utf16BE }
    var encoding: Encoding
    var bom: Bool

    func data(_ text: String) -> Data {
        switch encoding {
        case .utf8:
            return (bom ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(text.utf8)
        case .utf16LE, .utf16BE:
            var data = bom ? (encoding == .utf16LE ? Data([0xff, 0xfe]) : Data([0xfe, 0xff])) : Data()
            for unit in text.utf16 {
                data.append(encoding == .utf16LE ? UInt8(unit & 255) : UInt8(unit >> 8))
                data.append(encoding == .utf16LE ? UInt8(unit >> 8) : UInt8(unit & 255))
            }
            return data
        }
    }

    static func decode(_ data: Data) -> (String, FileTextFormat)? {
        let bytes = [UInt8](data.prefix(3))
        let encoding: Encoding
        let skip: Int
        if bytes.starts(with: [0xff, 0xfe]) { encoding = .utf16LE; skip = 2 }
        else if bytes.starts(with: [0xfe, 0xff]) { encoding = .utf16BE; skip = 2 }
        else { encoding = .utf8; skip = bytes == [0xef, 0xbb, 0xbf] ? 3 : 0 }
        let format = FileTextFormat(encoding: encoding, bom: skip > 0)
        let body = data.dropFirst(skip)
        let stringEncoding: String.Encoding = encoding == .utf8 ? .utf8 : (encoding == .utf16LE ? .utf16LittleEndian : .utf16BigEndian)
        guard let text = String(data: body, encoding: stringEncoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13, 12].contains($0.value)) }),
              format.data(text) == data else { return nil }
        return (text, format)
    }
}

struct FileSignature: Codable, Equatable {
    var device: UInt64
    var inode: UInt64
    var size: UInt64
    var hash: String?
}

func fileDocumentHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct FileEditTransaction {
    var forward: [iTermFileTextEdit]
    var inverse: [iTermFileTextEdit]
    var cost: Int {
        (forward + inverse).reduce(0) { $0 + $1.replacement.utf8.count + 32 }
    }
}

// All mutations occur on the owning store’s state queue.
final class FileDocument {
    let identifier: String
    var path: String { didSet { if path != oldValue { lifecycleGeneration += 1 } } }
    var canonicalPath: String { didSet { if canonicalPath != oldValue { lifecycleGeneration += 1 } } }
    var kind: iTermFileDocumentKind
    var text: String? { didSet { updateContentMetadata() } }
    var format: FileTextFormat? { didSet { updateContentMetadata() } }
    private var contentHash: String?
    private var contentByteCount: UInt64 = 0
    var baseline: FileSignature
    var revision: UInt64 = 0
    var lifecycleGeneration: UInt64 = 0
    var readOnly: Bool
    var conflict = false
    var tooLarge: Bool
    var saving = false
    var undo: [FileEditTransaction] = []
    var redo: [FileEditTransaction] = []

    var byteCount: UInt64 { text == nil ? baseline.size : contentByteCount }
    var isDirty: Bool { contentHash.map { $0 != baseline.hash } ?? false }

    private func updateContentMetadata() {
        guard let text = text, let format = format else { contentHash = nil; contentByteCount = 0; return }
        let data = format.data(text)
        contentHash = fileDocumentHash(data)
        contentByteCount = UInt64(data.count)
    }

    init(identifier: String = UUID().uuidString, path: String, canonicalPath: String,
         kind: iTermFileDocumentKind, text: String?, format: FileTextFormat?,
         baseline: FileSignature, readOnly: Bool, tooLarge: Bool) {
        self.identifier = identifier
        self.path = path
        self.canonicalPath = canonicalPath
        self.kind = kind
        self.text = text
        self.format = format
        self.baseline = baseline
        self.readOnly = readOnly
        self.tooLarge = tooLarge
        updateContentMetadata()
    }
}
