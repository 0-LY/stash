import AppKit
import Quartz
import Combine
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isTemporary: Bool
    var thumbnail: NSImage?
    var isPreview = false

    var name: String { url.lastPathComponent }

    static func == (a: ShelfItem, b: ShelfItem) -> Bool {
        a.id == b.id && a.thumbnail === b.thumbnail && a.isPreview == b.isPreview
    }

    static func wantsPreview(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }
}

struct Selection: Equatable {
    private(set) var ids: Set<UUID> = []
    private(set) var anchor: UUID?

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func click(_ id: UUID, in order: [UUID], command: Bool = false, shift: Bool = false) {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            let range = Set(order[min(a, b)...max(a, b)])
            ids = command ? ids.union(range) : range
            return
        }
        if command {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        } else {
            ids = [id]
        }
        anchor = id
    }

    mutating func selectAll(_ order: [UUID]) {
        ids = Set(order)
        anchor = order.first
    }

    mutating func clear() {
        ids.removeAll()
        anchor = nil
    }

    mutating func keep(_ order: [UUID]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
    }

    func allSelected(_ order: [UUID]) -> Bool { !order.isEmpty && ids.isSuperset(of: order) }

    func targets(_ order: [UUID]) -> [UUID] { ids.isEmpty ? order : order.filter(ids.contains) }

    func dragTargets(for id: UUID, in order: [UUID]) -> [UUID] {
        ids.contains(id) ? order.filter(ids.contains) : [id]
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = []
    @Published var targeted = false
    @Published var hovered: UUID?
    @Published var expanded = false
    @Published var selection = Selection()
    @Published var shown = false
    @Published var pileHovered = false
    @Published var lifting = false
    @Published var shift = CGSize.zero
    @Published var locked = false
    @Published var focus: UUID?
    var willExpand: () -> Void = {}
    var requestQuickLook: ([UUID]?) -> Void = { _ in }

    var selectedIDs: [UUID] { order.filter(selection.contains) }

    func open(_ ids: [UUID]) {
        let list = urls(for: ids)
        guard !list.isEmpty else { return }
        let risky = list.filter(OpenGuard.needsConfirmation)
        if !risky.isEmpty, !OpenGuard.confirm(risky) { return }
        for url in list { NSWorkspace.shared.open(url) }
    }

    func reveal(_ ids: [UUID]) {
        let list = urls(for: ids)
        guard !list.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(list)
    }

    func copy(_ ids: [UUID]) {
        let list = urls(for: ids)
        guard !list.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(list as [NSURL])
    }

    func move(dx: Int, dy: Int) {
        guard !items.isEmpty else { return }
        if expanded {
            let current = selection.anchor.flatMap { order.firstIndex(of: $0) } ?? selectedIDs.first.flatMap { order.firstIndex(of: $0) }
            guard let next = Navigation.nextIndex(current: current, dx: dx, dy: dy, count: items.count) else { return }
            select(order[next])
            focus = order[next]
        } else if dx != 0 {
            withAnimation(springAnim) { items = Navigation.rotated(items, by: dx > 0 ? 1 : -1) }
        }
    }

    func itemMenu(for id: UUID) -> NSMenu {
        if !selection.contains(id) { select(id) }
        return menu(for: dragIDs(for: id), quickLook: { [weak self] ids in self?.requestQuickLook(ids) })
    }

    func menu(forSelection: Void) -> NSMenu {
        let ids = selectedIDs
        return menu(for: ids, quickLook: { [weak self] ids in self?.requestQuickLook(ids) })
    }

    func pileMenu() -> NSMenu {
        menu(for: order, quickLook: { [weak self] _ in self?.requestQuickLook(nil) })
    }

    private func menu(for ids: [UUID], quickLook: @escaping ([UUID]) -> Void) -> NSMenu {
        ItemMenu.make(count: ids.count,
                      quickLook: { quickLook(ids) },
                      open: { [weak self] in self?.open(ids) },
                      reveal: { [weak self] in self?.reveal(ids) },
                      copy: { [weak self] in self?.copy(ids) },
                      remove: { [weak self] in
                          guard let self else { return }
                          withAnimation(self.springAnim) { self.remove(ids) }
                      })
    }

    nonisolated static func countText(total: Int, selected: Int) -> String {
        selected > 0 ? "\(selected)/\(total)" : "\(total)"
    }

    var countText: String {
        Self.countText(total: items.count, selected: order.filter(selection.contains).count)
    }

    nonisolated static func closesAfterDragOut(locked: Bool, moved: Bool, everything: Bool, autoClose: Bool) -> Bool {
        dragOutPlan(locked: locked, moved: moved, everything: everything, autoClose: autoClose).close
    }

    nonisolated static func dragOutPlan(locked: Bool, moved: Bool, everything: Bool, autoClose: Bool) -> (remove: Bool, close: Bool) {
        guard moved, !locked else { return (false, false) }
        return (true, everything && autoClose)
    }

    nonisolated static let tempHold: TimeInterval = 10

    nonisolated static func deletionDelay(lastDragOut: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastDragOut else { return 0 }
        return max(0, tempHold - now.timeIntervalSince(lastDragOut))
    }

    @Published var leaving: Set<UUID> = []

    func finishDragOut(_ ids: [UUID], moved: Bool, autoClose: Bool, animated: Bool = true) {
        let present = order.filter(Set(ids).contains)
        guard !present.isEmpty else { return }
        let plan = Self.dragOutPlan(locked: locked, moved: moved, everything: present.count == items.count, autoClose: autoClose)
        guard plan.remove else { return }
        lastDragOut = Date()
        guard animated else {
            remove(present, closeWhenEmpty: plan.close)
            return
        }
        let fade = Self.reduceMotion ? 0.15 : 0.18 / pace
        withAnimation(.easeOut(duration: fade)) { leaving.formUnion(present) }
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let still = present.filter { id in self.items.contains { $0.id == id } }
                withAnimation(self.springAnim) {
                    self.remove(still, closeWhenEmpty: plan.close)
                    self.leaving.subtract(present)
                }
            }
        }
    }

    func toggleLock() {
        withAnimation(springAnim) { locked.toggle() }
    }

    var pace: Double = 1
    var morphAnim: Animation { Self.morph.speed(pace) }
    var springAnim: Animation { Self.spring.speed(pace) }
    func fadeAnim(showing: Bool, matched: Bool) -> Animation { Self.fade(showing: showing, matched: matched).speed(pace) }
    private var lastDragOut: Date?

    static let margin: CGFloat = 30
    static let compactSize = NSSize(width: 120, height: 140)

    static let chrome: CGFloat = 81

    static func expandedSize(count: Int) -> NSSize {
        guard count > 0 else { return NSSize(width: 264, height: 172) }
        let rows = (count + 2) / 3
        return NSSize(width: 264, height: chrome + gridHeight(rows: rows))
    }

    static let tile = NSSize(width: 76, height: 88)

    static func gridHeight(rows: Int) -> CGFloat {
        let shown = min(rows, 3)
        return CGFloat(shown) * tile.height + CGFloat(max(shown - 1, 0)) * 6 + (rows > 3 ? 24 : 0)
    }

    var contentSize: NSSize { expanded ? Self.expandedSize(count: items.count) : Self.compactSize }

    static func windowSize(count: Int) -> NSSize {
        let e = expandedSize(count: count)
        return NSSize(width: max(e.width, compactSize.width) + 2 * margin,
                      height: max(e.height, compactSize.height) + 2 * margin)
    }

    var windowSize: NSSize { Self.windowSize(count: items.count) }

    static func fade(showing: Bool, matched: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        switch (showing, matched) {
        case (true, false): return .easeOut(duration: 0.16).delay(0.3)
        case (false, false): return .easeOut(duration: 0.08)
        case (true, true): return .easeOut(duration: 0.12).delay(0.22)
        case (false, true): return .easeIn(duration: 0.14).delay(0.2)
        }
    }

    static var morph: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var spring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.82)
    }
    var onEmptied: () -> Void = {}
    private var session: URL?
    private var counters: [String: Int] = [:]

    nonisolated static var tempPrefix: String { tempPrefixValue }
    nonisolated static let tempPrefixValue: String = Identity.bundleId + ".shelf."

    var urls: [URL] { items.map(\.url) }

    var order: [UUID] { items.map(\.id) }

    func urls(for ids: [UUID]) -> [URL] {
        ids.compactMap { id in items.first { $0.id == id }?.url }
    }

    func thumbnails(for ids: [UUID]) -> [NSImage?] {
        ids.map { id in items.first { $0.id == id }?.thumbnail }
    }

    var targetIDs: [UUID] { selection.targets(order) }

    var targetURLs: [URL] { urls(for: targetIDs) }

    func dragIDs(for id: UUID) -> [UUID] { selection.dragTargets(for: id, in: order) }

    func select(_ id: UUID, command: Bool = false, shift: Bool = false) {
        selection.click(id, in: order, command: command, shift: shift)
    }

    func selectAll() {
        selection.selectAll(order)
    }

    func toggleSelectAll() {
        if selection.allSelected(order) { selection.clear() } else { selection.selectAll(order) }
    }

    func expand() {
        guard !expanded else { return }
        willExpand()
        withAnimation(morphAnim) {
            expanded = true
            shift = .zero
        }
    }

    func collapse() {
        selection.clear()
        hovered = nil
        guard expanded else { return }
        withAnimation(morphAnim) { expanded = false }
    }

    func toggleExpanded() {
        if expanded { collapse() } else { expand() }
    }

    func addPlaceholder(_ name: String, image: NSImage, preview: Bool) {
        var item = ShelfItem(url: URL(fileURLWithPath: "/" + name), isTemporary: false)
        item.thumbnail = image
        item.isPreview = preview
        items.append(item)
    }

    static func cleanLeftovers() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(tempPrefix) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    func sessionDirectory() -> URL? {
        if let session { return session }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(Self.tempPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        session = dir
        return dir
    }

    func add(_ urls: [URL], temporary: Bool = false) {
        let known = Set(items.map(\.url.standardizedFileURL))
        for url in urls where !known.contains(url.standardizedFileURL) {
            let item = ShelfItem(url: url, isTemporary: temporary)
            items.append(item)
            loadThumbnail(for: item)
        }
    }

    func remove(_ id: UUID) {
        remove([id])
    }

    func remove(_ ids: [UUID], closeWhenEmpty: Bool = true) {
        let gone = Set(ids)
        let removed = items.filter { gone.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { gone.contains($0.id) }
        selection.keep(order)
        if items.isEmpty {
            if closeWhenEmpty {
                clear()
            } else {
                selection.clear()
                hovered = nil
            }
        }
    }


    func removeSelected() {
        remove(order.filter(selection.contains))
    }

    func clear() {
        items.removeAll()
        selection.clear()
        hovered = nil
        if let dir = session, Self.isSessionFolder(dir) {
            let delay = Self.deletionDelay(lastDragOut: lastDragOut)
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { try? FileManager.default.removeItem(at: dir) }
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        session = nil
        counters.removeAll()
        onEmptied()
    }

    func accept(_ pb: NSPasteboard) -> Bool {
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            add(files)
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, let dir = sessionDirectory() {
            let queue = OperationQueue()
            for promise in promises {
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                    guard error == nil else { return }
                    let inside = Self.isInside(url, folder: dir)
                    if inside { Quarantine.mark(url) }
                    DispatchQueue.main.async { self.add([url], temporary: inside) }
                }
            }
            return true
        }
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            let urls = images.compactMap { writeImage($0) }
            add(urls, temporary: true)
            return !urls.isEmpty
        }
        if let links = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !links.isEmpty {
            let urls = links.compactMap { writeLink($0) }
            add(urls, temporary: true)
            return !urls.isEmpty
        }
        if let text = pb.string(forType: .string), !text.isEmpty, let url = writeText(text) {
            add([url], temporary: true)
            return true
        }
        return false
    }

    private func nextName(_ base: String, _ ext: String) -> URL? {
        guard let dir = sessionDirectory() else { return nil }
        var n = counters[base] ?? 0
        while true {
            n += 1
            let url = dir.appendingPathComponent(Self.uniqueName(base, ext, n))
            if !FileManager.default.fileExists(atPath: url.path) || n > 9999 {
                counters[base] = n
                return url
            }
        }
    }

    nonisolated static func uniqueName(_ base: String, _ ext: String, _ n: Int) -> String {
        n == 1 ? "\(base).\(ext)" : "\(base) \(n).\(ext)"
    }

    private func writeData(_ data: Data, to url: URL) -> URL? {
        guard let dir = session, Self.isInside(url, folder: dir) else { return nil }
        do {
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        return url
    }

    nonisolated static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func isInside(_ url: URL, folder: URL) -> Bool {
        let base = resolved(folder)
        let path = resolved(url)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    nonisolated static func isSessionFolder(_ dir: URL) -> Bool {
        let root = resolved(FileManager.default.temporaryDirectory)
        let path = resolved(dir)
        return (path as NSString).deletingLastPathComponent == root && dir.lastPathComponent.hasPrefix(tempPrefix)
    }

    private func writeImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              let url = nextName("Image", "png") else { return nil }
        return writeData(png, to: url)
    }

    private func writeLink(_ link: URL) -> URL? {
        guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = link.host(), !host.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString],
                                                              format: .xml, options: 0) else { return nil }
        let safe = host.replacingOccurrences(of: "/", with: "-")
        guard let url = nextName(safe, "webloc") else { return nil }
        return writeData(data, to: url)
    }

    private func writeText(_ text: String) -> URL? {
        guard let url = nextName("Text", "txt") else { return nil }
        return writeData(Data(text.utf8), to: url)
    }

    private func loadThumbnail(for item: ShelfItem) {
        let id = item.id
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].thumbnail = icon }
        guard ShelfItem.wantsPreview(item.url) else { return }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 160, height: 160),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep, rep.type == .thumbnail else { return }
            let image = rep.nsImage
            DispatchQueue.main.async {
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].thumbnail = image
                self.items[i].isPreview = true
            }
        }
    }
}

