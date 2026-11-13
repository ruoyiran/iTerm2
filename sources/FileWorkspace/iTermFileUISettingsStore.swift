import Foundation

// Preference keys and protocol fields are stable technical identifiers.
final class FileUISettingsStore {
    private var settings: [String: Any]
    private var annotations: [String: Any]
    private let saveSettings: ([String: Any]) -> Void
    private let saveAnnotations: ([String: Any]) -> Void
    static let defaults: [String: Any] = ["editorWordWrap": true, "markdownDefaultViewMode": "rich", "diffSideBySide": false,
        "editorAutoSave": false, "richMarkdownSpellcheckEnabled": true, "editorFontZoomLevel": 0,
        "theme": "system", "uiFontFamily": "Geist"]
    init(read: () -> [String: Any] = { [:] }, write: @escaping ([String: Any]) -> Void = { _ in },
         readAnnotations: () -> [String: Any] = { [:] }, writeAnnotations: @escaping ([String: Any]) -> Void = { _ in }) {
        settings = Self.defaults.merging(read()) { _, value in value }
        annotations = readAnnotations(); saveSettings = write; saveAnnotations = writeAnnotations
    }
    var snapshot: [String: Any] { settings }
    func update(_ changes: [String: Any]) throws -> [String: Any] {
        var updated = settings
        for (key, value) in changes {
            switch key {
            case "editorWordWrap", "diffSideBySide", "editorAutoSave", "richMarkdownSpellcheckEnabled":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw fileBrowserError(2) }
            case "markdownDefaultViewMode": guard ["source", "rich"].contains(value as? String ?? "") else { throw fileBrowserError(2) }
            case "theme": guard ["system", "light", "dark"].contains(value as? String ?? "") else { throw fileBrowserError(2) }
            case "uiFontFamily", "editorFontFamily": guard let string = value as? String, string.utf8.count <= 256 else { throw fileBrowserError(2) }
            case "editorFontZoomLevel": guard let number = value as? NSNumber, number.doubleValue.isFinite, abs(number.doubleValue) <= 20 else { throw fileBrowserError(2) }
            case "viewerPreferences":
                guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
                      let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count <= 256 * 1024 else { throw fileBrowserError(2) }
            default: throw fileBrowserError(2)
            }
            updated[key] = value
        }
        settings = updated; saveSettings(settings); return settings
    }
    func comments(owner: String, path: String) -> [[String: Any]] { annotations[owner + "\n" + path] as? [[String: Any]] ?? [] }
    func setComments(_ comments: [[String: Any]], owner: String, path: String) throws -> [[String: Any]] {
        guard comments.count <= 1000, JSONSerialization.isValidJSONObject(comments),
              let data = try? JSONSerialization.data(withJSONObject: comments), data.count <= 256 * 1024 else { throw fileBrowserError(2) }
        var updated = annotations
        let key = owner + "\n" + path
        if comments.isEmpty { updated.removeValue(forKey: key) } else { updated[key] = comments }
        guard let total = try? JSONSerialization.data(withJSONObject: updated), total.count <= 4 * 1024 * 1024 else { throw fileBrowserError(2) }
        annotations = updated; saveAnnotations(annotations); return comments
    }
}
