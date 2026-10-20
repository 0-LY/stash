import Foundation

enum Identity {
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let appName = info["CFBundleDisplayName"] as? String
        ?? info["CFBundleName"] as? String
        ?? ProcessInfo.processInfo.processName
    static let bundleId = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    static let configDirName = info["AppConfigDirName"] as? String ?? appName.lowercased()
    static let stateNotification = Notification.Name(bundleId + ".state")
}
