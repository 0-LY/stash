import AppKit
import Quartz

enum ShelfKey: Equatable {
    case quickLook
    case move(dx: Int, dy: Int)
    case escape
    case open
    case none

    static func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ShelfKey {
        let mods = flags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return .none }
        switch keyCode {
        case 49: return .quickLook
        case 53: return .escape
        case 36, 76: return .open
        case 123: return .move(dx: -1, dy: 0)
        case 124: return .move(dx: 1, dy: 0)
        case 125: return .move(dx: 0, dy: 1)
        case 126: return .move(dx: 0, dy: -1)
        default: return .none
        }
    }
}

enum ShelfCommand {
    case copy, selectAll, delete, quickLook, open, close

    static func isEnabled(_ command: ShelfCommand, items: Int, selected: Int, expanded: Bool) -> Bool {
        switch command {
        case .copy, .quickLook: return items > 0
        case .selectAll: return expanded && items > 0
        case .delete: return selected > 0
        case .open: return expanded ? selected > 0 : items > 0
        case .close: return true
        }
    }
}

enum Navigation {
    static let columns = 3

    static func nextIndex(current: Int?, dx: Int, dy: Int, count: Int, columns: Int = columns) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else {
            return dx + dy >= 0 ? 0 : count - 1
        }
        let next = current + dx + dy * columns
        return min(max(next, 0), count - 1)
    }

    static func rotated<T>(_ items: [T], by step: Int) -> [T] {
        guard items.count > 1, step != 0 else { return items }
        let n = items.count
        let k = ((step % n) + n) % n
        return Array(items[k...] + items[..<k])
    }

    static func quickLookPlan(selected: [UUID], order: [UUID], expanded: Bool) -> (ids: [UUID], start: Int) {
        if expanded, !selected.isEmpty { return (selected, 0) }
        guard !order.isEmpty else { return ([], 0) }
        return expanded ? (order, 0) : (order, order.count - 1)
    }

    static func openTargets(selected: [UUID], order: [UUID], expanded: Bool) -> [UUID] {
        if expanded, !selected.isEmpty { return selected }
        if !expanded, let last = order.last { return [last] }
        return []
    }
}

enum ItemMenu {
    static let titles = ["Quick Look", "Open", "Show in Finder", "Copy", "Remove"]

    static func make(count: Int, quickLook: @escaping () -> Void, open: @escaping () -> Void,
                     reveal: @escaping () -> Void, copy: @escaping () -> Void, remove: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let suffix = count > 1 ? " \(count) Items" : ""
        let actions = [quickLook, open, reveal, copy, remove]
        for (index, title) in titles.enumerated() {
            if index == 4 { menu.addItem(.separator()) }
            let item = BlockMenuItem(title: index == 1 || index == 3 || index == 4 ? title + suffix : title,
                                     action: actions[index])
            menu.addItem(item)
        }
        return menu
    }
}

final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void

    init(title: String, key: String = "", action block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { block() }
}

final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []
    var frames: [NSRect] = []
    var images: [NSImage?] = []
    var start = 0

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    private func index(of item: QLPreviewItem?) -> Int? {
        guard let url = item?.previewItemURL else { return nil }
        return urls.firstIndex(of: url)
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let i = index(of: item), frames.indices.contains(i) else { return .zero }
        return frames[i]
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let i = index(of: item) else { return nil }
        if images.indices.contains(i), let image = images[i] { return image }
        return NSWorkspace.shared.icon(forFile: urls[i].path)
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { false }
}

enum MainMenu {
    static func make(app target: AnyObject, name: String) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: name)
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", "openSettings", ",", target)
        add(appMenu, "Set Up \(name)…", "openSetup", "", target)
        add(appMenu, "Check for Updates…", "checkUpdates", "", target)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        attach(appMenu, to: main, title: name)

        let file = NSMenu(title: "File")
        add(file, "New Shelf", "newShelf", "n", target)
        file.addItem(withTitle: "Quick Look", action: #selector(ShelfPanel.toggleQuickLook(_:)), keyEquivalent: "y")
        file.addItem(withTitle: "Open", action: #selector(ShelfPanel.openItems(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, "Close All Shelves", "closeAllShelves", "", target)
        attach(file, to: main, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(ShelfPanel.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let delete = edit.addItem(withTitle: "Remove from Shelf", action: #selector(ShelfPanel.delete(_:)),
                                  keyEquivalent: String(UnicodeScalar(UInt8(NSBackspaceCharacter))))
        delete.keyEquivalentModifierMask = .command
        attach(edit, to: main, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        attach(window, to: main, title: "Window")
        NSApp.windowsMenu = window
        return main
    }

    private static func add(_ menu: NSMenu, _ title: String, _ selector: String, _ key: String, _ target: AnyObject) {
        menu.addItem(withTitle: title, action: NSSelectorFromString(selector + ":"), keyEquivalent: key).target = target
    }

    private static func attach(_ menu: NSMenu, to main: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
