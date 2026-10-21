import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var cfg = Config.load()
    var onChange: () -> Void = {}
    private var saver: AnyCancellable?

    init() {
        saver = $cfg.dropFirst().removeDuplicates().sink { [weak self] new in
            DispatchQueue.main.async {
                guard let self, self.cfg == new else { return }
                Config.save(new)
                self.onChange()
            }
        }
    }
}

enum PreviewCue: Equatable {
    case shake(amplitude: CGFloat, swings: Int)
    case hotkey(String)
}

enum PreviewStep: Equatable {
    case cue, appear, drop, expand, collapse, dragOut, close, end, emptyAppear, emptyClose, refill
}

struct PreviewPlan: Equatable {
    struct Timed: Equatable {
        let time: Double
        let step: PreviewStep
    }

    var cue: PreviewCue
    var expanded: Bool
    var locked: Bool
    var closesAfterDrag: Bool
    var removesOnDrag: Bool
    var demoUnused: Bool
    var reduceMotion: Bool
    var steps: [Timed]

    static func amplitude(_ s: Sensitivity) -> CGFloat {
        switch s {
        case .low: 40
        case .medium: 26
        case .high: 14
        }
    }

    static func swings(_ s: Sensitivity) -> Int {
        switch s {
        case .low: 4
        case .medium: 3
        case .high: 2
        }
    }

    static func make(_ cfg: Config, reduceMotion: Bool) -> PreviewPlan {
        let cue: PreviewCue = cfg.shake
            ? .shake(amplitude: reduceMotion ? 0 : amplitude(cfg.sensitivity), swings: reduceMotion ? 0 : swings(cfg.sensitivity))
            : .hotkey(cfg.hotkey == "off" ? "New Shelf" : hotkeyName(cfg.hotkey))
        let drag = ShelfModel.dragOutPlan(locked: cfg.startLocked, moved: true, everything: true, autoClose: cfg.autoClose)
        let closes = drag.close
        var t = 0.4
        var steps: [Timed] = []
        func at(_ step: PreviewStep, after gap: Double) {
            t += gap
            steps.append(Timed(time: (t * 10).rounded() / 10, step: step))
        }
        let demoUnused = cfg.shake && !cfg.keepEmpty
        if demoUnused {
            at(.cue, after: 0)
            at(.emptyAppear, after: 1.1)
            at(.emptyClose, after: 1.0)
            at(.refill, after: 0.4)
            at(.cue, after: 0.1)
        } else {
            at(.cue, after: 0)
        }
        at(.appear, after: 1.4)
        at(.drop, after: 1.2)
        if !cfg.openExpanded {
            at(.expand, after: 1.3)
            at(.collapse, after: 1.9)
        }
        at(.dragOut, after: 1.3)
        if !drag.remove { at(.dragOut, after: 1.5) }
        at(.close, after: closes ? 0.9 : 1.5)
        at(.end, after: 1.1)
        return PreviewPlan(cue: cue, expanded: cfg.openExpanded, locked: cfg.startLocked,
                           closesAfterDrag: closes, removesOnDrag: drag.remove, demoUnused: demoUnused,
                           reduceMotion: reduceMotion, steps: steps)
    }
}

@MainActor
final class ShelfPreviewDriver: ObservableObject {
    let model: ShelfModel = {
        let m = ShelfModel()
        m.pace = 0.72
        return m
    }()
    @Published private(set) var plan = PreviewPlan.make(Config(), reduceMotion: ShelfModel.reduceMotion)
    @Published var cueVisible = false
    @Published var cueToken = 0
    @Published var flyToken = 0
    private var generation = 0
    private var running = false

    func update(_ cfg: Config) {
        let next = PreviewPlan.make(cfg, reduceMotion: ShelfModel.reduceMotion)
        guard next != plan else { return }
        plan = next
        if running { cycle() }
    }

    func start() {
        guard !running else { return }
        running = true
        cycle()
    }

    func stop() {
        running = false
        generation += 1
    }

