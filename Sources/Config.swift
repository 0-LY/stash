import Foundation

struct Config: Codable, Equatable {
    var hotkey = "ctrl-opt-d"
    var shake = true
    var sensitivity: Sensitivity = .medium
    var autoClose = true
    var openExpanded = false
    var startLocked = false
    var showMenuBarIcon = true
    var launchAtLogin = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = (try? c.decodeIfPresent(String.self, forKey: .hotkey)) ?? d.hotkey
        shake = (try? c.decodeIfPresent(Bool.self, forKey: .shake)) ?? d.shake
        sensitivity = (try? c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity)) ?? d.sensitivity
        autoClose = (try? c.decodeIfPresent(Bool.self, forKey: .autoClose)) ?? d.autoClose
        openExpanded = (try? c.decodeIfPresent(Bool.self, forKey: .openExpanded)) ?? d.openExpanded
        startLocked = (try? c.decodeIfPresent(Bool.self, forKey: .startLocked)) ?? d.startLocked
        showMenuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon)) ?? d.showMenuBarIcon
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(Identity.configDirName, isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    nonisolated(unsafe) private static var cache: Config?

    static var current: Config {
        if let cache { return cache }
        return load()
    }

    static func load() -> Config {
        let cfg = read()
        cache = cfg
        return cfg
    }

    private static func read() -> Config {
        lockDirectory()
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        protect(fileURL)
        guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let backup = directory.appendingPathComponent("config.unreadable.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: fileURL, to: backup)
                protect(backup)
            }
            return Config()
        }
        return cfg
    }

    static func save(_ cfg: Config) {
        lockDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        cache = cfg
        guard let data = try? enc.encode(cfg) else { return }
        try? data.write(to: fileURL, options: .atomic)
        protect(fileURL)
    }

    static func lockDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
