import AppKit
import Carbon.HIToolbox

let defaultHotkey = "ctrl-opt-d"

func hotkeyShortcut(_ id: String) -> RecordedShortcut? { id == "off" ? nil : ShortcutRules.parse(id) }

func hotkeyName(_ id: String) -> String {
    hotkeyShortcut(id)?.display ?? "Off"
}

func normalizedHotkey(_ id: String) -> String {
    if id == "off" { return id }
    return hotkeyShortcut(id)?.storageID ?? id
}

final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ id: String) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let shortcut = hotkeyShortcut(id) else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let hotID = EventHotKeyID(signature: OSType(0x5354_5348), id: 1)
        RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), hotID, GetApplicationEventTarget(), 0, &ref)
    }
}
