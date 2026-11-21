import AppKit

@objc protocol iTermSidebarWorkspaceViewDelegate: AnyObject {
    func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, createItemOfKind kind: String)
    func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, selectItemWithIdentifier identifier: String)
    func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, closeItemWithIdentifier identifier: String)
    func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, navigateToText text: String)
    func sidebarWorkspaceViewDidRequestExpand(_ view: iTermSidebarWorkspaceView)
    func sidebarWorkspaceViewDidRequestTools(_ view: iTermSidebarWorkspaceView)
    func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, didChangeWidth width: CGFloat)
}

@objcMembers
class iTermSidebarWorkspaceView: NSView, NSTextFieldDelegate {
    weak var delegate: iTermSidebarWorkspaceViewDelegate?
    var items: [iTermSidebarWorkspaceItem] = [] { didSet { rebuildTabs() } }
    var selectedIdentifier: String? { didSet { rebuildTabs(); updateAddress() } }
    var contentView: NSView? {
        didSet {
            guard oldValue !== contentView else { return }
            oldValue?.removeFromSuperview()
            if let contentView {
                contentView.autoresizingMask = [.width, .height]
                contentView.frame = contentHost.bounds
                contentHost.addSubview(contentView)
            }
            contentHost.isHidden = contentView == nil
            landing.isHidden = contentView != nil
            needsLayout = true
        }
    }

    private let tabStrip = NSScrollView()
    private let tabDocument = SidebarFlippedView()
    private let contentHost = SidebarFlippedView()
    private let landing = SidebarFlippedView()
    private let addressPill = SidebarAddressPill()
    private let addressField = NSTextField()
    private let openLabel = NSTextField(labelWithString: String(localized: "SidebarWorkspace.Open",
        defaultValue: "Open", comment: "Heading above the sidebar’s Terminal, Files, and Changes cards"))
    private let newTabButton = SidebarChromeButton()
    private let expandButton = SidebarChromeButton()
    private let moreButton = SidebarChromeButton()
    private let resizeHandle = SidebarResizeHandle()
    private var cards: [SidebarChromeButton] = []
    private var tabs: [SidebarFlippedView] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        clipsToBounds = true
        contentHost.clipsToBounds = true
        setAccessibilityLabel(String(localized: "SidebarWorkspace.AccessibilityLabel",
            defaultValue: "Sidebar workspace", comment: "Accessibility label for the right workspace pane"))
        tabStrip.drawsBackground = false
        tabStrip.hasHorizontalScroller = false
        tabStrip.hasVerticalScroller = false
        tabStrip.documentView = tabDocument
        addSubview(tabStrip)
        addSubview(contentHost)
        addSubview(landing)
        addSubview(addressPill)
        contentHost.isHidden = true

