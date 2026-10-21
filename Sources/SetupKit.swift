import AppKit
import SwiftUI

enum SetupLayout {
    static let size = CGSize(width: 520, height: 600)
    static let iconTop: CGFloat = 30
    static let iconSize: CGFloat = 72
    static let headerHeight: CGFloat = 92
    static let contentHeight: CGFloat = 244
    static let contentWidth: CGFloat = 424
    static let primaryWidth: CGFloat = 240
    static let linkRowHeight: CGFloat = 22
    static let bottomPadding: CGFloat = 24
    static let minGapAboveDots: CGFloat = 16
}

struct SetupPage: Equatable {
    var title: String
    var subtitle: String
    var primary: String
    var primaryEnabled = true
    var back = false
    var link: String?
}

struct SetupFrames: Equatable {
    var content: CGRect = .zero
    var dots: CGRect = .zero
    var primary: CGRect = .zero
    var links: CGRect = .zero

    mutating func set(_ key: String, _ r: CGRect) {
        switch key {
        case "content": content = r
        case "dots": dots = r
        case "primary": primary = r
        default: links = r
        }
    }

    var gapAboveDots: CGFloat { content.maxY == 0 ? 0 : dots.minY - content.maxY }
}

struct SetupScaffold<Content: View>: View {
    let step: Int
    let count: Int
    let forward: Bool
    let celebrating: Bool
    let page: (Int) -> SetupPage
    let onPrimary: () -> Void
    let onBack: () -> Void
    let onLink: () -> Void
    var report: (String, CGRect) -> Void = { _, _ in }
    @ViewBuilder let content: (Int) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: SetupPage { page(step) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: SetupLayout.iconSize, height: SetupLayout.iconSize)
                    .padding(.top, SetupLayout.iconTop)
                ZStack {
                    stepView(step)
                        .id(step)
                        .transition(transition)
                }
                .frame(width: SetupLayout.size.width, height: SetupLayout.headerHeight + SetupLayout.contentHeight)
                .clipped()
                .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.86), value: step)
                Spacer(minLength: SetupLayout.minGapAboveDots)
                footer
                    .padding(.bottom, SetupLayout.bottomPadding)
            }
            if celebrating {
                if reduceMotion {
                    DoneMark()
                } else {
                    Confetti()
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: SetupLayout.size.width, height: SetupLayout.size.height)
        .coordinateSpace(.named("setup"))
        .environment(\.controlActiveState, .key)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func stepView(_ s: Int) -> some View {
        let p = page(s)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(p.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(p.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 56)
            .padding(.top, 16)
            .frame(width: SetupLayout.size.width, height: SetupLayout.headerHeight, alignment: .top)
            content(s)
                .frame(width: SetupLayout.contentWidth, height: SetupLayout.contentHeight)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { r in
                    if s == step { report("content", r) }
                }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: step)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { report("dots", $0) }
            Button(action: onPrimary) {
                Text(current.primary)
                    .font(.body.weight(.semibold))
                    .frame(width: SetupLayout.primaryWidth - 32)
                    .contentTransition(.opacity)
            }
            .buttonStyle(SetupPrimaryStyle(enabled: current.primaryEnabled && !celebrating))
            .keyboardShortcut(.defaultAction)
            .disabled(!current.primaryEnabled || celebrating)
            .frame(width: SetupLayout.primaryWidth)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { report("primary", $0) }
            HStack(spacing: 18) {
                if current.back {
                    Button("Back", action: onBack)
                        .keyboardShortcut(.cancelAction)
                }
                if let link = current.link {
                    Button(link, action: onLink)
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .frame(width: SetupLayout.primaryWidth, height: SetupLayout.linkRowHeight)
            .disabled(celebrating)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { report("links", $0) }
        }
    }
}

struct SetupPrimaryStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(enabled ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.22))
                    .overlay(Capsule().strokeBorder(.white.opacity(enabled ? 0.18 : 0.06), lineWidth: 1))
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct SetupBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DoneMark: View {
    var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let p = min(1, context.date.timeIntervalSince(start) / 0.35)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(.green)
                .padding(28)
                .background(.ultraThinMaterial, in: Circle())
                .opacity(p)
                .scaleEffect(0.9 + 0.1 * p)
        }
    }
}

