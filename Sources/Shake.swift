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

    mutating func feed(x: CGFloat, time: TimeInterval, canFire: Bool = true) -> Bool {
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
        if canFire, turns.count >= sensitivity.reversals {
            reset()
            return true
        }
        return false
    }
}

struct DockWindow: Equatable {
    var owner: String
    var layer: Int
    var bounds: CGRect
    var onScreen: Bool
}

enum PollRate: Equatable { case off, slow, fast }

final class DragShakeMonitor {
    var onShake: ((NSPoint) -> Void)?
    var onRelease: (() -> Void)?
    var sensitivity: Sensitivity = .medium
    var enabled = true
    var ownRects: () -> [NSRect] = { [] }

    private var downMonitor: Any?
    private var timer: Timer?
    private var judge = DragJudge(sensitivity: .medium, downPoint: .zero, startedOnDock: false)
    private var dragCount = 0
    private var started = Date()
    private var downPoint = NSPoint.zero
    private var startedOnDock = false
    private var fired = false
    private var watcher: Timer?
    private var watcherRate: PollRate = .off
    private var wasDown = false
    private var moveMonitor: Any?
    private var lastStrip: Date?
    private var lastPopup: Date?
    private var lastPopupCheck = Date.distantPast

    static let dockLinger: TimeInterval = 120
    static let fastGrace: TimeInterval = 2
    static let popupCheckInterval: TimeInterval = 0.25
    static let edgeBand: CGFloat = 6
    static let hiddenTravel: CGFloat = 20

    var isPolling: Bool { watcher != nil }
    var rate: PollRate { watcherRate }

