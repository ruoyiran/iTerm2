import AppKit

/// Production storage selection belongs to the application, never to the Foundation store.
@objcMembers final class iTermFileWorkspaceService: NSObject {
    private static var suites = [String: iTermFileWorkspaceService]()
    let documentStore: iTermFileDocumentStore
    let runtime: iTermFileWorkspaceUIRuntime
    let coordinator: iTermFileSessionCoordinator
    private init(directory: URL) {
        documentStore = iTermFileDocumentStore(storageDirectory: directory.appendingPathComponent("FileWorkspaceDrafts", isDirectory: true))
        runtime = iTermFileWorkspaceUIRuntime(documentStore: documentStore)
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
