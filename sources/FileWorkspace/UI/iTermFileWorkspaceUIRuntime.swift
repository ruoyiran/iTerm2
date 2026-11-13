import AppKit
import WebKit

@objcMembers final class iTermFileWorkspaceUIRuntime: NSObject {
    @nonobjc let documentStore: iTermFileDocumentStore
    private let makeRenderer: (WKWebsiteDataStore) -> iTermFileWorkspaceWebView
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    private var server: iTermFileUIAssetServer?
    private var assetURL: URL?
    private var startupError: NSError?
    private var waiting = [(URL?, NSError?) -> Void]()
    private var idle = [iTermFileWorkspaceWebView]()
    private var leased = [iTermFileWorkspaceWebView: UUID]()
    private let controllers = NSHashTable<iTermFileViewController>.weakObjects()
    private var writers = [String: WeakFileView]()
    private var observer: NSObjectProtocol?
    private var stopped = false
    @nonobjc private(set) var interactionSuspended = false
    private var authorityGeneration: UInt64 = 0
    convenience init(documentStore: iTermFileDocumentStore) {
        self.init(documentStore: documentStore, resourceDirectory: Bundle.main.resourceURL?.appendingPathComponent("FileWorkspaceUI"))
    }
    @nonobjc init(documentStore: iTermFileDocumentStore, resourceDirectory: URL?,
                  makeRenderer: @escaping (WKWebsiteDataStore) -> iTermFileWorkspaceWebView = { iTermFileWorkspaceWebView(dataStore: $0) }) {
        self.makeRenderer = makeRenderer; self.documentStore = documentStore; super.init()
        observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(iTermFileDocumentStore.didChangeNotification), object: documentStore, queue: .main) { [weak self] note in
            guard let snapshot = note.userInfo?["snapshot"] as? iTermFileDocumentSnapshot else { return }
            for controller in self?.controllers.allObjects ?? [] where controller.documentIdentifier == snapshot.documentIdentifier {
                controller.applyDocumentChanges(snapshot, edits: note.userInfo?["edits"] as? [iTermFileTextEdit])
            }
        }
        let resource = resourceDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                guard let resource = resource else { throw fileUIError(1) }
                let server = try iTermFileUIAssetServer(resourceDirectory: resource)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.stopped else { server.stop(); return }; self.server = server
                    server.start { [weak self] result in
                        guard let self = self, !self.stopped else { return }
                        switch result { case .success(let url): self.assetURL = url; case .failure(let error): self.startupError = error as NSError }
                        let callbacks = self.waiting; self.waiting.removeAll(); callbacks.forEach { $0(self.assetURL, self.startupError) }
                    }
                }
            } catch { DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }; self.startupError = error as NSError
                let callbacks = self.waiting; self.waiting.removeAll(); callbacks.forEach { $0(nil, error as NSError) }
            } }
        }
    }
    @nonobjc @discardableResult func acquire(owner: AnyObject, completion: @escaping (iTermFileWorkspaceWebView?, NSError?) -> Void) -> FileUIAcquisition {
        let acquisition = FileUIAcquisition(owner: owner)
        guard !stopped else { acquisition.cancel(); completion(nil, fileUIError(2)); return acquisition }
        let ready: (URL?, NSError?) -> Void = { [weak self] url, error in
            guard acquisition.isActive else { acquisition.cancel(); return }
            guard let self = self, !self.stopped, let url = url else { acquisition.cancel(); completion(nil, error ?? fileUIError(2)); return }
            let renderer = self.idle.popLast() ?? self.makeRenderer(self.dataStore)
            let leaseIdentifier = acquisition.identifier
            self.leased[renderer] = leaseIdentifier
            acquisition.cleanup = { [weak self, weak renderer] in
                guard let self = self, let renderer = renderer, self.leased[renderer] == leaseIdentifier else { return }
                self.release(renderer)
            }
            completion(renderer, nil)
            guard acquisition.isActive, self.leased[renderer] == leaseIdentifier else { acquisition.cancel(); return }
            renderer.loadAssets(url)
        }
        if assetURL != nil || startupError != nil { ready(assetURL, startupError) } else { waiting.append(ready) }
        return acquisition
    }
    @nonobjc func release(_ renderer: iTermFileWorkspaceWebView) {
        guard leased.removeValue(forKey: renderer) != nil else { return }; renderer.unbind()
        if !stopped && idle.count < 2 { idle.append(renderer) } else { renderer.shutdown() }
    }
    @nonobjc func register(_ controller: iTermFileViewController) { controllers.add(controller) }
    @nonobjc func unregister(_ controller: iTermFileViewController) {
        controllers.remove(controller)
        for key in Array(writers.keys) where writers[key]?.value === controller { writers.removeValue(forKey: key) }
    }
    @nonobjc func requestAuthority(_ controller: iTermFileViewController) {
        guard !interactionSuspended, !controller.blocksEditAuthority, let id = controller.documentIdentifier else { return }
        authorityGeneration &+= 1; let generation = authorityGeneration
        let grant = { [weak self, weak controller] (error: NSError?) in
            guard let self = self, let controller = controller, !self.interactionSuspended, !controller.blocksEditAuthority, generation == self.authorityGeneration, error == nil,
                  controller.documentIdentifier == id else { return }
            self.writers[id]?.value?.setEditAuthority(false); self.writers[id] = WeakFileView(controller)
            controller.setEditAuthority(true)
        }
        if let previous = writers[id]?.value, previous !== controller { previous.flushEdits(reason: .focusTransfer, completion: grant) } else { grant(nil) }
    }
    @nonobjc func hasAuthority(_ controller: iTermFileViewController) -> Bool {
        guard let id = controller.documentIdentifier else { return false }; return writers[id]?.value === controller
    }
    func flushAllEdits(reason: iTermFileFlushReason, completion: @escaping (NSError?) -> Void) {
        if reason != .save { interactionSuspended = true }
        let values = controllers.allObjects
        guard !values.isEmpty else { completion(nil); return }
        var remaining = values.count, failure: NSError?
        for controller in values { controller.flushEdits(reason: reason) { error in
            if failure == nil { failure = error }; remaining -= 1; if remaining == 0 { completion(failure) }
        } }
    }
    func resumeEditing() { interactionSuspended = false; controllers.allObjects.forEach { $0.resumeEditing() } }
    func shutdown() {
        guard !stopped else { return }; stopped = true
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        controllers.allObjects.forEach { $0.shutdown() }; (idle + Array(leased.keys)).forEach { $0.shutdown() }
        idle.removeAll(); leased.removeAll(); writers.removeAll(); server?.stop(); server = nil
        let callbacks = waiting; waiting.removeAll(); callbacks.forEach { $0(nil, fileUIError(2)) }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) }; server?.stop() }
}
private final class WeakFileView { weak var value: iTermFileViewController?; init(_ value: iTermFileViewController) { self.value = value } }

final class FileUIAcquisition {
    let identifier = UUID()
    private weak var owner: AnyObject?
    private var cancelled = false
    fileprivate var cleanup: (() -> Void)?
    var isActive: Bool { !cancelled && owner != nil }
    init(owner: AnyObject) { self.owner = owner }
    func cancel() { cancelled = true; let callback = cleanup; cleanup = nil; callback?() }
}
