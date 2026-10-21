import Foundation

enum SiblingShortcuts {
    static let apps: [(dir: String, name: String, keys: [String])] = [
        ("tidy", "Tidy", ["hotkey"]),
        ("stash", "Stash", ["hotkey"]),
        ("murmur", "Murmur", ["hotkey"]),
        ("linkway", "Linkway", ["copiedLinkShortcut"]),
    ]

    static func read(excluding own: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(RecordedShortcut, String)] {
        var out: [(RecordedShortcut, String)] = []
        for app in apps where app.dir != own && app.name != Identity.appName {
            let url = home.appendingPathComponent(".config/\(app.dir)/config.json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for key in app.keys {
                if let id = obj[key] as? String, let s = ShortcutRules.parse(id) { out.append((s, app.name)) }
            }
        }
        return out
    }
}
