import AppKit
import UniformTypeIdentifiers

enum OpenGuard {
    static let riskyExtensions: Set<String> = [
        "app", "command", "terminal", "tool", "sh", "zsh", "bash", "csh", "ksh", "fish", "py", "pl", "rb",
        "fileloc", "inetloc", "webloc", "url", "workflow", "action", "pkg", "mpkg", "scpt", "scptd",
        "applescript", "jar", "prefpane", "qlgenerator", "saver", "kext", "dylib", "osax",
    ]

    static let riskyTypes: [UTType] = [.application, .applicationBundle, .executable, .script, .shellScript,
                                       .unixExecutable, .internetLocation]

    static func isRisky(ext: String, types: [UTType], isDirectory: Bool, executableBit: Bool) -> Bool {
        if riskyExtensions.contains(ext.lowercased()) { return true }
        if types.contains(where: { t in riskyTypes.contains { t.conforms(to: $0) } && !t.conforms(to: .folder) }) { return true }
        return executableBit && !isDirectory
    }

    static func needsConfirmation(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        let isDirectory = !(values?.isRegularFile ?? true)
        var types: [UTType] = []
        if let t = values?.contentType { types.append(t) }
        if let t = UTType(filenameExtension: url.pathExtension) { types.append(t) }
        let exec = FileManager.default.isExecutableFile(atPath: url.path)
        return isRisky(ext: url.pathExtension, types: types, isDirectory: isDirectory, executableBit: exec)
    }

    static func message(for urls: [URL]) -> (title: String, detail: String) {
        if urls.count == 1, let url = urls.first {
            return ("Open “\(url.lastPathComponent)”?",
                    "It's an app, script or link file. Opening it can run code or open places on your Mac. Only open it if you trust where it came from.")
        }
        return ("Open \(urls.count) items?",
                "Some of them are apps, scripts or link files. Opening them can run code or open places on your Mac. Only open them if you trust where they came from.")
    }

    @MainActor
    static func confirm(_ urls: [URL]) -> Bool {
        let text = message(for: urls)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}

enum Quarantine {
    static func value(agent: String, date: Date = Date()) -> String {
        String(format: "0081;%08x;%@;", Int(date.timeIntervalSince1970), agent)
    }

    static func isMarked(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    @discardableResult
    static func mark(_ url: URL, agent: String = Identity.appName) -> Bool {
        if isMarked(url) { return true }
        let data = Array(value(agent: agent).utf8)
        return setxattr(url.path, "com.apple.quarantine", data, data.count, 0, XATTR_NOFOLLOW) == 0
    }
}

enum SingleInstance {
    static func others(bundleId: String, own: pid_t) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { $0.processIdentifier != own && !$0.isTerminated }
    }

    static func shouldExit(otherPIDs: [pid_t], own: pid_t) -> Bool {
        otherPIDs.contains { $0 != own }
    }
}
