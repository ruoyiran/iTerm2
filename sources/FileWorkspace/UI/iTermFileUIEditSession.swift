import Foundation

final class FileUIEditSession {
    private let store: iTermFileDocumentStore
    private let documentIdentifier: String
    private var sequence: UInt64 = 0
    private(set) var pending = false
    init(store: iTermFileDocumentStore, documentIdentifier: String) {
        self.store = store; self.documentIdentifier = documentIdentifier
    }
    func apply(_ payload: [String: Any], completion: @escaping (iTermFileDocumentSnapshot?, NSError?) -> Void) {
        guard !pending, payload["documentIdentifier"] as? String == documentIdentifier,
              let sequenceText = payload["sequence"] as? String, let next = UInt64(sequenceText), String(next) == sequenceText,
              sequence < UInt64.max, next == sequence + 1,
              let revisionText = payload["expectedRevision"] as? String, let revision = UInt64(revisionText), String(revision) == revisionText,
              let raw = payload["edits"] as? [[String: Any]], !raw.isEmpty, raw.count <= 65536 else { completion(nil, fileUIError(3)); return }
        var edits = [iTermFileTextEdit](), bytes = 0
        for edit in raw {
            guard let location = fileUIInteger(edit["location"], maximum: 100 * 1024 * 1024),
                  let length = fileUIInteger(edit["length"], maximum: 100 * 1024 * 1024),
                  let text = edit["replacement"] as? String else { completion(nil, fileUIError(3)); return }
            bytes += text.utf8.count; guard bytes <= 150 * 1024 * 1024 else { completion(nil, fileUIError(3)); return }
            edits.append(iTermFileTextEdit(range: NSRange(location: location, length: length), replacement: text))
        }
        pending = true
        store.applyEdits(edits, documentIdentifier: documentIdentifier, expectedRevision: revision) { [weak self] snapshot, error in
            self?.pending = false
            if error == nil { self?.sequence = next }
            completion(snapshot, error)
        }
    }
}