final class ShelfPanel: NSPanel {
    var onKey: (ShelfKey) -> Bool = { _ in false }
    var onCommand: (ShelfCommand) -> Void = { _ in }
    var canPerform: (ShelfCommand) -> Bool = { _ in false }
    var quickLookSource: () -> QuickLookSource? = { nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow { makeKey() }
        if event.type == .keyDown, !(firstResponder is NSText) {
            let key = ShelfKey.action(keyCode: event.keyCode, flags: event.modifierFlags)
            if key != .none, onKey(key) { return }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    override func keyDown(with event: NSEvent) {
        let key = ShelfKey.action(keyCode: event.keyCode, flags: event.modifierFlags)
        _ = onKey(key)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onKey(.escape)
    }

    override func noResponder(for eventSelector: Selector) {}

    @objc func copy(_ sender: Any?) { onCommand(.copy) }
    @objc override func selectAll(_ sender: Any?) { onCommand(.selectAll) }
    @objc func delete(_ sender: Any?) { onCommand(.delete) }
    @objc func toggleQuickLook(_ sender: Any?) { onCommand(.quickLook) }
    @objc func openItems(_ sender: Any?) { onCommand(.open) }
    override func performClose(_ sender: Any?) { onCommand(.close) }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return canPerform(.copy)
        case #selector(selectAll(_:)): return canPerform(.selectAll)
        case #selector(delete(_:)): return canPerform(.delete)
        case #selector(toggleQuickLook(_:)): return canPerform(.quickLook)
        case #selector(openItems(_:)): return canPerform(.open)
        case #selector(performClose(_:)): return true
        case #selector(performMiniaturize(_:)), #selector(performZoom(_:)): return false
        default: return super.validateMenuItem(item)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookSource() != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        let source = quickLookSource()
        panel.dataSource = source
        panel.delegate = source
        panel.currentPreviewItemIndex = source?.start ?? 0
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

final class DropHostView: NSView {
    weak var model: ShelfModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png, .string, .init(UTType.item.identifier)]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { nil }

    private func cardRect() -> NSRect {
        let (size, shift) = MainActor.assumeIsolated { (model?.contentSize ?? .zero, model?.shift ?? .zero) }
        return NSRect(x: bounds.midX + shift.width - size.width / 2, y: bounds.midY + shift.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func inside(_ sender: NSDraggingInfo) -> Bool {
        cardRect().contains(convert(sender.draggingLocation, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard cardRect().insetBy(dx: -1, dy: -1).contains(p) else { return nil }
        return super.hitTest(point)
    }

    private func evaluate(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? DragSourceView == nil else { return [] }
        let ok = inside(sender)
        MainActor.assumeIsolated { if model?.targeted != ok { model?.targeted = ok } }
        return ok ? .copy : []
    }

    override var isFlipped: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { model?.targeted = false }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard inside(sender) else { return false }
        return MainActor.assumeIsolated {
            model?.targeted = false
            return model?.accept(sender.draggingPasteboard) ?? false
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { model?.targeted = false }
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var images: () -> [NSImage?] = { [] }
    var onEnded: (_ allMoved: Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onClick: (_ count: Int, _ flags: NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onHover: (Bool) -> Void = { _ in }
    var contextMenu: () -> NSMenu? = { nil }
    private var down: NSPoint?
    private var dragging = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        dragging = false
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick(event.clickCount, event.modifierFlags.intersection(.deviceIndependentFlagsMask)) }
        down = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, !dragging else { return }
        let p = event.locationInWindow
        guard hypot(p.x - down.x, p.y - down.y) > 4 else { return }
        let list = urls()
        guard !list.isEmpty else { return }
        dragging = true
        onBegan()
        let pics = images()
        let local = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = list.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = (i < pics.count ? pics[i] : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 56
            let offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: local.x - side / 2 + offset, y: local.y - side / 2 - offset,
                                         width: side, height: side), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = list.count > 1 ? .stack : .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        return Self.operations(for: urls())
    }

    nonisolated static func operations(for urls: [URL]) -> NSDragOperation {
        let temp = FileManager.default.temporaryDirectory
        let prefix = ShelfModel.tempPrefixValue
        let hasTemp = urls.contains { url in
            ShelfModel.resolved(url).hasPrefix(ShelfModel.resolved(temp) + "/" + prefix)
        }
        return hasTemp ? .copy : [.copy, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded(operation != [])
        dragging = false
        down = nil
    }
}

struct DragHandle: NSViewRepresentable {
    let urls: () -> [URL]
    let images: () -> [NSImage?]
    var onEnded: (Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onClick: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onHover: (Bool) -> Void = { _ in }
    var menu: () -> NSMenu? = { nil }

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: DragSourceView) {
        view.urls = urls
        view.images = images
        view.onEnded = onEnded
        view.onBegan = onBegan
        view.onClick = onClick
        view.onHover = onHover
        view.contextMenu = menu
    }
}

final class AnchorBox {
    weak var view: NSView?
}

struct Anchor: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let autoClose: () -> Bool
    let close: () -> Void
    @Namespace private var space

    var body: some View {
        let size = model.contentSize
        let radius: CGFloat = model.expanded ? 22 : 20
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let still = ShelfModel.reduceMotion
        ZStack {
            ExpandedShelf(model: model, space: space, autoClose: autoClose, close: close)
                .allowsHitTesting(model.expanded)
            CompactShelf(model: model, space: space, autoClose: autoClose, close: close)
                .allowsHitTesting(!model.expanded)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) { ShelfHeader(model: model, close: close) }
        .overlay(alignment: .bottomLeading) { ShelfCorner(model: model, autoClose: autoClose, close: close) }
        .clipShape(shape)
        .glassEffect(.regular.tint(Color.white.opacity(0.05)), in: shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
        }
        .overlay {
            shape.strokeBorder(Color(nsColor: .controlAccentColor).opacity(model.targeted ? 0.85 : 0), lineWidth: 2)
        }
        .scaleEffect(model.shown || still ? 1 : 0.92, anchor: .center)
        .opacity(model.shown ? 1 : 0)
        .offset(x: model.shift.width, y: -model.shift.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(model.morphAnim, value: model.expanded)
        .animation(model.springAnim, value: model.shown)
        .animation(model.springAnim, value: model.items.count)
        .animation(.easeOut(duration: 0.15), value: model.targeted)
        .ignoresSafeArea()
    }
}

extension View {
    func layerFade(_ visible: Bool, matched: Bool = false, expanded: Bool, pace: Double = 1) -> some View {
        opacity(visible ? 1 : 0)
            .animation(ShelfModel.fade(showing: visible, matched: matched).speed(pace), value: expanded)
    }

    @ViewBuilder
    func hero(_ id: UUID, in space: Namespace.ID, source: Bool, active: Bool) -> some View {
        if active && !ShelfModel.reduceMotion {
            matchedGeometryEffect(id: id, in: space, properties: .frame, anchor: .center, isSource: source)
        } else {
            self
        }
    }
}

struct ShelfHeader: View {
    @ObservedObject var model: ShelfModel
    let close: () -> Void
    static let top: CGFloat = 7
    static let height: CGFloat = 22
    static let button: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if !model.items.isEmpty || model.expanded {
                    RoundIconButton(symbol: model.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                    help: model.expanded ? "Collapse" : "Expand", size: Self.button,
                                    action: model.toggleExpanded)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.button, height: Self.button)
            ZStack {
                Color.clear
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 26, height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .help("Drag to move the shelf")
            CloseButton(action: close, size: Self.button)
        }
        .frame(height: Self.height)
        .padding(.horizontal, 8)
        .padding(.top, Self.top)
    }
}

struct CloseButton: View {
    let action: () -> Void
    var size: CGFloat = 20

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Close and clear")
    }
}

struct RoundIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 20
    var active = false
    var morphSymbol = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(active ? AnyShapeStyle(Color(nsColor: .controlAccentColor)) : AnyShapeStyle(.secondary))
                .contentTransition(morphSymbol ? .symbolEffect(.replace) : .opacity)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(Color(nsColor: .controlAccentColor).opacity(0.28)).interactive() : .regular.interactive(), in: Circle())
        .help(help)
    }
}

struct GlassBubble: View {
    let text: String
    var size: CGFloat = 20

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.28)
            .frame(minWidth: size, minHeight: size, maxHeight: size)
            .contentShape(Capsule())
            .glassEffect(.regular, in: Capsule())
    }
}

struct ShelfCorner: View {
    @ObservedObject var model: ShelfModel
    let autoClose: () -> Bool
    let close: () -> Void

