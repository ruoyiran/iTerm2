import Foundation

// Localization unneeded: wire protocol fields and stable diagnostic codes.
struct FileUIMessageFence {
    let epoch: String
    let view: String
    let token: String
    let generation: UInt64

    func accepts(_ message: [String: Any]) -> Bool {
        guard let version = message["protocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              message["rendererEpoch"] as? String == epoch,
              message["viewIdentifier"] as? String == view,
              message["contextToken"] as? String == token,
              message["generation"] as? String == String(generation),
              let request = message["requestIdentifier"] as? String, !request.isEmpty, request.utf8.count <= 128,
              let type = message["type"] as? String, type.utf8.count <= 64,
              message["payload"] is [String: Any], JSONSerialization.isValidJSONObject(message) else { return false }
        return true
    }
    var dictionary: [String: Any] {
        ["protocolVersion": 1, "rendererEpoch": epoch, "viewIdentifier": view,
         "contextToken": token, "generation": String(generation)]
    }
}

func fileUIError(_ code: Int) -> NSError { NSError(domain: "iTermFileUI", code: code) }

func fileUIChunks(_ string: String) -> [String] {
    let value = string as NSString
    var offset = 0, chunks = [String]()
    while offset < value.length {
        var count = min(131072, value.length - offset)
        if offset + count < value.length {
            let last = value.character(at: offset + count - 1), next = value.character(at: offset + count)
            if (0xd800...0xdbff).contains(last), (0xdc00...0xdfff).contains(next) { count -= 1 }
        }
        chunks.append(value.substring(with: NSRange(location: offset, length: count))); offset += count
    }
    return chunks
}
final class FileUIChunkAssembler {
    private var identifier: String?
    private var parts = [String]()
    private var total = 0
    private var bytes = 0
    private var started = Date.distantPast
    func reset() { identifier = nil; parts.removeAll(); total = 0; bytes = 0 }
    func accept(_ payload: [String: Any]) -> [String: Any]? {
        if Date().timeIntervalSince(started) > 5 { reset() }
        guard let id = payload["identifier"] as? String, id.utf8.count <= 128,
              let index = fileUIInteger(payload["index"], maximum: 4095),
              let count = fileUIInteger(payload["total"], minimum: 1, maximum: 4096),
              let text = payload["text"] as? String, text.utf16.count <= 131072 else { reset(); return nil }
        if index == 0 { reset(); identifier = id; total = count; started = Date() }
        guard identifier == id, total == count, index == parts.count else { reset(); return nil }
        bytes += text.utf8.count; guard bytes <= 300 * 1024 * 1024 else { reset(); return nil }
        parts.append(text)
        guard parts.count == total else { return nil }
        let data = Data(parts.joined().utf8); reset()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
