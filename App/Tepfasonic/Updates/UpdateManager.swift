import AppKit
import Foundation
import Observation
import Security
import Sparkle
import TepfaCore

/// In-app updates.
///
/// Signed builds use Sparkle's normal flow (check, show notes, install in
/// place). Ad-hoc builds cannot be installed by Sparkle without Gatekeeper
/// refusing the result, so they fall back to download-only: the appcast is
/// read directly and the user is sent to the release download.
@MainActor
@Observable
final class UpdateManager: NSObject {
    static let betaChannelKey = "updates.betaChannel"
    static let automaticChecksKey = "updates.automaticChecks"
    static let skippedVersionKey = "updates.skippedVersion"
    static let lastCheckKey = "updates.lastCheck"

    enum Mode {
        /// Sparkle installs updates in place.
        case sparkle
        /// Ad-hoc signed or the feed key is a placeholder: offer the download only.
        case downloadOnly(reason: String)
    }

    private(set) var mode: Mode = .downloadOnly(reason: "")
    private(set) var isChecking = false
    private(set) var lastError: String?
    private(set) var lastCheck: Date?
    /// A download-only update waiting for the user's decision.
    var availableUpdate: Appcast.Item?
    var noUpdateMessage: String?

    private var controller: SPUStandardUpdaterController?

    var betaChannel: Bool {
        get { UserDefaults.standard.bool(forKey: Self.betaChannelKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.betaChannelKey) }
    }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticChecksKey)
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var feedURL: URL? {
        let base = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard var url = URL(string: base) else { return nil }
        if betaChannel {
            url = url.deletingLastPathComponent().appending(path: "appcast-beta.xml")
        }
        return url
    }

    override init() {
        super.init()
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        configure()
    }

    private func configure() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if publicKey.isEmpty || publicKey.hasPrefix("REPLACE") {
            mode = .downloadOnly(reason: "This build has no Sparkle signing key, so updates are download-only.")
        } else if !Self.isSignedWithDeveloperID() {
            mode = .downloadOnly(reason: "This build is not signed with a Developer ID, so Gatekeeper would block an in-place update. Updates are download-only.")
        } else {
            mode = .sparkle
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            controller.updater.automaticallyChecksForUpdates = automaticChecks
            controller.updater.updateCheckInterval = 86_400
            controller.startUpdater()
            self.controller = controller
        }
        if case .downloadOnly = mode, automaticChecks {
            Task { await checkInBackground() }
        }
    }

    /// True when the main bundle carries a Developer ID (or any team) signature.
    static func isSignedWithDeveloperID() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String != nil
    }

    // MARK: - Checking

    func checkForUpdates() {
        switch mode {
        case .sparkle:
            controller?.checkForUpdates(nil)
        case .downloadOnly:
            Task { await checkFeed(userInitiated: true) }
        }
    }

    private func checkInBackground() async {
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 86_400 { return }
        await checkFeed(userInitiated: false)
    }

    private func checkFeed(userInitiated: Bool) async {
        guard let feedURL else {
            lastError = "No update feed is configured."
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: feedURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateFeedError.status(http.statusCode)
            }
            let appcast = try Appcast.parse(data)
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            lastError = nil
            let channels: Set<String> = betaChannel ? ["beta"] : []
            if let update = appcast.newestUpdate(after: Self.currentVersion, allowedChannels: channels) {
                let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey)
                if userInitiated || skipped != update.version {
                    availableUpdate = update
                }
            } else if userInitiated {
                noUpdateMessage = "Tepfasonic \(Self.currentShortVersion) is up to date."
            }
        } catch {
            lastError = error.localizedDescription
            if userInitiated {
                noUpdateMessage = nil
            }
        }
    }

    func skip(_ item: Appcast.Item) {
        UserDefaults.standard.set(item.version, forKey: Self.skippedVersionKey)
        availableUpdate = nil
    }

    func download(_ item: Appcast.Item) {
        if let url = item.downloadURL {
            NSWorkspace.shared.open(url)
        }
        availableUpdate = nil
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURL?.absoluteString }
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { betaChannel ? ["beta"] : [] }
    }
}

/// The feed answered, but not with an appcast.
enum UpdateFeedError: LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(404): "The update feed has not been published yet (HTTP 404). Check the releases page for a newer build."
        case .status(let code): "The update feed answered HTTP \(code)."
        }
    }
}