    static func size(expanded: Bool) -> CGFloat { expanded ? 26 : 20 }
    static func inset(expanded: Bool) -> CGFloat { expanded ? 10 : 8 }

    var body: some View {
        let size = Self.size(expanded: model.expanded)
        let still = ShelfModel.reduceMotion
        HStack(spacing: 5) {
            GlassBubble(text: model.countText, size: size)
                .keyframeAnimator(initialValue: 1.0, trigger: model.items.count) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    SpringKeyframe(still ? 1.0 : 1.22, duration: 0.12)
                    SpringKeyframe(1.0, duration: 0.28)
                }
                .overlay {
                    DragHandle(urls: { model.targetURLs }, images: { model.thumbnails(for: model.targetIDs) },
                               onEnded: { moved in model.finishDragOut(model.targetIDs, moved: moved, autoClose: autoClose()) },
                               onClick: { _, _ in if model.expanded { model.toggleSelectAll() } },
                               menu: { model.selection.isEmpty ? model.pileMenu() : model.menu(forSelection: ()) })
                }
                .help(model.expanded ? "Click to select all · drag to move out" : "Drag to move everything out")
            RoundIconButton(symbol: model.locked ? "lock.fill" : "lock.open", help: "Keep files after dragging out",
                            size: size, active: model.locked, action: model.toggleLock)
        }
        .padding(Self.inset(expanded: model.expanded))
        .opacity(model.items.isEmpty ? 0 : 1)
        .allowsHitTesting(!model.items.isEmpty)
        .animation(model.springAnim, value: model.items.isEmpty)
    }
}

