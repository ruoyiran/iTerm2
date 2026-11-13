import AppKit

/// Production storage selection belongs to the application, never to the Foundation store.
@objcMembers final class iTermFileWorkspaceService: NSObject {
    private static var suites = [String: iTermFileWorkspaceService]()
    let documentStore: iTermFileDocumentStore
    let runtime: iTermFileWorkspaceUIRuntime
    let coordinator: iTermFileSessionCoordinator
    private init(directory: URL) {
        documentStore = iTermFileDocumentStore(storageDirectory: directory.appendingPathComponent("FileWorkspaceDrafts", isDirectory: true))
        let preferences = iTermUserDefaults.userDefaults()
        let settings = FileUISettingsStore(read: {
            var values = preferences.dictionary(forKey: "FileWorkspaceUISettings") ?? [:]
            values["viewerPreferences"] = preferences.dictionary(forKey: "NoSyncFileWorkspaceViewerPreferences") ?? [:]
            return values
        }, write: { values in
            var configuration = values; configuration.removeValue(forKey: "viewerPreferences")
            preferences.set(configuration, forKey: "FileWorkspaceUISettings")
            preferences.set(values["viewerPreferences"] ?? [:], forKey: "NoSyncFileWorkspaceViewerPreferences")
        }, readAnnotations: { preferences.dictionary(forKey: "NoSyncFileWorkspaceAnnotations") ?? [:] },
           writeAnnotations: { preferences.set($0, forKey: "NoSyncFileWorkspaceAnnotations") })
        runtime = iTermFileWorkspaceUIRuntime(documentStore: documentStore,
            resourceDirectory: Bundle.main.resourceURL?.appendingPathComponent("FileWorkspaceUI"), settings: settings)
        coordinator = iTermFileSessionCoordinator(documentStore: documentStore, runtime: runtime)
        super.init()
    }
    @discardableResult static func bootstrap() -> iTermFileWorkspaceService {
        guard let path = FileManager.default.applicationSupportDirectoryWithoutCreating() else { it_fatalError("Missing application support directory") }
        if let service = suites[path] { iTermFileSessionHost.installCoordinator(service.coordinator); return service }
        let service = iTermFileWorkspaceService(directory: URL(fileURLWithPath: path, isDirectory: true))
        suites[path] = service
        iTermFileSessionHost.installCoordinator(service.coordinator)
        return service
    }
}
