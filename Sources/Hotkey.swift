import AppKit
import Carbon.HIToolbox

struct HotkeyOption: Identifiable {
    let id: String
    let name: String
}

let hotkeys = [
    HotkeyOption(id: "ctrl-opt-d", name: "⌃⌥D"),
    HotkeyOption(id: "ctrl-opt-s", name: "⌃⌥S"),
    HotkeyOption(id: "ctrl-shift-d", name: "⌃⇧D"),
    HotkeyOption(id: "opt-cmd-d", name: "⌥⌘D"),
    HotkeyOption(id: "off", name: "Off"),
]

func hotkeyName(_ id: String) -> String {
    hotkeys.first { $0.id == id }?.name ?? "⌃⌥D"
}

final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ id: String) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard id != "off" else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let (code, mods): (Int, Int) = switch id {
        case "ctrl-opt-s": (kVK_ANSI_S, controlKey | optionKey)
        case "ctrl-shift-d": (kVK_ANSI_D, controlKey | shiftKey)
        case "opt-cmd-d": (kVK_ANSI_D, optionKey | cmdKey)
        default: (kVK_ANSI_D, controlKey | optionKey)
        }
        let hotID = EventHotKeyID(signature: OSType(0x5354_5348), id: 1)
        RegisterEventHotKey(UInt32(code), UInt32(mods), hotID, GetApplicationEventTarget(), 0, &ref)
    }
}
