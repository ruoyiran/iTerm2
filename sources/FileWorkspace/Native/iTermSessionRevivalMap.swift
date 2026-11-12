import Foundation

/// Native Undo Close uses one map for both tab and window restoration. File/archive leaves
/// can be constructed from their descriptors; every other leaf must reuse its retained job.
@objcMembers final class iTermSessionRevivalMap: NSObject {
    static func build(_ tab: [String: Any], sessions: [String: AnyObject]) -> [String: AnyObject]? {
        var result = [String: AnyObject]()
        func visit(_ node: [String: Any], depth: Int) -> Bool {
            guard depth < 512 else { return false }
            if node["View Type"] as? String == "Splitter" {
                guard let children = node["Subviews"] as? [[String: Any]] else { return false }
                return children.allSatisfy { visit($0, depth: depth + 1) }
            }
            guard let session = node["Session"] as? [String: Any] else { return false }
            let identifier = session["Session GUID"] as? String ?? session["Session Unique ID"] as? String
            if let identifier, let retained = sessions[identifier] {
                result[identifier] = retained
                return true
            }
            // Presence, not successful decoding: malformed file records must stay on the
            // native file error-view path and must never trigger terminal relaunch fallback.
            if session[iTermFileSessionDescriptor.arrangementKey] != nil { return true }
            return identifier != nil && session["Restore As Archive"] is String
        }
        guard let root = tab["Root"] as? [String: Any], visit(root, depth: 0) else { return nil }
        for record in tab["Floating Panes"] as? [[String: Any]] ?? [] {
            if let node = record["Node"] as? [String: Any], !visit(node, depth: 0) { return nil }
        }
        return result
    }
}