    func start() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, Self.shouldStart(fromMonitor: true, buttonDown: true, wasDown: false, tracking: self.timer != nil) else { return }
            self.mouseDown()
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            self.pointerMoved()
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
        pollRate(enabled: enabled, inStrip: nearDock, popupOpen: false, buttonDown: buttonDown,
                 lastStrip: lastNearDock, lastPopup: nil, now: now) != .off
    }

    static func pollRate(enabled: Bool, inStrip: Bool, popupOpen: Bool, buttonDown: Bool,
                         lastStrip: Date?, lastPopup: Date?, now: Date = Date()) -> PollRate {
        guard enabled else { return .off }
        if inStrip || popupOpen || buttonDown { return .fast }
        let recent = [lastStrip, lastPopup].compactMap { $0 }.map { now.timeIntervalSince($0) }.min()
        guard let recent else { return .off }
        if recent < fastGrace { return .fast }
        return recent < dockLinger ? .slow : .off
    }

    static func isFullScreen(_ bounds: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { s in bounds.width >= s.width - 1 && bounds.height >= s.height - 1 }
    }

    static func isDockPopup(_ w: DockWindow, screens: [CGRect], strips: [CGRect]) -> Bool {
        guard w.owner == "Dock", w.layer > 0, w.onScreen, !w.bounds.isEmpty else { return false }
        if isFullScreen(w.bounds, screens: screens) { return false }
        let isBar = strips.contains { strip in strip.insetBy(dx: -2, dy: -2).contains(w.bounds) }
        return !isBar
    }

    static func dockPopupOpen(_ windows: [DockWindow], screens: [CGRect], strips: [CGRect]) -> Bool {
        windows.contains { isDockPopup($0, screens: screens, strips: strips) }
    }

    static func pressOnDockPopup(_ point: CGPoint, windows: [DockWindow], screens: [CGRect], strips: [CGRect]) -> Bool {
        windows.contains { isDockPopup($0, screens: screens, strips: strips) && $0.bounds.contains(point) }
    }

    static func countsAsContent(pasteboardHasFile: Bool, startedOnDock: Bool, travel: CGFloat) -> Bool {
        pasteboardHasFile || (startedOnDock && travel >= 20)
    }

    static func countsAsContent(pasteboardHasFile: Bool, startedOnDock: Bool, dockDragWindow: Bool,
                                travel: CGFloat) -> Bool {
        if pasteboardHasFile || dockDragWindow { return true }
        return startedOnDock && travel >= hiddenTravel
    }

    struct DragWindow: Equatable {
        var owner: String
        var layer: Int
        var pid: Int
    }

    static var draggingLayer: Int { Int(CGWindowLevelForKey(.draggingWindow)) }

    static func dockDragWindowPresent(_ windows: [DragWindow], ownPid: Int, draggingLayer: Int = 500) -> Bool {
        windows.contains { $0.layer == draggingLayer && $0.owner == "Dock" && $0.pid != ownPid }
    }

    static func dragWindows() -> [DragWindow] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let level = draggingLayer
        return list.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == level else { return nil }
            return DragWindow(owner: w[kCGWindowOwnerName as String] as? String ?? "",
                              layer: layer, pid: w[kCGWindowOwnerPID as String] as? Int ?? 0)
        }
    }

    struct DragJudge {
        var detector: ShakeDetector
        var downPoint: CGPoint
        var startedOnDock: Bool
        var dockDragSeen = false
        var lastWindowCheck: TimeInterval = -1
        static let windowCheckInterval: TimeInterval = 0.1

        init(sensitivity: Sensitivity, downPoint: CGPoint, startedOnDock: Bool) {
            detector = ShakeDetector(sensitivity: sensitivity)
            self.downPoint = downPoint
            self.startedOnDock = startedOnDock
        }

        mutating func needsWindowCheck(at time: TimeInterval, pasteboardHasFile: Bool) -> Bool {
            guard !dockDragSeen, !pasteboardHasFile else { return false }
            guard lastWindowCheck < 0 || time - lastWindowCheck >= Self.windowCheckInterval else { return false }
            lastWindowCheck = time
            return true
        }

        mutating func feed(time: TimeInterval, point: CGPoint, pasteboardHasFile: Bool, dockDragWindow: Bool?) -> Bool {
            if dockDragWindow == true { dockDragSeen = true }
            let travel = hypot(point.x - downPoint.x, point.y - downPoint.y)
            let content = DragShakeMonitor.countsAsContent(pasteboardHasFile: pasteboardHasFile, startedOnDock: startedOnDock,
                                                           dockDragWindow: dockDragSeen, travel: travel)
            return detector.feed(x: point.x, time: time, canFire: content)
        }
    }

    private static var screenGeometry: [(frame: NSRect, visible: NSRect)] {
        NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
    }

    private static var cgScreens: [CGRect] {
        guard let h = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: h - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    private static var cgStrips: [CGRect] {
        guard let h = NSScreen.screens.first?.frame.height else { return [] }
        return screenGeometry.flatMap { dockStrips(frame: $0.frame, visible: $0.visible) }
            .map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) }
    }

    static func dockWindows() -> [DockWindow] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Dock",
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return DockWindow(owner: "Dock", layer: w[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                              onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? true)
        }
    }

    private var dockSessionActive: Bool {
        Self.pollRate(enabled: true, inStrip: false, popupOpen: false, buttonDown: false,
                      lastStrip: lastStrip, lastPopup: lastPopup) != .off
    }

    private func checkPopup(force: Bool = false) -> Bool {
        let now = Date()
        guard force || now.timeIntervalSince(lastPopupCheck) >= Self.popupCheckInterval else {
            return lastPopup.map { now.timeIntervalSince($0) < Self.popupCheckInterval * 2 } ?? false
        }
        lastPopupCheck = now
        let open = Self.dockPopupOpen(Self.dockWindows(), screens: Self.cgScreens, strips: Self.cgStrips)
        if open { lastPopup = now }
        return open
    }

    private func pointerMoved() {
        guard enabled else { stopPolling(); return }
        let strip = Self.inDockArea(NSEvent.mouseLocation, screens: Self.screenGeometry)
        if strip { lastStrip = Date() }
        let popup = (!strip && dockSessionActive) ? checkPopup() : false
        updatePolling(strip: strip, popup: popup, buttonDown: wasDown || timer != nil)
    }

    private func updatePolling(strip: Bool, popup: Bool, buttonDown: Bool) {
        let want = Self.pollRate(enabled: enabled, inStrip: strip, popupOpen: popup, buttonDown: buttonDown,
                                 lastStrip: lastStrip, lastPopup: lastPopup)
        guard want != watcherRate else { return }
        watcher?.invalidate()
        watcher = nil
        watcherRate = want
        guard want != .off else { wasDown = false; return }
        let interval = want == .fast ? 1.0 / 20.0 : 1.0 / 4.0
        let w = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.watch() }
        w.tolerance = want == .fast ? 0.05 : 0.1
        RunLoop.main.add(w, forMode: .common)
        watcher = w
    }

    private func stopPolling() {
        watcher?.invalidate()
        watcher = nil
        watcherRate = .off
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
        let strip = Self.inDockArea(NSEvent.mouseLocation, screens: Self.screenGeometry)
        if strip { lastStrip = Date() }
        if Self.shouldStart(fromMonitor: false, buttonDown: isDown, wasDown: wasDown, tracking: timer != nil) {
            wasDown = isDown
            mouseDown()
            return
        }
        wasDown = isDown
        let popup = (!strip && !isDown && dockSessionActive) ? checkPopup() : false
        updatePolling(strip: strip, popup: popup, buttonDown: isDown || timer != nil)
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
        fired = false
        let strip = Self.inDockArea(point, screens: Self.screenGeometry)
        if strip { lastStrip = Date() }
        switch Self.dockLookupPlan(inStrip: strip, dockSession: dockSessionActive) {
        case .strip:
            startedOnDock = true
        case .lookup:
            let h = NSScreen.screens.first?.frame.height ?? 0
            startedOnDock = Self.pressOnDockPopup(CGPoint(x: point.x, y: h - point.y), windows: Self.dockWindows(),
                                                  screens: Self.cgScreens, strips: Self.cgStrips)
        case .skip:
            startedOnDock = false
        }
        judge = DragJudge(sensitivity: sensitivity, downPoint: point, startedOnDock: startedOnDock)
        started = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updatePolling(strip: strip, popup: false, buttonDown: true)
    }

    private func tick() {
        guard CGEventSource.buttonState(.hidSystemState, button: .left) else {
            timer?.invalidate()
            timer = nil
            if fired {
                fired = false
                onRelease?()
            }
            pointerMoved()
            return
        }
        guard !fired else { return }
        let p = NSEvent.mouseLocation
        let time = Date().timeIntervalSince(started)
        let pbFile = isContentDrag(since: dragCount)
        var dockWindow: Bool?
        if judge.needsWindowCheck(at: time, pasteboardHasFile: pbFile) {
            dockWindow = Self.dockDragWindowPresent(Self.dragWindows(), ownPid: Int(ProcessInfo.processInfo.processIdentifier),
                                                    draggingLayer: Self.draggingLayer)
        }
        if judge.feed(time: time, point: p, pasteboardHasFile: pbFile, dockDragWindow: dockWindow) {
            fired = true
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