struct ConfettiPiece {
    let x: CGFloat
    let vx: CGFloat
    let vy: CGFloat
    let spin: Double
    let size: CGSize
    let color: Color
    let round: Bool
    let delay: Double

    static let palette: [Color] = [
        Color(red: 0xCD / 255, green: 0xD1 / 255, blue: 0xA6 / 255),
        Color(red: 0x95 / 255, green: 0x9B / 255, blue: 0x6C / 255),
        Color(red: 0x4B / 255, green: 0x4E / 255, blue: 0x52 / 255),
        Color(red: 0xCD / 255, green: 0xD1 / 255, blue: 0xA6 / 255),
        Color(red: 1.0, green: 0.42, blue: 0.42),
        Color(red: 0.36, green: 0.68, blue: 1.0),
        Color(red: 1.0, green: 0.8, blue: 0.3),
    ]

    static func burst(count: Int = 90, seed: UInt64 = 7) -> [ConfettiPiece] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            ConfettiPiece(x: CGFloat(rng.next(in: 0.2...0.8)),
                          vx: CGFloat(rng.next(in: -260...260)),
                          vy: CGFloat(rng.next(in: -720 ... -380)),
                          spin: rng.next(in: -8...8),
                          size: CGSize(width: rng.next(in: 6...10), height: rng.next(in: 9...15)),
                          color: palette[Int(rng.next(in: 0...Double(palette.count) - 0.001))],
                          round: rng.next(in: 0...1) < 0.25,
                          delay: rng.next(in: 0...0.12))
        }
    }

    func position(at t: Double, in size: CGSize) -> CGPoint {
        let tt = max(0, t - delay)
        let gravity = 900.0
        let px = Double(x * size.width) + Double(vx) * tt
        let py = Double(size.height) * 0.55 + Double(vy) * tt + 0.5 * gravity * tt * tt
        return CGPoint(x: px, y: py)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUnit() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}

struct Confetti: View {
    var start = Date()
    private let pieces = ConfettiPiece.burst()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { ctx, size in
                let fade = t > 1.1 ? max(0, 1 - (t - 1.1) / 0.45) : 1
                for p in pieces where t >= p.delay {
                    let pos = p.position(at: t, in: size)
                    var c = ctx
                    c.opacity = fade
                    c.translateBy(x: pos.x, y: pos.y)
                    c.rotate(by: .radians(p.spin * (t - p.delay)))
                    let rect = CGRect(x: -p.size.width / 2, y: -p.size.height / 2, width: p.size.width, height: p.size.height)
                    let shape = p.round ? Path(ellipseIn: rect.insetBy(dx: 0, dy: (p.size.height - p.size.width) / 2)) : Path(roundedRect: rect, cornerRadius: 2)
                    c.fill(shape, with: .color(p.color))
                }
            }
        }
    }
}

final class SetupHostWindow: NSWindow {
    override func noResponder(for eventSelector: Selector) {}
}

enum SetupHost {
    static let celebration: TimeInterval = 1.6
    static let calmCelebration: TimeInterval = 1.1

    @MainActor static func makeWindow<V: View>(_ view: V, delegate: NSWindowDelegate?) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        host.safeAreaRegions = []
        let w = SetupHostWindow(contentViewController: host)
        w.title = "Set Up \(Identity.appName)"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace]
        w.delegate = delegate
        w.setContentSize(SetupLayout.size)
        w.center()
        return w
    }

    @MainActor static func bringToFront(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
        w?.orderFrontRegardless()
    }

    static func celebrationDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? calmCelebration : celebration
    }
}

struct SetupAppRow<Trailing: View>: View {
    let icon: NSImage
    let name: String
    let tag: String?
    @ViewBuilder let trailing: Trailing

    static var height: CGFloat { 42 }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            Text(name).lineLimit(1)
            if let tag {
                Text(tag).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
    }
}

struct SetupFade: View {
    let enabled: Bool

    var body: some View {
        LinearGradient(stops: [.init(color: .black, location: 0),
                               .init(color: .black, location: enabled ? 0.82 : 1),
                               .init(color: .black.opacity(enabled ? 0.15 : 1), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}
