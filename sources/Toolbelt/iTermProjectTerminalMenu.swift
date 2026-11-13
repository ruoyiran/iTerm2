import AppKit

/// The same explicit opening choices are used by project rows and file-tree entries.
final class iTermProjectTerminalMenu {
    private struct Choice {
        let style: iTermOpenStyle
        let title: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    private static let choices = [
        Choice(style: .tab, title: String(localized: "Projects.OpenTerminalNewTab", defaultValue: "New Tab", comment: "Open a new terminal in the chosen directory in a new tab"), key: "t", modifiers: .command),
        Choice(style: .verticalSplit, title: String(localized: "Projects.OpenTerminalSplitRight", defaultValue: "Split Left and Right", comment: "Open a new terminal beside the current pane, with a vertical divider"), key: "d", modifiers: .command),
        Choice(style: .horizontalSplit, title: String(localized: "Projects.OpenTerminalSplitDown", defaultValue: "Split Top and Bottom", comment: "Open a new terminal below the current pane, with a horizontal divider"), key: "D", modifiers: [.command, .shift]),
        Choice(style: .window, title: String(localized: "Projects.OpenTerminalNewWindow", defaultValue: "New Window", comment: "Open a new terminal in the chosen directory in a separate window"), key: "n", modifiers: .command)
    ]

    static func style(for event: NSEvent) -> iTermOpenStyle? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let leaderFlag = NSEvent.ModifierFlags(rawValue: iTermEventModifierFlags.leaderModifierFlag.rawValue)
        guard !event.modifierFlags.contains(leaderFlag) else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return choices.first { $0.key.lowercased() == key && $0.modifiers == modifiers }?.style
    }

    static func make(target: AnyObject, action: Selector, includeShortcuts: Bool = false, canOpen: (iTermOpenStyle) -> Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices {
            let item = NSMenuItem(title: choice.title, action: action, keyEquivalent: includeShortcuts ? choice.key : "")
            if includeShortcuts { item.keyEquivalentModifierMask = choice.modifiers }
            item.target = target
            item.tag = Int(choice.style.rawValue)
            item.isEnabled = canOpen(choice.style)
            if !item.isEnabled {
                item.toolTip = String(localized: "Projects.TerminalModeUnavailable", defaultValue: "This opening mode is unavailable for the current terminal or layout.", comment: "Tooltip for a disabled terminal opening menu item")
            }
            menu.addItem(item)
        }
        return menu
    }
}
