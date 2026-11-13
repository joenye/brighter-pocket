import AppKit
import Sparkle

/// Brighter Pocket Companion's own updates, through Sparkle 2 (pocket/patches/0034).
///
/// The feed is an appcast attached to the latest GitHub release
/// (Info.plist SUFeedURL: releases/latest/download/appcast.xml); each item is the
/// release's DMG, signed with the project's EdDSA key, whose public half is built
/// into the app (SUPublicEDKey, from tools/release/sparkle-public-key.txt). Sparkle
/// checks on its own schedule and shows the release notes (CHANGELOG.md) with each
/// update; nothing installs without the user's say-so (SUAutomaticallyUpdate is
/// off). A build without the public key (a local build, or one from a fork) has no
/// way to check what it would install, so updates are off there and the menu says so.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// Off in a build without a public key, and while unit tests host the app.
    let isAvailable: Bool
    /// False while a check or an install is already under way (Sparkle reports it
    /// over KVO only, so it is mirrored here for SwiftUI).
    private(set) var canCheckForUpdates = false
    /// Sparkle's own setting (SUEnableAutomaticChecks in the defaults), which Settings shows.
    var checksAutomatically = false {
        didSet {
            if let updater = controller?.updater, updater.automaticallyChecksForUpdates != checksAutomatically {
                updater.automaticallyChecksForUpdates = checksAutomatically
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        isAvailable = !testing && Self.isEdKey(key)
        guard isAvailable else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = can }
        }
    }

    /// A Sparkle EdDSA public key: the base64 of 32 bytes.
    nonisolated static func isEdKey(_ text: String) -> Bool {
        Data(base64Encoded: text)?.count == 32
    }

    /// Asked for by the user, so Sparkle always answers, "up to date" and errors too.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}
