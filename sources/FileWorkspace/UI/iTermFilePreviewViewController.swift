import AppKit
import PDFKit
import ImageIO
import Darwin

private final class FilePreviewTextView: NSTextView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { onFocus?() }; return accepted }
}
private final class FilePreviewImageView: NSImageView {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onFocus?(); super.mouseDown(with: event) }
}
private final class FilePreviewSearchField: NSSearchField {
    var onFocus: (() -> Void)?
    // Activating a pane may assign its main responder. Do that before AppKit installs
    // this field's editor so typing remains in the search field.
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
}
private final class FilePreviewButton: NSButton {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func performClick(_ sender: Any?) { onFocus?(); super.performClick(sender) }
}
private final class FilePDFView: PDFView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { onFocus?() }; return accepted }

    override func perform(_ action: PDFAction) {
        // Only navigation inside this document is permitted; never execute file/URL actions.
        if action is PDFActionGoTo { super.perform(action) }
    }
}
final class iTermFilePreviewViewController: NSViewController, NSTextViewDelegate, NSSearchFieldDelegate, PDFDocumentDelegate {
    private static let worker = OperationQueue()
    private var work: BlockOperation?
    private var generation: UInt64 = 0
    private var content: NSView?
    var onShowSource: (() -> Void)?
    var onFocus: (() -> Void)?
    var onSelection: ((Bool) -> Void)?
    private var selectionObserver: NSObjectProtocol?
    private var sourceButton: NSButton?
    private var markdownTextView: NSTextView?
    private var toolbar: NSStackView?
    private var searchField: NSSearchField?
    private var searchDocument: PDFDocument?
    private var matches = [PDFSelection]()
    private var matchIndex = -1
    private var searchText = ""
    private var searchWasTruncated = false
    private let searchStatus = NSTextField(labelWithString: "")

