import Foundation

/// A restorable description. Live sessions and views belong to the workspace owner.
@objcMembers
class iTermSidebarWorkspaceItem: NSObject {
    let identifier: String
    var title: String
    let kind: String
    let sessionIdentifier: String?
    private var storedState: [String: Any]
    var state: [String: Any] {
        get { storedState }
        set { storedState = Self.propertyListDictionary(newValue) }
    }

    @objc(initWithIdentifier:title:kind:sessionIdentifier:state:)
    init(identifier: String, title: String, kind: String, sessionIdentifier: String?, state: [String: Any]) {
        self.identifier = identifier
        self.title = title
        self.kind = kind
        self.sessionIdentifier = sessionIdentifier
        storedState = Self.propertyListDictionary(state)
        super.init()
    }

    @objc(initWithDictionary:)
    convenience init?(dictionary: [String: Any]) {
        // Localization unneeded: arrangement keys and item kinds are stable identifiers.
        guard let identifier = dictionary["identifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let kind = dictionary["kind"] as? String,
              !kind.isEmpty else { return nil }
        self.init(identifier: identifier,
                  title: dictionary["title"] as? String ?? "",
                  kind: kind,
                  sessionIdentifier: dictionary["sessionIdentifier"] as? String,
                  state: dictionary["state"] as? [String: Any] ?? [:])
    }

    var dictionaryRepresentation: [String: Any] {
        // Localization unneeded: these are persisted arrangement keys.
        var result: [String: Any] = ["identifier": identifier, "title": title, "kind": kind, "state": state]
        if let sessionIdentifier { result["sessionIdentifier"] = sessionIdentifier }
        return result
    }

    // Only property-list values are retained, preventing state from owning live runtime objects.
    private static func propertyListDictionary(_ dictionary: [String: Any], depth: Int = 0) -> [String: Any] {
        guard depth < 32 else { return [:] }
        return dictionary.compactMapValues { propertyListValue($0, depth: depth + 1) }
    }

    private static func propertyListValue(_ value: Any, depth: Int) -> Any? {
        guard depth < 32 else { return nil }
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.doubleValue.isFinite ? number : nil
        case let data as Data: return data
        case let date as Date: return date
        case let array as [Any]: return array.compactMap { propertyListValue($0, depth: depth + 1) }
        case let dictionary as [String: Any]: return propertyListDictionary(dictionary, depth: depth + 1)
        default: return nil
        }
    }
}

/// Per-primary-tab workspace state. Geometry is bounded again by the window layout owner.
@objcMembers
class iTermSidebarWorkspaceState: NSObject {
    static let defaultWidth: CGFloat = 480
    static let minimumWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 720

    private var storedItems: [iTermSidebarWorkspaceItem] = []
    private var storedSelectedIdentifier: String?
    private var storedWidth = defaultWidth

    var items: [iTermSidebarWorkspaceItem] {
        get { storedItems }
        set {
            var identifiers = Set<String>()
            storedItems = newValue.filter {
                !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.kind.isEmpty && identifiers.insert($0.identifier).inserted
            }
            sanitizeSelection()
        }
    }

    var selectedIdentifier: String? {
        get { storedSelectedIdentifier }
        set { storedSelectedIdentifier = newValue; sanitizeSelection() }
    }

    var visible = false
    var width: CGFloat {
        get { storedWidth }
        set { storedWidth = Self.sanitizedWidth(newValue) }
    }

    var dictionaryRepresentation: [String: Any] {
        // Localization unneeded: these are persisted arrangement keys, not displayed text.
        var result: [String: Any] = ["version": 1, "items": items.map(\.dictionaryRepresentation),
                                   "visible": visible, "width": width]
        if let selectedIdentifier { result["selectedIdentifier"] = selectedIdentifier }
        return result
    }

    override init() { super.init() }

    @objc(initWithDictionary:)
    init(dictionary: [String: Any]) {
        super.init()
        // Localization unneeded: these are persisted arrangement keys.
        items = (dictionary["items"] as? [[String: Any]] ?? []).compactMap(iTermSidebarWorkspaceItem.init(dictionary:))
        selectedIdentifier = dictionary["selectedIdentifier"] as? String
        visible = dictionary["visible"] as? Bool ?? false
        width = (dictionary["width"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? Self.defaultWidth
    }

    @objc(appendItem:)
    func appendItem(_ item: iTermSidebarWorkspaceItem) {
        if let index = items.firstIndex(where: { $0.identifier == item.identifier }) {
            items[index] = item
        } else {
            items.append(item)
        }
        selectedIdentifier = item.identifier
    }

    @objc(selectItemWithIdentifier:)
    func selectItem(withIdentifier identifier: String) {
        guard items.contains(where: { $0.identifier == identifier }) else { return }
        selectedIdentifier = identifier
    }

    @objc(removeItemWithIdentifier:)
    func removeItem(withIdentifier identifier: String) {
        guard let index = items.firstIndex(where: { $0.identifier == identifier }) else { return }
        let wasSelected = selectedIdentifier == identifier
        items.remove(at: index)
        if wasSelected {
            selectedIdentifier = items.isEmpty ? nil : items[min(index, items.count - 1)].identifier
        }
    }

    private func sanitizeSelection() {
        if !items.contains(where: { $0.identifier == storedSelectedIdentifier }) {
            storedSelectedIdentifier = items.first?.identifier
        }
    }

    private static func sanitizedWidth(_ width: CGFloat) -> CGFloat {
        width.isFinite ? min(max(width, minimumWidth), maximumWidth) : defaultWidth
    }
}
