import AppKit
import XCTest
#if !SIDEBAR_HOSTLESS
@testable import iTerm2SharedARC
#endif

final class SidebarWorkspaceViewTests: XCTestCase {
    func testBackgroundDrawingStaysWithinWorkspaceBounds() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 100).fill()
        let transform = NSAffineTransform()
        transform.translateX(by: 200, yBy: 0)
        transform.concat()
        let workspace = iTermSidebarWorkspaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        workspace.draw(NSRect(x: -200, y: 0, width: 400, height: 100))
        NSGraphicsContext.restoreGraphicsState()
        let outside = try XCTUnwrap(bitmap.colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(outside.redComponent - outside.greenComponent, 0.9,
                             "Workspace repaint must not cover the adjacent project or terminal area")
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private final class Delegate: NSObject, iTermSidebarWorkspaceViewDelegate {
        var created: [String] = []
        var selected: [String] = []
        var closed: [String] = []
        var navigated: [String] = []
        var expanded = 0
        var tools = 0
        var widths: [CGFloat] = []
        func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, createItemOfKind kind: String) { created.append(kind) }
        func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, selectItemWithIdentifier identifier: String) { selected.append(identifier) }
        func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, closeItemWithIdentifier identifier: String) { closed.append(identifier) }
        func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, navigateToText text: String) { navigated.append(text) }
        func sidebarWorkspaceViewDidRequestExpand(_ view: iTermSidebarWorkspaceView) { expanded += 1 }
        func sidebarWorkspaceViewDidRequestTools(_ view: iTermSidebarWorkspaceView) { tools += 1 }
        func sidebarWorkspaceView(_ view: iTermSidebarWorkspaceView, didChangeWidth width: CGFloat) { widths.append(width) }
    }

    private func button(in view: NSView, identifier: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0, identifier: identifier) }.first
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func key(_ character: String, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                         isARepeat: false, keyCode: 0)!
    }

    // Workspace shortcuts must not steal Cmd-T/W/L from the primary terminal.
    func testKeyboardActionsRequireWorkspaceFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentView!.bounds)
        let primary = FocusableView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let workspace = iTermSidebarWorkspaceView(frame: NSRect(x: 320, y: 0, width: 480, height: 800))
        container.addSubview(primary)
        container.addSubview(workspace)
        window.contentView = container
        let delegate = Delegate()
        workspace.delegate = delegate
        workspace.items = [iTermSidebarWorkspaceItem(identifier: "selected", title: "Shell", kind: "terminal",
                                                     sessionIdentifier: nil, state: [:])]
        workspace.selectedIdentifier = "selected"
        XCTAssertTrue(window.makeFirstResponder(primary))
        XCTAssertFalse(workspace.handleKeyEquivalent(key("t")))
        XCTAssertFalse(workspace.handleKeyEquivalent(key("w")))
        XCTAssertFalse(workspace.handleKeyEquivalent(key("l")))
        XCTAssertTrue(window.makeFirstResponder(workspace))
        XCTAssertTrue(workspace.handleKeyEquivalent(key("t")))
        XCTAssertTrue(workspace.handleKeyEquivalent(key("w")))
        XCTAssertTrue(workspace.handleKeyEquivalent(key("l")))
        XCTAssertTrue(workspace.containsFirstResponder)
        XCTAssertFalse(window.firstResponder === workspace)
        XCTAssertFalse(workspace.handleKeyEquivalent(key("t", modifiers: [.command, .shift])))
        XCTAssertEqual(delegate.created, ["home"])
        XCTAssertEqual(delegate.closed, ["selected"])
    }

    private final class FocusableController: NSViewController {
        override var acceptsFirstResponder: Bool { true }
    }

    func testControllerResponderBelongsToTheHostedContent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentView!.bounds)
        let workspace = iTermSidebarWorkspaceView(frame: NSRect(x: 320, y: 0, width: 480, height: 700))
        container.addSubview(workspace); window.contentView = container
        let hosted = FocusableController()
        hosted.view = NSView()
        workspace.contentView = hosted.view
        XCTAssertTrue(window.makeFirstResponder(hosted))
        XCTAssertTrue(workspace.containsFirstResponder)
        let outside = FocusableController()
        outside.view = NSView()
        container.addSubview(outside.view)
        XCTAssertTrue(window.makeFirstResponder(outside))
        XCTAssertFalse(workspace.containsFirstResponder)
    }

    // Terminal/browser views must actually be hosted and resized, rather than rendered as labels.
    func testContentHostReparentsAndResizesSuppliedView() throws {
        let view = iTermSidebarWorkspaceView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        let first = NSView()
        view.contentView = first
        view.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(first.superview)
        XCTAssertGreaterThan(first.frame.width, 300)
        XCTAssertGreaterThan(first.frame.height, 500)
        XCTAssertEqual(first.frame, host.bounds)
        view.frame.size.width = 360
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.frame.width, host.bounds.width)
        let second = NSView()
        view.contentView = second
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(first.superview)
        XCTAssertNotNil(second.superview)
        view.contentView = nil
        XCTAssertNil(second.superview)
    }

    // Each visible native control must route the intended item kind to the owner.
    func testLandingCardsAndToolbarRouteActions() throws {
        let view = iTermSidebarWorkspaceView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        let delegate = Delegate()
        view.delegate = delegate
        for kind in ["terminal", "files", "changes"] {
            let card = try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.create." + kind))
            XCTAssertFalse(card.accessibilityLabel()?.isEmpty ?? true)
            card.performClick(nil)
        }
        try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.newTab")).performClick(nil)
        try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.expand")).performClick(nil)
        try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.more")).performClick(nil)
        XCTAssertEqual(delegate.created, ["terminal", "files", "changes", "home"])
        XCTAssertEqual(delegate.expanded, 1)
        XCTAssertEqual(delegate.tools, 0)
        let more = try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.more"))
        let menu = try XCTUnwrap(more.menu)
        XCTAssertTrue(menu.items.contains { $0.representedObject as? String == "files" })
        XCTAssertTrue(menu.items.contains { $0.representedObject as? String == "terminal" })
        XCTAssertTrue(menu.items.contains { $0.representedObject as? String == "changes" })
        for kind in ["home", "terminal", "files", "changes", "tools"] {
            let item = try XCTUnwrap(menu.items.first { $0.representedObject as? String == kind })
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        }
        XCTAssertEqual(delegate.created, ["terminal", "files", "changes", "home", "home", "terminal", "files", "changes"])
        XCTAssertEqual(delegate.tools, 1)
    }

    // Index-based routing closes the wrong item after a preceding tab is removed.
    func testTabButtonsRouteStableIdentifiers() throws {
        let view = iTermSidebarWorkspaceView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        let delegate = Delegate()
        view.delegate = delegate
        view.items = ["first", "second"].map {
            iTermSidebarWorkspaceItem(identifier: $0, title: $0, kind: "terminal", sessionIdentifier: nil, state: [:])
        }
        view.selectedIdentifier = "first"
        try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.tab.second")).performClick(nil)
        try XCTUnwrap(button(in: view, identifier: "SidebarWorkspace.close.first")).performClick(nil)
        XCTAssertEqual(delegate.selected, ["second"])
        XCTAssertEqual(delegate.closed, ["first"])
    }
}
