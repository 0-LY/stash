import AppKit
import SwiftUI

enum StashSetup {
    static func shouldOfferSetup(fresh: Bool, background: Bool, gotFiles: Bool) -> Bool {
        fresh && !background && !gotFiles
    }
}

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, howItWorks, preferences }

    @Published var step = 0
    @Published var forward = true
    @Published var celebrating = false
    @Published var cfg = Config()
    @Published var frames = SetupFrames()
    let preview = ShelfPreviewDriver()
    var save: (Config) -> Void = { Config.save($0) }
    var onFinish: () -> Void = {}

    static let count = Step.allCases.count

    var current: Step { Step(rawValue: step) ?? .welcome }

    func reset(_ start: Config) {
        cfg = start
        step = 0
        forward = true
        celebrating = false
        preview.update(cfg)
    }

    func page(_ s: Int) -> SetupPage {
        let name = Identity.appName
        switch Step(rawValue: s) ?? .welcome {
        case .welcome:
            return SetupPage(title: "Welcome to \(name)",
                             subtitle: "A shelf for files on their way somewhere. Drop them, then drag them out where you need them.",
                             primary: "Get Started")
        case .howItWorks:
            return SetupPage(title: "Shake to open a shelf",
                             subtitle: "While you drag files, shake the pointer. Or press \(hotkeyName(cfg.hotkey)) any time.",
                             primary: "Continue", back: true)
        case .preferences:
            return SetupPage(title: "Make it yours", subtitle: "You can change these any time in Settings.",
                             primary: "Finish", back: true)
        }
    }

    func changed() { preview.update(cfg) }

    func primary() {
        if current == .preferences { finish() } else { go(1) }
    }

    func go(_ delta: Int) {
        forward = delta > 0
        step = max(0, min(Self.count - 1, step + delta))
        if current == .howItWorks { preview.start() } else { preview.stop() }
    }

    func finish() {
        preview.stop()
        save(cfg)
        celebrating = true
        onFinish()
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SetupScaffold(step: m.step, count: SetupModel.count, forward: m.forward, celebrating: m.celebrating,
                      page: { m.page($0) },
                      onPrimary: primary, onBack: { m.go(-1) }, onLink: {},
                      report: { m.frames.set($0, $1) }) { s in
            switch SetupModel.Step(rawValue: s) ?? .welcome {
            case .welcome: welcomeContent
            case .howItWorks: howContent
            case .preferences: preferencesContent
            }
        }
        .ignoresSafeArea()
        .onChange(of: m.cfg) { _, _ in m.changed() }
    }

    private func primary() {
        let finishing = m.current == .preferences
        m.primary()
        if finishing {
            DispatchQueue.main.asyncAfter(deadline: .now() + SetupHost.celebrationDuration(reduceMotion: reduceMotion)) { close() }
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            SetupBox {
                VStack(spacing: 0) {
                    feature("hand.draw", "Shake while dragging", "A shelf appears right under the pointer.")
                    Divider().padding(.leading, 56)
                    feature("tray.and.arrow.down", "Drop files on it", "Files stay where they are, nothing is copied.")
                    Divider().padding(.leading, 56)
                    feature("square.and.arrow.up", "Drag them out later", "Or share, copy and Quick Look them.")
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var howContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ShelfPreview(driver: m.preview)
            Text("Drop more files any time. Drag the pile to take them all out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var preferencesContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Hotkey").font(.headline)
                Picker("", selection: $m.cfg.hotkey) {
                    ForEach(hotkeys) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                Text("Opens an empty shelf at the pointer.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Shake sensitivity").font(.headline)
                Picker("", selection: $m.cfg.sensitivity) {
                    ForEach(Sensitivity.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                Text("High opens a shelf with a gentle shake.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $m.cfg.keepEmpty) {
                Text("Keep empty shelves open")
                Text("Off: a shaken-open shelf closes again if you don't drop anything.")
            }
            .toggleStyle(.switch)
            Spacer(minLength: 0)
        }
    }
}

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private let model = SetupModel()
    private var window: NSWindow?
    var onFinish: () -> Void = {}

    func show() {
        model.reset(Config.load())
        model.onFinish = { [weak self] in self?.onFinish() }
        if window == nil {
            window = SetupHost.makeWindow(SetupView(m: model) { [weak self] in self?.window?.close() }, delegate: self)
        }
        SetupHost.bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        model.preview.stop()
    }
}
