import AppKit
import Combine
import Sparkle
import SwiftUI

final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    static let betaKey = "betaUpdates"

    @Published var canCheck = false
    @Published var automaticChecks = true {
        didSet { if updater.automaticallyChecksForUpdates != automaticChecks { updater.automaticallyChecksForUpdates = automaticChecks } }
    }
    @Published var automaticDownloads = true {
        didSet { if updater.automaticallyDownloadsUpdates != automaticDownloads { updater.automaticallyDownloadsUpdates = automaticDownloads } }
    }
    @Published var beta = UserDefaults.standard.bool(forKey: Updates.betaKey) {
        didSet {
            UserDefaults.standard.set(beta, forKey: Self.betaKey)
            if beta != oldValue { updater.resetUpdateCycleAfterShortDelay() }
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?

    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller.startUpdater()
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        observation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        beta ? ["beta"] : []
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
}

struct UpdatesSection: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
            Toggle("Download and install automatically", isOn: $updates.automaticDownloads)
                .disabled(!updates.automaticChecks)
            Toggle(isOn: $updates.beta) {
                Text("Get beta updates")
                Text("Try new features early. Betas may be less stable.")
            }
            LabeledContent("Updates") {
                Button("Check Now") { updates.checkNow() }
                    .disabled(!updates.canCheck)
            }
        }
    }
}
