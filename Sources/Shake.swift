import AppKit

enum Sensitivity: String, CaseIterable, Codable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var reversals: Int {
        switch self {
        case .low: 4
        case .medium: 3
        case .high: 2
        }
    }

    var travel: CGFloat {
        switch self {
        case .low: 60
        case .medium: 40
        case .high: 25
        }
    }
}

struct ShakeDetector {
    var sensitivity: Sensitivity = .medium
    var window: TimeInterval = 1.0

    private var lastX: CGFloat?
    private var anchorX: CGFloat = 0
    private var direction = 0
    private var turns: [TimeInterval] = []

    init(sensitivity: Sensitivity = .medium) {
        self.sensitivity = sensitivity
    }

    mutating func reset() {
        lastX = nil
        direction = 0
        turns.removeAll()
    }

    mutating func feed(x: CGFloat, time: TimeInterval) -> Bool {
        guard let last = lastX else {
            lastX = x
            anchorX = x
            return false
        }
        lastX = x
        let step = x - last
        guard step != 0 else { return false }
        let dir = step > 0 ? 1 : -1
        if direction == 0 {
            direction = dir
            anchorX = last
            return false
        }
        if dir != direction {
            if abs(last - anchorX) >= sensitivity.travel {
                turns.append(time)
            }
            direction = dir
            anchorX = last
        }
        turns.removeAll { time - $0 > window }
        if turns.count >= sensitivity.reversals {
            reset()
            return true
        }
        return false
    }
}

final class DragShakeMonitor {
    var onShake: ((NSPoint) -> Void)?
    var sensitivity: Sensitivity = .medium
    var enabled = true
    var ownRects: () -> [NSRect] = { [] }

    private var downMonitor: Any?
    private var timer: Timer?
    private var detector = ShakeDetector()
    private var dragCount = 0
    private var started = Date()
    private var downPoint = NSPoint.zero
    private var startedOnDock = false
    private var watcher: Timer?
    private var wasDown = false
    private var moveMonitor: Any?
    private var lastNearDock: Date?

    static let dockLinger: TimeInterval = 15
    static let edgeBand: CGFloat = 6

    var isPolling: Bool { watcher != nil }