    private func cycle() {
        guard running else { return }
        generation += 1
        let g = generation
        let plan = self.plan
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            cueVisible = false
            model.shown = false
            model.lifting = false
            model.selection.clear()
            model.items.removeAll()
            model.expanded = plan.expanded
            model.locked = plan.locked
            if !plan.demoUnused { fill() }
        }
        for timed in plan.steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + timed.time) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, g == self.generation else { return }
                    self.run(timed.step)
                }
            }
        }
    }

    private func run(_ step: PreviewStep) {
        switch step {
        case .cue:
            withAnimation(.easeOut(duration: 0.18)) { cueVisible = true }
            cueToken += 1
        case .appear:
            withAnimation(.easeIn(duration: 0.15)) { cueVisible = false }
            model.shown = true
        case .drop:
            model.addPlaceholder("Photo.jpg", image: Self.photo, preview: true)
        case .expand:
            model.expand()
        case .collapse:
            model.collapse()
        case .dragOut:
            model.lifting = true
            flyToken += 1
            let removes = plan.removesOnDrag
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.lifting = false
                    if removes { self.model.finishDragOut(self.model.order, moved: true, autoClose: false) }
                }
            }
        case .close:
            model.shown = false
        case .end:
            cycle()
        case .emptyAppear:
            withAnimation(.easeIn(duration: 0.15)) { cueVisible = false }
            model.shown = true
        case .emptyClose:
            model.shown = false
        case .refill:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { fill() }
        }
    }

    private func fill() {
        model.addPlaceholder("Report.pdf", image: Self.pdfIcon, preview: false)
        model.addPlaceholder("Project", image: NSWorkspace.shared.icon(for: .folder), preview: false)
    }

    static let pdfIcon = NSWorkspace.shared.icon(for: .pdf)

    static let photo: NSImage = {
        let size = NSSize(width: 160, height: 120)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.96, green: 0.62, blue: 0.38, alpha: 1),
                                NSColor(srgbRed: 0.42, green: 0.40, blue: 0.86, alpha: 1)])?.draw(in: rect, angle: -35)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 46, y: rect.maxY - 46, width: 26, height: 26)).fill()
            return true
        }
    }()
}

struct PreviewCueView: View {
    @ObservedObject var driver: ShelfPreviewDriver

    var body: some View {
        Group {
            switch driver.plan.cue {
            case .shake(let amp, let swings):
                DraggedFile()
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: driver.cueToken) { content, x in
                        content.offset(x: x)
                    } keyframes: { _ in
                        KeyframeTrack {
                            for i in 0..<(swings * 2) {
                                CubicKeyframe(i % 2 == 0 ? amp : -amp, duration: i == 0 ? 0.12 : 0.16)
                            }
                            CubicKeyframe(0, duration: 0.12)
                        }
                    }
            case .hotkey(let name):
                Text(name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: Capsule())
            }
        }
        .opacity(driver.cueVisible ? 1 : 0)
        .scaleEffect(driver.cueVisible ? 1 : 0.9)
    }
}

struct DraggedFile: View {
    var cursor = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: ShelfPreviewDriver.pdfIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .opacity(0.85)
                .offset(x: 4, y: 7)
            if cursor {
                Image(nsImage: NSCursor.arrow.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: NSCursor.arrow.image.size.width, height: NSCursor.arrow.image.size.height)
                    .offset(x: -NSCursor.arrow.hotSpot.x, y: -NSCursor.arrow.hotSpot.y)
            }
        }
        .frame(width: 40, height: 44, alignment: .topLeading)
    }
}

struct PreviewFlyout: View {
    @ObservedObject var driver: ShelfPreviewDriver

    var body: some View {
        DraggedFile()
            .keyframeAnimator(initialValue: FlyState(), trigger: driver.flyToken) { content, s in
                content.offset(x: s.x, y: s.y).opacity(s.alpha)
            } keyframes: { _ in
                KeyframeTrack(\.alpha) {
                    LinearKeyframe(driver.flyToken == 0 ? 0 : 1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.55)
                    LinearKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.x) {
                    LinearKeyframe(0, duration: 0.08)
                    CubicKeyframe(130, duration: 0.85)
                }
                KeyframeTrack(\.y) {
                    LinearKeyframe(0, duration: 0.08)
                    CubicKeyframe(-22, duration: 0.85)
                }
            }
    }

    struct FlyState {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var alpha: Double = 0
    }
}

struct ShelfPreview: View {
    @ObservedObject var driver: ShelfPreviewDriver
    static let height: CGFloat = 206

