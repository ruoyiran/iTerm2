import AppKit

@objcMembers final class iTermToolFileTree: NSView, ToolbeltTool {
    var rootDirectory: String?
    var browserContext: iTermFileBrowserContext? {
        didSet { guard browserContext !== oldValue else { return }; binding.applyContext(browserContext); updateVisibility() }
    }
    var activeBrowserContext: iTermFileBrowserContext? { visible && !stopped ? binding.context : nil }
    var openTerminal: ((String, iTermOpenStyle) -> Void)?
    var canOpenTerminal: ((iTermOpenStyle) -> Bool)?
    var nativeRequest: ((iTermFileBrowserRequest) -> Void)?
    private let binding: iTermFileBrowserCoordinator
    private var watcher: iTermFileTreeWatcher?
    private var observers = [NSObjectProtocol]()
    private var refreshWork: DispatchWorkItem?
    private var stopped = false
    private var visible = false
    override init(frame: NSRect) {
        binding = iTermFileBrowserCoordinator(native: iTermFileWorkspaceService.bootstrap().coordinator)
        super.init(frame: frame)
        addSubview(binding.controller.view)
        binding.nativeRequest = { [weak self] request in self?.nativeRequest?(request) }
        watcher = iTermFileTreeWatcher { [weak self] root, _ in
            guard let self, self.visible, self.browserContext?.rootDirectory == root else { return }
            self.refreshWork?.cancel()
            let context = self.browserContext
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.visible, self.browserContext === context else { return }
                self.binding.refresh()
            }
            self.refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    required convenience init!(frame: NSRect, url: URL!, identifier: String!) { self.init(frame: frame) }
    static func isDynamic() -> Bool { false }
    override var isFlipped: Bool { true }
    static var supportedProfileTypes: ProfileType { .terminal }
    var ownsToolHeader: Bool { true }
    func minimumHeight() -> CGFloat { 100 }
    func relayout() { binding.controller.view.frame = bounds }
    override func layout() { super.layout(); relayout() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    if note.name == NSWindow.willCloseNotification { self?.shutdown() } else { self?.updateVisibility() }
                })
            }
        }
        updateVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }
    private func updateVisibility() {
        visible = !stopped && !isHiddenOrHasHiddenAncestor && window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        binding.setVisible(visible)
        if visible, let root = browserContext?.rootDirectory { watcher?.watch(root: root) }
        else { watcher?.stop(); refreshWork?.cancel() }
    }
    func shutdown() {
        guard !stopped else { return }; stopped = true; watcher?.stop(); refreshWork?.cancel(); binding.shutdown()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        nativeRequest = nil; openTerminal = nil; canOpenTerminal = nil
    }
    deinit { watcher?.stop(); refreshWork?.cancel(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