struct ItemCard: View {
    let item: ShelfItem
    static let side: CGFloat = 54

    static func fitted(_ image: NSSize, in side: CGFloat) -> NSSize {
        guard image.width > 0, image.height > 0 else { return NSSize(width: side, height: side) }
        let k = min(side / image.width, side / image.height)
        return NSSize(width: (image.width * k).rounded(), height: (image.height * k).rounded())
    }

    var body: some View {
        let side = Self.side
        Group {
            if let image = item.thumbnail, item.isPreview {
                let border: CGFloat = 2
                let fit = Self.fitted(image.size, in: side - 2 * border)
                let inner = RoundedRectangle(cornerRadius: 2, style: .continuous)
                let outer = RoundedRectangle(cornerRadius: 4, style: .continuous)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(inner)
                    .padding(border)
                    .background(Color(white: 0.97), in: outer)
                    .overlay { outer.strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.28), radius: 1.6, y: 0.8)
            } else if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side, height: side)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
    }
}

enum FinderName {
    static func lines(_ name: String, width: CGFloat, font: NSFont) -> [String] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ t: String) -> Bool { (t as NSString).size(withAttributes: attrs).width <= width }
        guard !fits(name) else { return [name] }
        let chars = Array(name)
        var cut = 0
        var breakCut = 0
        for i in 1...chars.count {
            guard fits(String(chars[0..<i])) else { break }
            cut = i
            if " -_.".contains(chars[i - 1]) { breakCut = i }
        }
        let split = breakCut > 0 ? breakCut : max(cut, 1)
        let first = String(chars[0..<split]).trimmingCharacters(in: .whitespaces)
        let rest = String(chars[split...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return [first] }
        return [first, middleTruncated(rest, fits: fits)]
    }

    static func middleTruncated(_ text: String, fits: (String) -> Bool) -> String {
        guard !fits(text) else { return text }
        let chars = Array(text)
        var keep = chars.count - 1
        while keep > 1 {
            let head = (keep + 1) / 2
            let tail = keep - head
            let candidate = String(chars[0..<head]) + "…" + String(chars[(chars.count - tail)...])
            if fits(candidate) { return candidate }
            keep -= 1
        }
        return String(chars.prefix(1)) + "…"
    }
}

