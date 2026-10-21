import AppKit
import ServiceManagement
import SwiftUI

func trayTemplate(size: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let k = size / 18
        func card(_ x: CGFloat, _ y: CGFloat, _ angle: CGFloat) -> NSBezierPath {
            let rect = NSRect(x: x * k, y: y * k, width: 5.8 * k, height: 7.8 * k)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5 * k, yRadius: 1.5 * k)
            var t = AffineTransform(translationByX: rect.midX, byY: rect.midY)
            t.rotate(byDegrees: angle)
            t.translate(x: -rect.midX, y: -rect.midY)
            path.transform(using: t)
            return path
        }
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: 1.2 * k, y: 10.4 * k))
        tray.line(to: NSPoint(x: 16.8 * k, y: 10.4 * k))
        tray.line(to: NSPoint(x: 15.6 * k, y: 14.6 * k))
        tray.curve(to: NSPoint(x: 13.6 * k, y: 16.2 * k), controlPoint1: NSPoint(x: 15.3 * k, y: 15.6 * k), controlPoint2: NSPoint(x: 14.6 * k, y: 16.2 * k))
        tray.line(to: NSPoint(x: 4.4 * k, y: 16.2 * k))
        tray.curve(to: NSPoint(x: 2.4 * k, y: 14.6 * k), controlPoint1: NSPoint(x: 3.4 * k, y: 16.2 * k), controlPoint2: NSPoint(x: 2.7 * k, y: 15.6 * k))
        tray.close()
        let back = card(8.9, 2.6, 11)
        let front = card(3.6, 3.4, -8)
        let ctx = NSGraphicsContext.current
        NSColor.black.setFill()
        NSColor.black.setStroke()
        back.fill()
        ctx?.compositingOperation = .clear
        front.lineWidth = 2.0 * k
        front.stroke()
        front.fill()
        ctx?.compositingOperation = .sourceOver
        front.fill()
        ctx?.compositingOperation = .clear
        tray.lineWidth = 2.0 * k
        tray.stroke()
        ctx?.compositingOperation = .sourceOver
        tray.fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = Identity.appName
    return image
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let shelves = ShelfManager()
    private let settings = SettingsWindow()
    private let setup = SetupWindow()
    private var fresh = false
    private let shake = DragShakeMonitor()
    private var statusItem: NSStatusItem?
    private var launchedAtLogin = false
    private var gotFiles = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        fresh = !FileManager.default.fileExists(atPath: Config.fileURL.path)
        launchedAtLogin = Self.isLoginLaunch()
        let me = ProcessInfo.processInfo.processIdentifier
        let others = SingleInstance.others(bundleId: Identity.bundleId, own: me)
        guard SingleInstance.shouldExit(otherPIDs: others.map(\.processIdentifier), own: me) else { return }
        let quiet = launchedAtLogin || CommandLine.arguments.contains("--background")
        if !quiet, let other = others.first, let url = other.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
            return
        }
        exit(0)
    }

    private static func isLoginLaunch() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 300
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !SingleInstance.shouldExit(otherPIDs: SingleInstance.others(bundleId: Identity.bundleId, own: ProcessInfo.processInfo.processIdentifier).map(\.processIdentifier), own: ProcessInfo.processInfo.processIdentifier) else { return }
        NSApp.setActivationPolicy(.accessory)
        ShelfModel.cleanLeftovers()
        Updates.shared.start()
        settings.model.onChange = { [weak self] in self?.apply() }
        settings.model.runSetup = { [weak self] in self?.openSetup() }
        shelves.autoClose = { Config.current.autoClose }
        shelves.startExpanded = { Config.current.openExpanded }
        shelves.startLocked = { Config.current.startLocked }
        shelves.keepEmpty = { Config.current.keepEmpty }
        HotKey.shared.onPress = { [weak self] in self?.shelves.newShelf() }
        shake.onShake = { [weak self] point in self?.shelves.shake(at: point) }
        shake.onRelease = { [weak self] in self?.shelves.shakeDragEnded() }
        shake.ownRects = { [weak self] in
            let others = NSApp.windows.filter { $0.isVisible && !($0 is ShelfPanel) }.map(\.frame)
            return (self?.shelves.cardFrames ?? []) + others
        }
        NSApp.mainMenu = MainMenu.make(app: self, name: Identity.appName)
        shake.start()
        apply()
        let args = CommandLine.arguments
        if args.contains("--new-shelf") { shelves.newShelf() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.gotFiles, !self.launchedAtLogin, !args.contains("--background"),
                  !args.contains("--new-shelf") else { return }
            if StashSetup.shouldOfferSetup(fresh: self.fresh, background: false, gotFiles: self.gotFiles) {
                self.setup.onFinish = { [weak self] in self?.setupFinished() }
                self.setup.show()
            } else {
                self.settings.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shelves.closeAll()
        ShelfModel.cleanLeftovers()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        gotFiles = true
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        shelves.add(files)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private func apply() {
        let cfg = Config.load()
        HotKey.shared.register(cfg.hotkey)
        shake.enabled = cfg.shake
        shake.sensitivity = cfg.sensitivity
        shake.refresh()
        let svc = SMAppService.mainApp
        if cfg.launchAtLogin {
            if svc.status != .enabled { try? svc.register() }
        } else if svc.status == .enabled {
            try? svc.unregister()
        }
        if cfg.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = trayTemplate()
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = Config.current
        menu.addItem(withTitle: "New Shelf", action: #selector(newShelf), keyEquivalent: "").target = self
        let closeAll = menu.addItem(withTitle: "Close All Shelves", action: #selector(closeAllShelves), keyEquivalent: "")
        closeAll.target = self
        closeAll.isEnabled = shelves.isAnyVisible
        if cfg.hotkey != "off" {
            let hint = NSMenuItem(title: "Hotkey: \(hotkeyName(cfg.hotkey))", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Set Up \(Identity.appName)…", action: #selector(openSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Identity.appName)", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func newShelf(_ sender: Any? = nil) { shelves.newShelf() }
    @objc private func closeAllShelves(_ sender: Any? = nil) { shelves.closeAll() }
    @objc private func openSettings(_ sender: Any? = nil) { settings.show() }
    @objc private func openSetup(_ sender: Any? = nil) {
        setup.onFinish = { [weak self] in self?.setupFinished() }
        setup.show()
    }

    private func setupFinished() {
        apply()
        let fresh = Config.load()
        if settings.model.cfg != fresh { settings.model.cfg = fresh }
    }
    @objc private func checkUpdates(_ sender: Any? = nil) { Updates.shared.checkNow() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == NSSelectorFromString("closeAllShelves:") { return shelves.isAnyVisible }
        return true
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--login-off") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.run()
}