    func start() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, Self.shouldStart(fromMonitor: true, buttonDown: true, wasDown: false, tracking: self.timer != nil) else { return }
            self.mouseDown()
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.pointerMoved()
        }
        pointerMoved()
    }

    static func dockStrips(frame: NSRect, visible: NSRect, band: CGFloat = edgeBand) -> [NSRect] {
        var out: [NSRect] = []
        let bottom = max(visible.minY - frame.minY, band)
        out.append(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: bottom))
        let left = max(visible.minX - frame.minX, band)
        out.append(NSRect(x: frame.minX, y: frame.minY, width: left, height: frame.height))
        let right = max(frame.maxX - visible.maxX, band)
        out.append(NSRect(x: frame.maxX - right, y: frame.minY, width: right, height: frame.height))
        return out
    }

    static func inDockArea(_ point: NSPoint, screens: [(frame: NSRect, visible: NSRect)]) -> Bool {
        screens.contains { s in s.frame.contains(point) && dockStrips(frame: s.frame, visible: s.visible).contains { $0.contains(point) } }
    }

    static func shouldPoll(enabled: Bool, nearDock: Bool, lastNearDock: Date?, buttonDown: Bool, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if nearDock || buttonDown { return true }
        guard let lastNearDock else { return false }
        return now.timeIntervalSince(lastNearDock) < dockLinger
    }

    private static var screenGeometry: [(frame: NSRect, visible: NSRect)] {
        NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
    }

    private var dockSessionActive: Bool {
        guard let lastNearDock else { return false }
        return Date().timeIntervalSince(lastNearDock) < Self.dockLinger
    }

    private func pointerMoved() {
        guard enabled else { stopPolling(); return }
        let near = Self.inDockArea(NSEvent.mouseLocation, screens: Self.screenGeometry)
        if near { lastNearDock = Date() }
        if Self.shouldPoll(enabled: enabled, nearDock: near, lastNearDock: lastNearDock, buttonDown: wasDown) {
            startPolling()
        }
    }

    private func startPolling() {
        guard watcher == nil else { return }
        let w = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.watch() }
        w.tolerance = 0.05
        RunLoop.main.add(w, forMode: .common)
        watcher = w
    }

    private func stopPolling() {
        watcher?.invalidate()
        watcher = nil
        wasDown = false
    }

    func refresh() {
        if !enabled { stopPolling(); timer?.invalidate(); timer = nil } else { pointerMoved() }
    }

    static func shouldStart(fromMonitor: Bool, buttonDown: Bool, wasDown: Bool, tracking: Bool) -> Bool {
        guard !tracking else { return false }
        return fromMonitor || (buttonDown && !wasDown)
    }

    private func watch() {
        guard enabled else { stopPolling(); return }
        let isDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        if Self.inDockArea(NSEvent.mouseLocation, screens: Self.screenGeometry) { lastNearDock = Date() }
        if Self.shouldStart(fromMonitor: false, buttonDown: isDown, wasDown: wasDown, tracking: timer != nil) {
            wasDown = isDown
            mouseDown()
            return
        }
        wasDown = isDown
        if !Self.shouldPoll(enabled: enabled, nearDock: false, lastNearDock: lastNearDock, buttonDown: isDown || timer != nil) {
            stopPolling()
        }
    }

    func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        downMonitor = nil
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        stopPolling()
        timer?.invalidate()
        timer = nil
    }

    private func mouseDown() {
        guard enabled else { return }
        let point = NSEvent.mouseLocation
        guard !Self.startsInOwnWindow(point, rects: ownRects()) else { return }
        dragCount = NSPasteboard(name: .drag).changeCount
        downPoint = point
        let strip = Self.inDockArea(point, screens: Self.screenGeometry)
        if strip { lastNearDock = Date() }
        startedOnDock = Self.dockLookupPlan(inStrip: strip, dockSession: dockSessionActive) == .strip
            || (Self.dockLookupPlan(inStrip: strip, dockSession: dockSessionActive) == .lookup && Self.isDockWindow(at: point))
        detector = ShakeDetector(sensitivity: sensitivity)
        started = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard CGEventSource.buttonState(.hidSystemState, button: .left) else {
            timer?.invalidate()
            timer = nil
            return
        }
        let p = NSEvent.mouseLocation
        let travel = hypot(p.x - downPoint.x, p.y - downPoint.y)
        guard Self.countsAsContent(pasteboardHasFile: isContentDrag(since: dragCount),
                                   startedOnDock: startedOnDock, travel: travel) else { return }
        if detector.feed(x: p.x, time: Date().timeIntervalSince(started)) {
            timer?.invalidate()
            timer = nil
            onShake?(p)
        }
    }

    enum DockLookup: Equatable { case strip, lookup, skip }

    static func dockLookupPlan(inStrip: Bool, dockSession: Bool) -> DockLookup {
        if inStrip { return .strip }
        return dockSession ? .lookup : .skip
    }

    static func startsInOwnWindow(_ point: NSPoint, rects: [NSRect]) -> Bool {
        rects.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }

    static func countsAsContent(pasteboardHasFile: Bool, startedOnDock: Bool, travel: CGFloat) -> Bool {
        pasteboardHasFile || (startedOnDock && travel >= 20)
    }

    static func isDockWindow(at point: NSPoint) -> Bool {
        guard let height = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let cg = CGPoint(x: point.x, y: height - point.y)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        for window in list {
            if window[kCGWindowOwnerPID as String] as? Int == me { continue }
            guard let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(cg) else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            return Self.isDock(owner: owner, layer: layer)
        }
        return false
    }

    static func isDock(owner: String?, layer: Int) -> Bool {
        owner == "Dock" && layer > 0
    }

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "com.google.Chrome.beta", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    static let linkTypes: Set<String> = [
        "com.apple.web-internet-location", "com.microsoft.internet-shortcut", "public.url",
        "com.apple.webarchive", "public.html",
    ]

    static let linkExtensions: Set<String> = ["webloc", "url", "inetloc", "webarchive"]

    static let promiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url", "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-content-type", "NSPromiseContentsPboardType",
        kPasteboardTypeFileURLPromise as String,
    ]

    static func isBrowserPrivate(_ type: String) -> Bool {
        type.hasPrefix("chromium/") || type.hasPrefix("org.chromium.") || type.hasPrefix("com.apple.safari.")
            || type.hasPrefix("com.apple.Safari") || type.hasPrefix("org.mozilla.") || type.hasPrefix("application/x-moz")
            || type == "text/x-moz-url" || type == "WebURLsWithTitlesPboardType"
    }

    static func acceptsDrag(types: [String], realFiles: Bool, promisedTypes: [String], browserFront: Bool) -> Bool {
        if realFiles { return true }
        if browserFront { return false }
        if types.contains(where: isBrowserPrivate) { return false }
        guard types.contains(where: promiseTypes.contains) else { return false }
        if promisedTypes.isEmpty { return !types.contains("public.url") }
        return promisedTypes.contains { !linkTypes.contains($0) }
    }

    static func frontmostIsBrowser() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(browsers.contains) ?? false
    }

    static func evaluate(_ pb: NSPasteboard) -> Bool {
        let types = (pb.types ?? []).map(\.rawValue)
        let browserFront = frontmostIsBrowser()
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let real = files.filter { url in
            FileManager.default.fileExists(atPath: url.path)
                && !(browserFront && linkExtensions.contains(url.pathExtension.lowercased()))
        }
        let promised = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .init("com.apple.pasteboard.promised-file-content-type")) }
        return acceptsDrag(types: types, realFiles: !real.isEmpty, promisedTypes: promised, browserFront: browserFront)
    }

    private var evaluatedCount = -1
    private var evaluatedResult = false

    private func isContentDrag(since count: Int) -> Bool {
        let pb = NSPasteboard(name: .drag)
        let now = pb.changeCount
        guard now != count else { return false }
        if now != evaluatedCount {
            evaluatedCount = now
            evaluatedResult = Self.evaluate(pb)
        }
        return evaluatedResult
    }
}