struct ItemName: View {
    let name: String
    var selected = false
    static let width: CGFloat = 74
    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)

    var body: some View {
        let lines = FinderName.lines(name, width: Self.width, font: Self.font)
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Font(Self.font))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 3)
                    .background(selected ? Color(nsColor: .controlAccentColor) : .clear, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: Self.width, height: 26, alignment: .top)
    }
}

struct CompactShelf: View {
    @ObservedObject var model: ShelfModel
    let space: Namespace.ID
    let autoClose: () -> Bool
    let close: () -> Void

    private var on: Bool { !model.expanded }
    static let pileHeight: CGFloat = 83

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ShelfHeader.top + ShelfHeader.height)
            if model.items.isEmpty {
                dropZone
                    .layerFade(on, expanded: model.expanded, pace: model.pace)
            } else {
                pile
                    .frame(width: 104, height: CompactShelf.pileHeight)
                    .overlay {
                        if on {
                            DragHandle(urls: { model.urls }, images: { model.items.map(\.thumbnail) },
                                       onEnded: { moved in
                                           model.lifting = false
                                           model.finishDragOut(model.order, moved: moved, autoClose: autoClose())
                                       },
                                       onBegan: { model.lifting = true },
                                       onClick: { clicks, _ in if clicks == 2 { model.expand() } },
                                       onHover: { model.pileHovered = $0 },
                                       menu: { model.pileMenu() })
                        }
                    }
                    .help("Drag to move everything out · double-click to expand · Space to Quick Look")
            }
        }
        .frame(width: ShelfModel.compactSize.width, height: ShelfModel.compactSize.height, alignment: .top)
    }

    private var dropZone: some View {
        VStack(spacing: 5) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .regular))
            Text("Drop files")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(width: 104, height: 98)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    static func fan(depth: Int, count: Int, open: Bool) -> (angle: Double, x: CGFloat, y: CGFloat) {
        guard count > 1 else { return (0, 0, 0) }
        switch depth {
        case 0: return (0, 0, open ? -3 : 0)
        case 1: return (open ? -13 : -8, open ? -19 : -11, open ? 2 : 3)
        default: return (open ? 13 : 8, open ? 19 : 11, open ? 3 : 5)
        }
    }

    private var pile: some View {
        let top = Array(model.items.suffix(3))
        let still = ShelfModel.reduceMotion
        let open = model.pileHovered && !still
        return ZStack {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, item in
                let f = on ? Self.fan(depth: top.count - 1 - index, count: top.count, open: open) : (0, 0, 0)
                ItemCard(item: item)
                    .layerFade(on, matched: true, expanded: model.expanded, pace: model.pace)
                    .hero(item.id, in: space, source: on, active: true)
                    .opacity(model.leaving.contains(item.id) ? 0 : 1)
                    .rotationEffect(.degrees(f.0))
                    .offset(x: f.1, y: f.2)
                    .transition(still ? .opacity : .asymmetric(
                        insertion: .offset(y: -26).combined(with: .scale(scale: 1.12)).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .frame(width: 104, height: Self.pileHeight)
        .scaleEffect(model.lifting && !still ? 1.05 : 1)
        .offset(y: model.lifting && !still ? -2 : 0)
        .contentShape(Rectangle())
        .animation(model.springAnim, value: model.items.map(\.id))
        .animation(model.springAnim, value: model.pileHovered)
        .animation(model.springAnim, value: model.lifting)
    }
}

struct ExpandedShelf: View {
    @ObservedObject var model: ShelfModel
    let space: Namespace.ID
    let autoClose: () -> Bool
    let close: () -> Void
    private let shareAnchor = AnchorBox()

    private var on: Bool { model.expanded }

    var body: some View {
        let size = ShelfModel.expandedSize(count: model.items.count)
        return VStack(spacing: 8) {
            Color.clear.frame(height: ShelfHeader.height)
            if model.items.isEmpty {
                empty
                    .layerFade(on, expanded: model.expanded, pace: model.pace)
            } else {
                grid
            }
        }
        .padding(.top, ShelfHeader.top)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay(alignment: .bottom) {
            if !model.items.isEmpty {
                footer
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transaction(value: model.expanded) { $0.animation = nil }
                    .layerFade(on, expanded: model.expanded, pace: model.pace)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Drop files here")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(.tertiary)
        }
    }

    private var grid: some View {
        let pileIDs = Set(model.items.suffix(3).map(\.id))
        let rows = (model.items.count + 2) / 3
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(ShelfModel.tile.width), spacing: 6), count: 3), spacing: 6) {
                    ForEach(model.items) { item in
                        tile(item, hero: pileIDs.contains(item.id))
                            .id(item.id)
                            .transition(ShelfModel.reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(model.springAnim, value: model.items.map(\.id))
            }
            .scrollIndicators(.never)
            .scrollDisabled(!on)
            .onChange(of: model.focus) { _, id in
                guard let id else { return }
                withAnimation(model.springAnim) { proxy.scrollTo(id) }
            }
        }
        .frame(height: ShelfModel.gridHeight(rows: rows))
    }

    private func tile(_ item: ShelfItem, hero: Bool) -> some View {
        let selected = model.selection.contains(item.id)
        return VStack(spacing: 3) {
            ItemCard(item: item)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(selected && on ? 0.14 : 0))
                        .padding(-4)
                }
                .layerFade(on, matched: hero, expanded: model.expanded, pace: model.pace)
                .hero(item.id, in: space, source: on, active: hero)
            ItemName(name: item.name, selected: selected && on)
                .layerFade(on, expanded: model.expanded, pace: model.pace)
        }
        .padding(.top, 5)
        .frame(width: ShelfModel.tile.width, height: ShelfModel.tile.height, alignment: .top)
        .contentShape(Rectangle())
        .overlay {
            if on {
                DragHandle(urls: { model.urls(for: model.dragIDs(for: item.id)) },
                           images: { model.thumbnails(for: model.dragIDs(for: item.id)) },
                           onEnded: { moved in model.finishDragOut(model.dragIDs(for: item.id), moved: moved, autoClose: autoClose()) },
                           onClick: { clicks, flags in
                               if clicks == 2 {
                                   model.open([item.id])
                               } else {
                                   model.select(item.id, command: flags.contains(.command), shift: flags.contains(.shift))
                               }
                           },
                           onHover: { inside in
                               if inside { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
                           },
                           menu: { model.itemMenu(for: item.id) })
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.hovered == item.id && on {
                Button { model.remove(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .padding(2)
                .help("Remove")
            }
        }
        .help(item.name)
        .opacity(model.leaving.contains(item.id) ? 0 : 1)
        .scaleEffect(model.leaving.contains(item.id) && !ShelfModel.reduceMotion ? 0.82 : 1)
    }

    private var footer: some View {
        let none = model.selection.isEmpty
        return HStack(spacing: 5) {
            Spacer(minLength: 4)
            footerButton("eye", "Quick Look (Space)") {
                model.requestQuickLook(nil)
            }
            footerButton("square.and.arrow.up", "Share") {
                guard let anchor = shareAnchor.view else { return }
                NSSharingServicePicker(items: model.targetURLs).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            }
            .background(Anchor(box: shareAnchor))
            footerButton("doc.on.doc", "Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(model.targetURLs as [NSURL])
            }
            footerButton("folder", "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(model.targetURLs)
            }
            footerButton(none ? "trash" : "minus.circle", none ? "Clear the shelf" : "Remove selected") {
                if model.selection.isEmpty { close() } else { model.removeSelected() }
            }
        }
        .frame(height: 26)
    }

    private func footerButton(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        RoundIconButton(symbol: symbol, help: help, size: ShelfCorner.size(expanded: true), morphSymbol: false, action: run)
    }
}

@MainActor
final class Shelf {
    let model = ShelfModel()
    var autoClose: () -> Bool = { true }
    var onClosed: (Shelf) -> Void = { _ in }
    private lazy var panel: ShelfPanel = makePanel()
    private var resizer: AnyCancellable?
    private var sizeToken = 0
    private var hideToken = 0
    private let quickLook = QuickLookSource()

    var isVisible: Bool { panel.isVisible }
    var isEmpty: Bool { model.items.isEmpty }
    var windowFrame: NSRect { panel.frame }
    var frame: NSRect { Self.cardFrame(window: panel.frame, card: model.contentSize, shift: model.shift) }

    init() {
        model.onEmptied = { [weak self] in self?.hide() }
        model.willExpand = { [weak self] in self?.prepareExpand() }
        model.requestQuickLook = { [weak self] ids in self?.toggleQuickLook(ids) }
        resizer = model.$items.map(\.count).removeDuplicates().sink { [weak self] count in
            DispatchQueue.main.async { self?.fit(count: count) }
        }
    }

    var isExpanded: Bool {
        get { model.expanded }
        set { model.expanded = newValue }
    }

    static func cardFrame(window: NSRect, card: NSSize, shift: CGSize = .zero) -> NSRect {
        NSRect(x: window.midX + shift.width - card.width / 2, y: window.midY + shift.height - card.height / 2,
               width: card.width, height: card.height)
    }

    static func windowFrame(card: NSRect, window: NSSize) -> NSRect {
        NSRect(x: card.midX - window.width / 2, y: card.midY - window.height / 2, width: window.width, height: window.height)
    }

    static func resizePlan(current: NSSize, target: NSSize) -> (now: NSSize, later: NSSize?) {
        let now = NSSize(width: max(current.width, target.width), height: max(current.height, target.height))
        return (now, now == target ? nil : target)
    }

    static func centered(_ frame: NSRect, size: NSSize) -> NSRect {
        NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func clampDelta(_ rect: NSRect, in vis: NSRect?, inset: CGFloat = 8) -> CGSize {
        guard let vis else { return .zero }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if rect.maxX > vis.maxX - inset { dx = vis.maxX - inset - rect.maxX }
        if rect.minX + dx < vis.minX + inset { dx = vis.minX + inset - rect.minX }
        if rect.maxY > vis.maxY - inset { dy = vis.maxY - inset - rect.maxY }
        if rect.minY + dy < vis.minY + inset { dy = vis.minY + inset - rect.minY }
        return CGSize(width: dx, height: dy)
    }

    static func expansionShift(compact card: NSRect, expanded size: NSSize, in vis: NSRect?) -> CGSize {
        clampDelta(centered(card, size: size), in: vis)
    }

    private func prepareExpand() {
        let p = panel
        guard p.isVisible else { return }
        let card = frame
        let delta = Self.expansionShift(compact: card, expanded: ShelfModel.expandedSize(count: model.items.count),
                                        in: p.screen?.visibleFrame)
        guard delta != .zero else { return }
        p.setFrameOrigin(NSPoint(x: p.frame.minX + delta.width, y: p.frame.minY + delta.height))
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.shift = CGSize(width: model.shift.width - delta.width, height: model.shift.height - delta.height)
        }
    }

    private func fit(count: Int) {
        let p = panel
        guard p.isVisible else { return }
        let plan = Self.resizePlan(current: p.frame.size, target: ShelfModel.windowSize(count: count))
        if plan.now != p.frame.size { p.setFrame(placed(Self.centered(p.frame, size: plan.now)), display: true) }
        sizeToken += 1
        guard let later = plan.later else { return }
        let token = sizeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, token == self.sizeToken, self.panel.isVisible else { return }
            let f = self.placed(Self.centered(self.panel.frame, size: later))
            if f != self.panel.frame { self.panel.setFrame(f, display: true) }
        }
    }

    private func placed(_ window: NSRect) -> NSRect {
        let card = Self.cardFrame(window: window, card: model.contentSize, shift: model.shift)
        let d = Self.clampDelta(card, in: panel.screen?.visibleFrame)
        return window.offsetBy(dx: d.width, dy: d.height)
    }

    private func makePanel() -> ShelfPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 324, height: 232),
                           styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.onKey = { [weak self] key in self?.handle(key) ?? false }
        p.onCommand = { [weak self] command in self?.perform(command) }
        p.canPerform = { [weak self] command in self?.canPerform(command) ?? false }
        p.quickLookSource = { [weak self] in self?.quickLook }
        let drop = DropHostView()
        drop.model = model
        drop.wantsLayer = true
        drop.layer?.backgroundColor = .clear
        let host = NSHostingView(rootView: ShelfView(model: model, autoClose: { [weak self] in self?.autoClose() ?? true },
                                                     close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        host.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            host.topAnchor.constraint(equalTo: drop.topAnchor),
            host.bottomAnchor.constraint(equalTo: drop.bottomAnchor),
        ])
        p.contentView = drop
        return p
    }

    var fittingSize: NSSize { model.contentSize }

    var panelWindow: NSWindow { panel }

    func canPerform(_ command: ShelfCommand) -> Bool {
        ShelfCommand.isEnabled(command, items: model.items.count, selected: model.selectedIDs.count, expanded: model.expanded)
    }

    func perform(_ command: ShelfCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .copy: model.copy(model.targetIDs)
        case .selectAll: model.selectAll()
        case .delete: withAnimation(model.springAnim) { model.removeSelected() }
        case .quickLook: toggleQuickLook(nil)
        case .open: model.open(Navigation.openTargets(selected: model.selectedIDs, order: model.order, expanded: model.expanded))
        case .close: close()
        }
    }

    func handle(_ key: ShelfKey) -> Bool {
        switch key {
        case .quickLook:
            guard !model.items.isEmpty else { return true }
            toggleQuickLook(nil)
        case .escape:
            if Self.quickLookVisible {
                QLPreviewPanel.shared()?.orderOut(nil)
            } else if !model.selection.isEmpty {
                model.selection.clear()
            } else if model.expanded {
                model.collapse()
            }
        case .open:
            perform(.open)
        case let .move(dx, dy):
            model.move(dx: dx, dy: dy)
        case .none:
            break
        }
        return true
    }

    static var quickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    static func tileFrame(index: Int, card: NSRect, expanded: Bool) -> NSRect {
        let side = ItemCard.side
        if !expanded {
            let top = ShelfHeader.top + ShelfHeader.height + CompactShelf.pileHeight / 2
            return NSRect(x: card.midX - side / 2, y: card.maxY - top - side / 2, width: side, height: side)
        }
        let row = index / Navigation.columns, col = index % Navigation.columns
        guard row < 3 else { return .zero }
        let grid = CGFloat(Navigation.columns) * ShelfModel.tile.width + CGFloat(Navigation.columns - 1) * 6
        let left = (card.width - grid) / 2 + CGFloat(col) * (ShelfModel.tile.width + 6) + (ShelfModel.tile.width - side) / 2
        let top = ShelfHeader.top + ShelfHeader.height + 8 + CGFloat(row) * (ShelfModel.tile.height + 6) + 5
        return NSRect(x: card.minX + left, y: card.maxY - top - side, width: side, height: side)
    }

    func toggleQuickLook(_ ids: [UUID]?) {
        guard let ql = QLPreviewPanel.shared() else { return }
        if ids == nil, Self.quickLookVisible, (ql.dataSource as AnyObject?) === quickLook {
            ql.orderOut(nil)
            return
        }
        let plan = ids.map { (ids: $0, start: 0) }
            ?? Navigation.quickLookPlan(selected: model.selectedIDs, order: model.order, expanded: model.expanded)
        guard !plan.ids.isEmpty else { return }
        let card = frame
        let order = model.order
        quickLook.urls = model.urls(for: plan.ids)
        quickLook.images = model.thumbnails(for: plan.ids)
        quickLook.frames = plan.ids.map { id in
            let i = order.firstIndex(of: id) ?? 0
            return model.expanded || id == order.last ? Self.tileFrame(index: i, card: card, expanded: model.expanded) : .zero
        }
        quickLook.start = min(plan.start, plan.ids.count - 1)
        NSApp.activate()
        panel.makeKey()
        if ql.isVisible {
            ql.updateController()
            ql.reloadData()
            ql.currentPreviewItemIndex = quickLook.start
        } else {
            ql.makeKeyAndOrderFront(nil)
        }
    }

    func show(origin: NSPoint) {
        let p = panel
        hideToken += 1
        let appearing = !p.isVisible || !model.shown
        let card = NSRect(origin: origin, size: model.contentSize)
        let vis = NSScreen.screens.first { $0.frame.contains(card.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { model.shift = .zero }
        let d = Self.clampDelta(card, in: vis)
        p.setFrame(Self.windowFrame(card: card.offsetBy(dx: d.width, dy: d.height), window: model.windowSize), display: true)
        if appearing { model.shown = false }
        p.orderFrontRegardless()
        if appearing {
            DispatchQueue.main.async { [weak self] in self?.model.shown = true }
        }
    }

    func bringForward() {
        panel.orderFrontRegardless()
    }

    func hide() {
        hideToken += 1
        let token = hideToken
        model.shown = false
        model.pileHovered = false
        model.lifting = false
        onClosed(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
            guard token == self.hideToken, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    func close() {
        if Self.quickLookVisible, (QLPreviewPanel.shared()?.dataSource as AnyObject?) === quickLook { QLPreviewPanel.shared()?.orderOut(nil) }
        model.clear()
    }

    func add(_ urls: [URL]) {
        model.add(urls)
    }
}

@MainActor
final class ShelfManager {
    static let limit = 4
    var autoClose: () -> Bool = { true }
    var startExpanded: () -> Bool = { false }
    var startLocked: () -> Bool = { false }
    private(set) var shelves: [Shelf] = []

    var isAnyVisible: Bool { !shelves.isEmpty }

    var cardFrames: [NSRect] { shelves.filter(\.isVisible).map(\.frame) }

    static func origin(for size: NSSize, at point: NSPoint, avoiding taken: [NSRect], spread: Bool) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        func clamp() {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)
        }
        clamp()
        if spread {
            for _ in 0..<8 {
                let rect = NSRect(origin: origin, size: size)
                guard let hit = taken.first(where: { $0.intersects(rect.insetBy(dx: 6, dy: 6)) }) else { break }
                if hit.maxX + 12 + size.width <= vis.maxX - 8 {
                    origin.x = hit.maxX + 12
                } else if hit.minX - 12 - size.width >= vis.minX + 8 {
                    origin.x = hit.minX - 12 - size.width
                } else {
                    origin.y = hit.minY - 12 - size.height
                }
                clamp()
            }
        } else {
            var tries = 0
            while tries < 8, taken.contains(where: { abs($0.minX - origin.x) < 16 && abs($0.minY - origin.y) < 16 }) {
                origin.x += 26
                origin.y -= 26
                clamp()
                tries += 1
            }
        }
        return origin
    }

    private func makeShelf() -> Shelf {
        let shelf = Shelf()
        shelf.isExpanded = startExpanded()
        shelf.model.locked = startLocked()
        shelf.autoClose = { [weak self] in self?.autoClose() ?? true }
        shelf.onClosed = { [weak self] closed in self?.shelves.removeAll { $0 === closed } }
        return shelf
    }

    private func open(at point: NSPoint, spread: Bool) -> Shelf {
        let shelf = makeShelf()
        let origin = Self.origin(for: shelf.fittingSize, at: point, avoiding: shelves.map(\.frame), spread: spread)
        shelves.append(shelf)
        shelf.show(origin: origin)
        return shelf
    }

    private func moveToFront(_ shelf: Shelf) {
        shelves.removeAll { $0 === shelf }
        shelves.append(shelf)
        shelf.bringForward()
    }

    func shake(at point: NSPoint) {
        if let empty = shelves.last(where: \.isEmpty) {
            let origin = Self.origin(for: empty.fittingSize, at: point,
                                     avoiding: shelves.filter { $0 !== empty }.map(\.frame), spread: false)
            empty.show(origin: origin)
            moveToFront(empty)
        } else if shelves.count < Self.limit {
            _ = open(at: point, spread: false)
        } else if let nearest = shelves.min(by: { distance($0, point) < distance($1, point) }) {
            moveToFront(nearest)
        }
    }

    func newShelf(at point: NSPoint = NSEvent.mouseLocation) {
        if let empty = shelves.last(where: \.isEmpty) {
            let origin = Self.origin(for: empty.fittingSize, at: point,
                                     avoiding: shelves.filter { $0 !== empty }.map(\.frame), spread: true)
            empty.show(origin: origin)
            moveToFront(empty)
        } else if shelves.count < Self.limit {
            _ = open(at: point, spread: true)
        } else if let newest = shelves.last {
            moveToFront(newest)
        }
    }

    func add(_ urls: [URL]) {
        let shelf = shelves.last ?? open(at: NSEvent.mouseLocation, spread: true)
        shelf.add(urls)
        moveToFront(shelf)
    }

    func closeAll() {
        for shelf in shelves {
            shelf.model.clear()
            shelf.hide()
        }
        shelves.removeAll()
    }

    private func distance(_ shelf: Shelf, _ point: NSPoint) -> CGFloat {
        hypot(shelf.frame.midX - point.x, shelf.frame.midY - point.y)
    }
}