        configureButton(newTabButton, symbol: .plus, identifier: "SidebarWorkspace.newTab",
            label: String(localized: "SidebarWorkspace.NewTab", defaultValue: "New Tab",
                          comment: "Title and accessibility label for a new sidebar tab"), action: #selector(createNewTab))
        configureButton(expandButton, symbol: .arrowUpLeftAndArrowDownRight, identifier: "SidebarWorkspace.expand",
            label: String(localized: "SidebarWorkspace.Expand", defaultValue: "Expand Sidebar",
                          comment: "Button to expand the right workspace"), action: #selector(expand))
        configureButton(moreButton, symbol: .ellipsis, identifier: "SidebarWorkspace.more",
            label: String(localized: "SidebarWorkspace.More", defaultValue: "More Sidebar Tools",
                          comment: "More tools button beside the Open heading"), action: #selector(showTools), parent: landing)

        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.font = .systemFont(ofSize: 14)
        addressField.textColor = .labelColor
        addressField.placeholderString = String(localized: "SidebarWorkspace.AddressPlaceholder",
            defaultValue: "Search files or enter a URL", comment: "Placeholder in the sidebar URL and file search field")
        addressField.placeholderAttributedString = NSAttributedString(string: addressField.placeholderString ?? "",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        addressField.setAccessibilityLabel(String(localized: "SidebarWorkspace.AddressAccessibilityLabel",
            defaultValue: "Search files or enter a URL", comment: "Accessibility label for the sidebar address field"))
        addressField.setAccessibilityIdentifier("SidebarWorkspace.address")
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(navigate)
        addressPill.addSubview(addressField)
        openLabel.font = .systemFont(ofSize: 14)
        openLabel.textColor = .secondaryLabelColor
        landing.addSubview(openLabel)
        let terminal = String(localized: "SidebarWorkspace.Terminal", defaultValue: "Terminal",
                              comment: "Card that opens a terminal in the sidebar")
        let files = String(localized: "SidebarWorkspace.Files", defaultValue: "Files",
                           comment: "Card that opens a file browser in the sidebar")
        let changes = String(localized: "SidebarWorkspace.Changes", defaultValue: "Changes",
                             comment: "Card that opens repository changes in the sidebar")
        // Localization unneeded: kinds and accessibility identifiers are stable routing keys.
        for (kind, title, symbol) in [("terminal", terminal, SFSymbol.terminal),
                                     ("files", files, .folder), ("changes", changes, .docBadgePlus)] {
            let card = SidebarChromeButton()
            configureButton(card, symbol: symbol, identifier: "SidebarWorkspace.create." + kind,
                            label: title, action: #selector(createCard(_:)), parent: landing)
            card.itemIdentifier = kind
            card.cardStyle = true
            cards.append(card)
        }
        resizeHandle.workspace = self
        addSubview(resizeHandle)
        rebuildTabs()
    }

    private func configureButton(_ button: SidebarChromeButton, symbol: SFSymbol, identifier: String,
                                 label: String, action: Selector, parent: NSView? = nil) {
        button.title = label
        button.image = NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil)
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.target = self
        button.action = action
        (parent ?? self).addSubview(button)
    }

    private func rebuildTabs() {
        tabs.forEach { $0.removeFromSuperview() }
        tabs.removeAll()
        if items.isEmpty {
            let placeholder = SidebarFlippedView()
            let button = SidebarChromeButton()
            configureButton(button, symbol: .plus, identifier: "SidebarWorkspace.emptyTab",
                label: newTabButton.title, action: #selector(createNewTab), parent: placeholder)
            button.tabStyle = true
            button.selectedTab = true
            tabDocument.addSubview(placeholder)
            tabs.append(placeholder)
        }
        for item in items {
            let container = SidebarFlippedView()
            let button = SidebarChromeButton()
            let close = SidebarChromeButton()
            let title = item.title.isEmpty ? newTabButton.title : item.title
            configureButton(button, symbol: symbol(for: item.kind), identifier: "SidebarWorkspace.tab." + item.identifier,
                            label: title, action: #selector(selectTab(_:)), parent: container)
            button.itemIdentifier = item.identifier
            button.tabStyle = true
            button.selectedTab = item.identifier == selectedIdentifier
            button.setAccessibilityValue(button.selectedTab ? 1 : 0)
            let closeLabel = String(localized: "SidebarWorkspace.CloseTab", defaultValue: "Close \(title)",
                                    comment: "Close sidebar tab button; the interpolated value is the tab’s title")
            configureButton(close, symbol: .xmark, identifier: "SidebarWorkspace.close." + item.identifier,
                            label: closeLabel, action: #selector(closeTab(_:)), parent: container)
            close.itemIdentifier = item.identifier
            tabDocument.addSubview(container)
            tabs.append(container)
        }
        needsLayout = true
    }

    private func symbol(for kind: String) -> SFSymbol {
        // Localization unneeded: item kinds are stable routing keys.
        switch kind {
        case "terminal": return .terminal
        case "files": return .folder
        case "file": return .docText
        case "changes": return .docBadgePlus
        case "browser": return .globe
        default: return .plus
        }
    }

    private func updateAddress() {
        guard addressField.currentEditor() == nil else { return }
        let item = items.first { $0.identifier == selectedIdentifier }
        // Localization unneeded: item metadata keys are stable identifiers.
        addressField.stringValue = item?.state["url"] as? String ?? item?.state["query"] as? String ?? ""
    }

    override func layout() {
        super.layout()
        addressPill.isHidden = contentView != nil
        let width = bounds.width
        let padding: CGFloat = width < 400 ? 16 : 22
        let headerHeight: CGFloat = 46
        expandButton.frame = NSRect(x: width - 38, y: 8, width: 28, height: 28)
        newTabButton.frame = NSRect(x: width - 70, y: 8, width: 28, height: 28)
        tabStrip.frame = NSRect(x: 10, y: 7, width: max(0, width - 84), height: 32)
        let tabWidth = min(180, max(112, tabStrip.bounds.width / CGFloat(max(1, tabs.count))))
        for (index, tab) in tabs.enumerated() {
            tab.frame = NSRect(x: CGFloat(index) * (tabWidth + 4), y: 0, width: tabWidth, height: 32)
            tab.subviews.first?.frame = tab.bounds
            if tab.subviews.count > 1 {
                tab.subviews[1].frame = NSRect(x: tabWidth - 26, y: 4, width: 24, height: 24)
            }
        }
        tabDocument.frame = NSRect(x: 0, y: 0, width: CGFloat(tabs.count) * (tabWidth + 4), height: 32)
        if let index = items.firstIndex(where: { $0.identifier == selectedIdentifier }), index < tabs.count {
            tabDocument.scrollToVisible(tabs[index].frame)
        }

        landing.frame = NSRect(x: 0, y: headerHeight, width: width, height: max(0, bounds.height - headerHeight))
        let landingAddressY = min(max(headerHeight + 56, bounds.height * 0.28), max(headerHeight + 8, bounds.height - 230))
        let addressY = contentView == nil ? landingAddressY : headerHeight + 5
        addressPill.frame = NSRect(x: padding, y: addressY, width: max(0, width - padding * 2), height: 44)
        addressField.frame = NSRect(x: 40, y: 11, width: max(0, addressPill.bounds.width - 54), height: 24)
        let openY = addressY + 78 - headerHeight
        openLabel.frame = NSRect(x: padding, y: openY, width: 160, height: 22)
        moreButton.frame = NSRect(x: width - padding - 24, y: openY - 1, width: 24, height: 24)
        let gap: CGFloat = 8
        let cardWidth = min(112, max(0, (width - padding * 2 - gap * 2) / 3))
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: padding + CGFloat(index) * (cardWidth + gap), y: openY + 34,
                                width: cardWidth, height: 92)
        }
        let contentY = headerHeight
        contentHost.frame = NSRect(x: 4, y: contentY, width: max(0, width - 4), height: max(0, bounds.height - contentY))
        contentView?.frame = contentHost.bounds
        resizeHandle.frame = NSRect(x: 0, y: 0, width: 4, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        // AppKit can include sibling regions in a dirty rectangle. Keep the
        // workspace background from covering the terminal or project sidebar.
        bounds.intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === addressField.currentEditor() { return true }
        var current: NSResponder? = responder
        var visited = Set<ObjectIdentifier>()
        while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
            if (candidate as? NSView)?.isDescendant(of: self) == true { return true }
            if let controller = candidate as? NSViewController, controller.isViewLoaded,
               controller.view.isDescendant(of: self) { return true }
            current = candidate.nextResponder
        }
        return false
    }

    @objc(focusAddressField)
    func focusAddressField() {
        window?.makeFirstResponder(addressField)
        addressField.selectText(nil)
    }

    @objc(handleKeyEquivalent:)
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard delegate != nil, !isHiddenOrHasHiddenAncestor, containsFirstResponder,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": createNewTab()
        case "w": if let selectedIdentifier { delegate?.sidebarWorkspaceView(self, closeItemWithIdentifier: selectedIdentifier) }
        case "l":
            if contentView != nil { return false }
            focusAddressField()
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }


    @objc private func createNewTab() {
        // Localization unneeded: this is an item kind, not a title.
        delegate?.sidebarWorkspaceView(self, createItemOfKind: "home")
    }
    @objc private func createCard(_ sender: SidebarChromeButton) {
        delegate?.sidebarWorkspaceView(self, createItemOfKind: sender.itemIdentifier)
    }
    @objc private func selectTab(_ sender: SidebarChromeButton) {
        delegate?.sidebarWorkspaceView(self, selectItemWithIdentifier: sender.itemIdentifier)
    }
    @objc private func closeTab(_ sender: SidebarChromeButton) {
        delegate?.sidebarWorkspaceView(self, closeItemWithIdentifier: sender.itemIdentifier)
    }
    @objc private func navigate() {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { delegate?.sidebarWorkspaceView(self, navigateToText: text) }
    }
    @objc private func expand() { delegate?.sidebarWorkspaceViewDidRequestExpand(self) }
    @objc private func showTools() { delegate?.sidebarWorkspaceViewDidRequestTools(self) }
    fileprivate func requestWidth(_ width: CGFloat) {
        guard width.isFinite else { return }
        delegate?.sidebarWorkspaceView(self, didChangeWidth: min(max(width, iTermSidebarWorkspaceState.minimumWidth),
                                                               iTermSidebarWorkspaceState.maximumWidth))
    }
}

private class SidebarFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Native NSButton tracking, keyboard activation, and accessibility, with the reference’s gray chrome.
private class SidebarChromeButton: NSButton {
    var itemIdentifier = ""
    var cardStyle = false
    var tabStyle = false
    var selectedTab = false
    var roundBackground = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if cardStyle || selectedTab || roundBackground || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.045).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: roundBackground ? bounds.height / 2 : cardStyle ? 16 : 9,
                         yRadius: roundBackground ? bounds.height / 2 : cardStyle ? 16 : 9).fill()
        }
        let imageSize: CGFloat = cardStyle ? 19 : 14
        let imageRect = NSRect(x: cardStyle ? 20 : tabStyle ? 11 : (bounds.width - imageSize) / 2,
                               y: cardStyle ? 22 : (bounds.height - imageSize) / 2,
                               width: imageSize, height: imageSize)
        if let image {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? image
            tinted.sidebarDrawAspectFitted(in: imageRect)
        }
        if cardStyle || tabStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let rect = cardStyle ? NSRect(x: 20, y: 56, width: max(0, bounds.width - 28), height: 22) :
                                  NSRect(x: 32, y: 8, width: max(0, bounds.width - 60), height: 19)
            (title as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: cardStyle ? 15 : 12,
                                                                                      weight: cardStyle ? .medium : .regular),
                                                               .foregroundColor: NSColor.labelColor,
                                                               .paragraphStyle: paragraph])
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill() }
}

private class SidebarAddressPill: SidebarFlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
        let image = NSImage(systemSymbolName: SFSymbol.magnifyingglass.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        image?.sidebarDrawAspectFitted(in: NSRect(x: 17, y: 14, width: 16, height: 16))
    }
}

private extension NSImage {
    func sidebarDrawAspectFitted(in bounds: NSRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fittedSize = NSSize(width: size.width * scale, height: size.height * scale)
        let fittedRect = NSRect(x: bounds.midX - fittedSize.width / 2, y: bounds.midY - fittedSize.height / 2,
                                width: fittedSize.width, height: fittedSize.height)
        draw(in: fittedRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private class SidebarResizeHandle: NSView {
    weak var workspace: iTermSidebarWorkspaceView?
    private var initialPoint = NSPoint.zero
    private var initialWidth: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        initialPoint = event.locationInWindow
        initialWidth = workspace?.bounds.width ?? 0
    }
    override func mouseDragged(with event: NSEvent) {
        workspace?.requestWidth(initialWidth - (event.locationInWindow.x - initialPoint.x))
    }
}