    private let label = NSTextField(wrappingLabelWithString: "")
    var preferredFirstResponder: NSResponder { markdownTextView ?? content ?? view }
    override func loadView() { view = NSView(); view.addSubview(label) }
    override func viewDidLayout() { super.viewDidLayout(); content?.frame = contentFrame; sourceButton?.frame = NSRect(x: 8, y: max(0, view.bounds.height - 30), width: 130, height: 26); label.frame = view.bounds.insetBy(dx: 12, dy: 12); toolbar?.frame = NSRect(x: 8, y: max(0, view.bounds.height - 34), width: max(0, view.bounds.width - 16), height: 28) }
    func apply(_ snapshot: iTermFileDocumentSnapshot) {
        work?.cancel(); clearControls(); generation &+= 1; let generation = generation
        if let observer = selectionObserver { NotificationCenter.default.removeObserver(observer) }; selectionObserver = nil
        if snapshot.kind != .markdown { markdownTextView = nil; sourceButton?.removeFromSuperview(); sourceButton = nil }
        if snapshot.isTooLarge { showError(tooLarge: true); return }
        if snapshot.kind == .markdown, let text = snapshot.text {
            if sourceButton == nil { let button = NSButton(title: String(localized: "FileWorkspace.ShowSource", defaultValue: "Show Source", comment: "Switch Markdown preview to editable source"), target: self, action: #selector(showSource)); sourceButton = button; view.addSubview(button) }

            let scroll = NSScrollView(); scroll.hasVerticalScroller = true
            let textView = FilePreviewTextView(); textView.onFocus = { [weak self] in self?.onFocus?() }; textView.isEditable = false; textView.isSelectable = true; textView.delegate = self
            markdownTextView = textView
            textView.textContainerInset = NSSize(width: 16, height: 12)
            textView.textStorage?.setAttributedString(MarkdownPortholeRenderer.attributedString(markdown: text, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), textColor: .textColor, backgroundColor: .textBackgroundColor, imageLoader: nil))
            textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false; textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true; textView.frame = view.bounds; scroll.documentView = textView; install(scroll); return
        }
        guard !snapshot.isTooLarge, snapshot.kind == .image || snapshot.kind == .pdf else { showError(unsupported: true); return }
        label.stringValue = FileUIStrings.labels["loading"] ?? ""; label.isHidden = false
        let operation = BlockOperation(); work = operation
        Self.worker.maxConcurrentOperationCount = 1; Self.worker.qualityOfService = .utility
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            do {
                let data = try Self.read(path: snapshot.canonicalPath)
                guard operation?.isCancelled == false else { return }
                var image: CGImage?
                if snapshot.kind == .image {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 32 * 1024 * 1024 else { throw fileUIError(7) }
                    image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                    guard image != nil else { throw fileUIError(7) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == generation else { return }
                    if let image = image { self.installImage(image) }
                    else if let document = PDFDocument(data: data), document.pageCount <= 10000 {
                        let pdf = FilePDFView(); pdf.onFocus = { [weak self] in self?.onFocus?() }; pdf.autoScales = true;
                        self.selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdf, queue: .main) { [weak self] _ in guard let self = self else { return }; self.onSelection?(self.hasSelection) }
                        pdf.document = document; self.installPDFControls(document); self.install(pdf)
                    } else { self.showError() }
                }
            } catch { DispatchQueue.main.async { [weak self] in guard let self = self, self.generation == generation else { return }; self.showError() } }
        }
        Self.worker.addOperation(operation)
    }
    private var contentFrame: NSRect { NSRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - (sourceButton == nil && toolbar == nil ? 0 : 38))) }
    private func installToolbar(_ controls: [NSView]) {
        let bar = NSStackView(views: controls)
        bar.orientation = .horizontal; bar.spacing = 8
        toolbar = bar; view.addSubview(bar); view.needsLayout = true
    }
    private func button(_ title: String, displayTitle: String? = nil, identifier: String, action: Selector) -> NSButton {
        let button = FilePreviewButton(title: displayTitle ?? title, target: self, action: action)
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.onFocus = { [weak self] in self?.onFocus?() }
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }
    private func installImage(_ image: CGImage) {
        let imageView = FilePreviewImageView()
        imageView.onFocus = { [weak self] in self?.onFocus?() }
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.frame = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.001; scroll.maxMagnification = 16
        scroll.documentView = imageView
        installToolbar([
            button(String(localized: "FileWorkspace.ZoomOut", defaultValue: "Zoom Out", comment: "Reduce image preview magnification"), displayTitle: "−", identifier: "file-preview-zoom-out", action: #selector(zoomOut)),
            button(String(localized: "FileWorkspace.ZoomIn", defaultValue: "Zoom In", comment: "Increase image preview magnification"), displayTitle: "+", identifier: "file-preview-zoom-in", action: #selector(zoomIn)),
            button(String(localized: "FileWorkspace.FitImage", defaultValue: "Fit to Window", comment: "Fit the image preview inside its pane"), displayTitle: String(localized: "FileWorkspace.Fit", defaultValue: "Fit", comment: "Compact button to fit an image inside its pane"), identifier: "file-preview-image-fit", action: #selector(fitImage))
        ])
        install(scroll); fitImage()
    }
    @objc private func zoomIn() { zoom(by: 1.25) }
    @objc private func zoomOut() { zoom(by: 0.8) }
    private func zoom(by factor: CGFloat) {
        guard let scroll = content as? NSScrollView, scroll.allowsMagnification else { return }
        scroll.magnification = min(scroll.maxMagnification, max(scroll.minMagnification, scroll.magnification * factor))
    }
    @objc private func fitImage() {
        guard let scroll = content as? NSScrollView, let image = scroll.documentView as? NSImageView,
              image.bounds.width > 0, image.bounds.height > 0 else { return }
        let size = scroll.contentSize
        scroll.magnification = min(scroll.maxMagnification, max(scroll.minMagnification,
            min(size.width / image.bounds.width, size.height / image.bounds.height)))
    }
    private func installPDFControls(_ document: PDFDocument) {
        searchDocument = document; document.delegate = self
        let field = FilePreviewSearchField(); field.onFocus = { [weak self] in self?.onFocus?() }; field.delegate = self; field.target = self; field.action = #selector(searchPDF)
        field.placeholderString = String(localized: "FileWorkspace.FindPDF", defaultValue: "Find in PDF", comment: "Search text inside the PDF preview")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal); searchField = field
        searchStatus.stringValue = ""
        installToolbar([field,
            button(String(localized: "FileWorkspace.PreviousMatch", defaultValue: "Previous", comment: "Select the previous PDF search match"), displayTitle: "‹", identifier: "file-preview-find-previous", action: #selector(previousMatch)),
            button(String(localized: "FileWorkspace.NextMatch", defaultValue: "Next", comment: "Select the next PDF search match"), displayTitle: "›", identifier: "file-preview-find-next", action: #selector(nextMatch)), searchStatus])
    }
    func canPerform(_ command: iTermFileViewCommand) -> Bool {
        guard content is PDFView else { return false }
        return command == .find || ([.findNext, .findPrevious].contains(command) && !matches.isEmpty)
    }
    func perform(_ command: iTermFileViewCommand) {
        switch command {
        case .find: if let field = searchField { view.window?.makeFirstResponder(field) }
        case .findNext: nextMatch()
        case .findPrevious: previousMatch()
        default: break
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { searchPDF() }
    }
    @objc private func searchPDF() {
        guard let document = searchDocument, let text = searchField?.stringValue else { return }
        onFocus?()
        document.cancelFindString(); matches.removeAll(); matchIndex = -1; searchText = text; searchWasTruncated = false
        (content as? PDFView)?.clearSelection()
        searchStatus.stringValue = ""
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 2048 else {
            searchStatus.stringValue = String(localized: "FileWorkspace.SearchTooLong", defaultValue: "Search text is too long.", comment: "Search queries exceeding the UTF-8 size limit cannot run")
            return
        }
        document.beginFindString(text, withOptions: .caseInsensitive)
    }
    func didMatchString(_ instance: PDFSelection) {
        guard instance.pages.first?.document === searchDocument, !searchText.isEmpty, matches.count < 5000 else { return }
        matches.append(instance)
        if matches.count == 5000 { searchWasTruncated = true; searchDocument?.cancelFindString() }
        if matchIndex < 0 { selectMatch(at: 0) }
        updateSearchStatus()
    }
    func documentDidEndDocumentFind(_ notification: Notification) {
        guard notification.object as? PDFDocument === searchDocument else { return }
        updateSearchStatus()
    }
    @objc private func nextMatch() { selectMatch(at: matchIndex + 1) }
    @objc private func previousMatch() { selectMatch(at: matchIndex - 1) }
    private func selectMatch(at index: Int) {
        guard !matches.isEmpty, let pdf = content as? PDFView else { return }
        matchIndex = (index % matches.count + matches.count) % matches.count
        let selection = matches[matchIndex]; pdf.setCurrentSelection(selection, animate: false); pdf.go(to: selection)
        onSelection?(hasSelection); updateSearchStatus()
    }
    private func updateSearchStatus() {
        if !matches.isEmpty { searchStatus.stringValue = "\(matchIndex + 1) / \(matches.count)" + (searchWasTruncated ? "+" : "") }
        else if !searchText.isEmpty, searchDocument?.isFinding == false {
            searchStatus.stringValue = String(localized: "FileWorkspace.NoPDFMatches", defaultValue: "No matches", comment: "The PDF search finished without matching text")
        }
    }
    private func clearControls() {
        searchDocument?.delegate = nil; searchDocument?.cancelFindString(); searchDocument = nil
        toolbar?.removeFromSuperview(); toolbar = nil; searchField = nil
        matches.removeAll(); matchIndex = -1; searchText = ""; searchWasTruncated = false
    }
    @objc private func showSource() { onShowSource?() }
    static func read(path: String) throws -> Data {
        guard (path as NSString).isAbsolutePath, URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { throw fileUIError(7) }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fileUIError(7) }; defer { Darwin.close(fd) }
        var stat = Darwin.stat(); let maximum = 10 * 1024 * 1024
        guard fstat(fd, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG, stat.st_size <= maximum else { throw fileUIError(7) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true { let count = Darwin.read(fd, &buffer, buffer.count); guard count >= 0 else { throw fileUIError(7) }; if count == 0 { break }; guard result.count + count <= maximum else { throw fileUIError(7) }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
    private func install(_ content: NSView) { self.content?.removeFromSuperview(); self.content = content; content.frame = contentFrame; content.autoresizingMask = [.width, .height]; view.addSubview(content); label.isHidden = true; view.needsLayout = true }
    private func showError(unsupported: Bool = false, tooLarge: Bool = false) { clearControls(); content?.removeFromSuperview(); content = nil; label.stringValue = FileUIStrings.labels[tooLarge ? "tooLarge" : unsupported ? "unsupported" : "previewError"] ?? ""; label.isHidden = false }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return true }
        NSWorkspace.shared.open(url); return true
    }
    var hasSelection: Bool {
        if let text = markdownTextView { return text.selectedRange().length > 0 }
        if let pdf = content as? PDFView { return !(pdf.currentSelection?.string ?? "").isEmpty }
        return false
    }
    func copySelection() { if let text = markdownTextView { text.copy(nil) } else if let pdf = content as? PDFView { pdf.copy(nil) } }
    func textViewDidChangeSelection(_ notification: Notification) { onSelection?(hasSelection) }
    deinit { if let observer = selectionObserver { NotificationCenter.default.removeObserver(observer) } }
    func shutdown() { clearControls(); work?.cancel(); if let observer = selectionObserver { NotificationCenter.default.removeObserver(observer) }; selectionObserver = nil; generation &+= 1; content?.removeFromSuperview(); content = nil }
}