    var body: some View {
        GeometryReader { geo in
            let card = ShelfModel.expandedSize(count: 3)
            let m = ShelfModel.margin
            let k = min(1, (Self.height - 44) / card.height)
            ZStack {
                LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ShelfView(model: driver.model, autoClose: { false }, close: {})
                    .frame(width: card.width + 2 * m, height: card.height + 2 * m)
                    .scaleEffect(k, anchor: .center)
                    .frame(width: geo.size.width, height: Self.height)
                    .allowsHitTesting(false)
                PreviewCueView(driver: driver)
                PreviewFlyout(driver: driver)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Text("Preview")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.3), in: Capsule())
                .padding(8)
        }
        .onAppear { driver.start() }
        .onDisappear { driver.stop() }
    }
}

var appVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(Identity.appName) \(version) (\(build))"
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    let tab: String
    var preview: ShelfPreviewDriver? = nil

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case "general": generalTab
                default: shelfTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Text(appVersion)
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .controlSize(.small)
        .frame(width: 480, height: 580)
    }

    private var shelfTab: some View {
        Form {
            if let preview {
                Section {
                    ShelfPreview(driver: preview)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            }
            Section {
                Picker("Hotkey", selection: $m.cfg.hotkey) {
                    ForEach(hotkeys) { Text($0.name).tag($0.id) }
                }
                .help("Opens an empty shelf at the pointer.")
                Toggle("Shake to open", isOn: $m.cfg.shake)
                    .help("Shake the pointer while dragging files.")
                Picker("Shake sensitivity", selection: $m.cfg.sensitivity) {
                    ForEach(Sensitivity.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!m.cfg.shake)
                Toggle("Keep empty shelves open", isOn: $m.cfg.keepEmpty)
                    .help("Off: a shelf opened by shaking closes again if you don't drop anything on it.")
                    .disabled(!m.cfg.shake)
                Toggle("Close when emptied", isOn: $m.cfg.autoClose)
                    .help("Close the shelf once every file has been dragged out.")
                Toggle("Open shelves expanded", isOn: $m.cfg.openExpanded)
                Toggle("New shelves start locked", isOn: $m.cfg.startLocked)
                    .help("Locked shelves keep their files after you drag them out.")
            } footer: {
                Text("Files stay put. Dropped images, links and text are kept privately until closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(isOn: $m.cfg.showMenuBarIcon) {
                    Text("Show in menu bar")
                    Text("When hidden, open \(Identity.appName) from Spotlight.")
                }
                Toggle("Open at login", isOn: $m.cfg.launchAtLogin)
            }
            Section {
                LabeledContent("Quit \(Identity.appName)") {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            UpdatesSection()
        }
        .formStyle(.grouped)
    }
}

final class SettingsTabs: NSTabViewController {
    static let lastKey = "settingsPane"
    static let panes = [("shelf", "Shelf", "tray"), ("general", "General", "gearshape")]

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.lastKey) }
    }
}

final class QuietWindow: NSWindow {
    override func noResponder(for eventSelector: Selector) {}

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    let preview = ShelfPreviewDriver()
    private var window: NSWindow?
    private var follower: AnyCancellable?

    override init() {
        super.init()
        follower = model.$cfg.sink { [weak self] cfg in self?.preview.update(cfg) }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        model.cfg = Config.load()
        if window == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            for (id, title, symbol) in SettingsTabs.panes {
                let host = NSHostingController(rootView: SettingsView(m: model, tab: id, preview: id == "shelf" ? preview : nil))
                host.sizingOptions = [.preferredContentSize]
                host.title = "\(Identity.appName) — \(title)"
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.identifier = id
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let w = QuietWindow(contentViewController: tabs)
            let start = CommandLine.arguments.first { $0.hasPrefix("--tab=") }.map { String($0.dropFirst(6)) }
                ?? UserDefaults.standard.string(forKey: SettingsTabs.lastKey) ?? "shelf"
            tabs.selectedTabViewItemIndex = SettingsTabs.panes.firstIndex { $0.0 == start } ?? 0
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.collectionBehavior = [.moveToActiveSpace]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        if UserDefaults.standard.string(forKey: SettingsTabs.lastKey) ?? "shelf" == "shelf" { preview.start() }
    }

    func windowWillClose(_ notification: Notification) {
        preview.stop()
    }
}
