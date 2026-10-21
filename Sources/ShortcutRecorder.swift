import AppKit
import Carbon.HIToolbox
import SwiftUI

struct RecordedShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    var carbonModifiers: Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    var storageID: String { "key:\(keyCode):\(modifiers)" }

    init?(storageID: String) {
        let parts = storageID.split(separator: ":")
        guard parts.count == 3, parts[0] == "key", let code = UInt16(parts[1]), let mods = UInt(parts[2]) else { return nil }
        keyCode = code
        modifiers = NSEvent.ModifierFlags(rawValue: mods).intersection(Self.relevant).rawValue
    }

    var display: String { ShortcutRules.symbols(flags) + ShortcutRules.keyName(keyCode) }
}

enum ShortcutCheck: Equatable {
    case ok
    case needsModifier
    case system(String)
    case conflict(String)

    var message: String? {
        switch self {
        case .ok: nil
        case .needsModifier: "Add ⌃, ⌥ or ⌘ — or use an F-key."
        case .system(let name): "macOS uses this for \(name)."
        case .conflict(let name): "Also used by \(name)."
        }
    }

    var blocks: Bool {
        switch self {
        case .needsModifier, .system: true
        default: false
        }
    }
}

enum ShortcutRules {
    static let functionKeys: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4), UInt16(kVK_F5), UInt16(kVK_F6),
        UInt16(kVK_F7), UInt16(kVK_F8), UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16), UInt16(kVK_F17), UInt16(kVK_F18),
        UInt16(kVK_F19), UInt16(kVK_F20),
    ]

    static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static let system: [(RecordedShortcut, String)] = [
        (RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: .command), "Spotlight"),
        (RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: [.command, .option]), "Finder search"),
        (RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: .control), "switching input source"),
        (RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option]), "switching input source"),
        (RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .command]), "the emoji picker"),
        (RecordedShortcut(keyCode: UInt16(kVK_Tab), modifiers: .command), "switching apps"),
        (RecordedShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.command, .shift]), "switching apps"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .command), "switching windows"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .shift]), "screenshots"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift]), "screenshots"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_5), modifiers: [.command, .shift]), "screenshots"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_6), modifiers: [.command, .shift]), "screenshots"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_Q), modifiers: .command), "quitting apps"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: .command), "closing windows"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_H), modifiers: .command), "hiding apps"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: .command), "minimizing windows"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: .command), "Copy"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: .command), "Paste"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_X), modifiers: .command), "Cut"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: .command), "Undo"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: .command), "Select All"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.control, .command]), "locking the screen"),
        (RecordedShortcut(keyCode: UInt16(kVK_Escape), modifiers: [.command, .option]), "Force Quit"),
        (RecordedShortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: [.control, .command]), "full screen"),
    ]

    static func check(_ s: RecordedShortcut, conflicts: [(RecordedShortcut, String)] = []) -> ShortcutCheck {
        let mods = s.flags
        let needsMod = !functionKeys.contains(s.keyCode)
        if needsMod && mods.intersection([.command, .option, .control]).isEmpty { return .needsModifier }
        if let hit = system.first(where: { $0.0 == s }) { return .system(hit.1) }
        if let hit = conflicts.first(where: { $0.0 == s }) { return .conflict(hit.1) }
        return .ok
    }

    static func symbols(_ f: NSEvent.ModifierFlags) -> String {
        var out = ""
        if f.contains(.control) { out += "⌃" }
        if f.contains(.option) { out += "⌥" }
        if f.contains(.shift) { out += "⇧" }
        if f.contains(.command) { out += "⌘" }
        return out
    }

    static let names: [UInt16: String] = {
        var m: [UInt16: String] = [
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
            UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
            UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟", UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
            UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_Semicolon): ";",
            UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",", UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
            UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Grave): "`",
        ]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"),
            (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"),
            (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        for (code, name) in letters { m[UInt16(code)] = name }
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                     kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fkeys.enumerated() { m[UInt16(code)] = "F\(i + 1)" }
        return m
    }()

    static func keyName(_ code: UInt16) -> String { names[code] ?? "Key \(code)" }

    static func parse(_ id: String) -> RecordedShortcut? {
        if let s = RecordedShortcut(storageID: id) { return s }
        let parts = id.lowercased().split(separator: "-").map(String.init)
        guard let key = parts.last, parts.count >= 2 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": flags.insert(.control)
            case "opt", "alt", "option": flags.insert(.option)
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            default: return nil
            }
        }
        let wanted = key == "space" ? "Space" : key.uppercased()
        guard let code = names.first(where: { $0.value == wanted })?.key else { return nil }
        return RecordedShortcut(keyCode: code, modifiers: flags)
    }
}

@MainActor
final class ShortcutRecording: ObservableObject {
    @Published var active = false
    @Published var problem: String?
    private var monitor: Any?

    func begin(conflicts: [(RecordedShortcut, String)], onSave: @escaping (RecordedShortcut?) -> Void) {
        end()
        active = true
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.active else { return event }
            let code = event.keyCode
            if code == UInt16(kVK_Escape), event.modifierFlags.intersection(RecordedShortcut.relevant).isEmpty {
                self.end()
                return nil
            }
            if code == UInt16(kVK_Delete) || code == UInt16(kVK_ForwardDelete),
               event.modifierFlags.intersection(RecordedShortcut.relevant).isEmpty {
                self.end()
                onSave(nil)
                return nil
            }
            guard !ShortcutRules.modifierKeys.contains(code) else { return nil }
            let shortcut = RecordedShortcut(keyCode: code, modifiers: event.modifierFlags)
            let check = ShortcutRules.check(shortcut, conflicts: conflicts)
            if check.blocks {
                self.problem = check.message
                return nil
            }
            self.problem = check.message
            self.active = false
            self.removeMonitor()
            onSave(shortcut)
            return nil
        }
    }

    func end() {
        active = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: RecordedShortcut?
    var defaultShortcut: RecordedShortcut?
    var conflicts: [(RecordedShortcut, String)] = []
    @StateObject private var recording: ShortcutRecording

    init(shortcut: Binding<RecordedShortcut?>, defaultShortcut: RecordedShortcut? = nil,
         conflicts: [(RecordedShortcut, String)] = [], recording: ShortcutRecording? = nil) {
        _shortcut = shortcut
        self.defaultShortcut = defaultShortcut
        self.conflicts = conflicts
        _recording = StateObject(wrappedValue: recording ?? ShortcutRecording())
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    if recording.active {
                        recording.end()
                    } else {
                        recording.begin(conflicts: conflicts) { shortcut = $0 }
                    }
                } label: {
                    Text(label)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(minWidth: 110)
                        .foregroundStyle(recording.active ? Color(nsColor: .controlAccentColor) : .primary)
                }
                .help(recording.active ? "Press keys · Esc cancels · Delete clears" : "Click, then press the keys you want")
                if let defaultShortcut, shortcut != defaultShortcut {
                    Button {
                        recording.end()
                        shortcut = defaultShortcut
                        recording.problem = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultShortcut.display)")
                }
            }
            if let problem = recording.problem ?? warning {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { recording.end() }
    }

    private var label: String {
        if recording.active { return "Press keys…" }
        return shortcut?.display ?? "Click to record"
    }

    private var warning: String? {
        guard let shortcut, !recording.active else { return nil }
        if case .conflict(let name) = ShortcutRules.check(shortcut, conflicts: conflicts) { return "Also used by \(name)." }
        return nil
    }
}
