import Foundation
import LocalAuthentication
import Observation

public enum VaultError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Unlock was cancelled."
        case .unavailable(let reason): "Secrets cannot be unlocked: \(reason)"
        }
    }
}

/// Gates access to Keychain secrets behind Touch ID, Apple Watch or the login
/// password, and locks again after a period of inactivity.
///
/// Reads of secrets call `ensureUnlocked` first. When the user has turned the
/// requirement off, the vault is always unlocked.
@MainActor
@Observable
public final class Vault {
    public static let shared = Vault()

    public static let requireAuthenticationKey = "security.requireAuthentication"
    public static let autoLockMinutesKey = "security.autoLockMinutes"
    public static let lockOnSleepKey = "security.lockOnSleep"

    public private(set) var isLocked = true
    public private(set) var lastUnlock: Date?
    /// Set when the last unlock attempt failed for a reason other than cancellation.
    public private(set) var lastError: String?

    private let defaults: UserDefaults
    private var lockTimer: Task<Void, Never>?
    /// Serialises concurrent unlock requests so only one system prompt shows.
    private var pendingUnlock: Task<Void, Error>?
    /// Test hook: replaces the LocalAuthentication prompt.
    var authenticator: @MainActor (String) async throws -> Void

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authenticator = { reason in
            let context = LAContext()
            context.localizedCancelTitle = "Cancel"
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                throw VaultError.unavailable(error?.localizedDescription ?? "no authentication method is set up")
            }
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch let laError as LAError where laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                throw VaultError.cancelled
            } catch {
                throw VaultError.unavailable(error.localizedDescription)
            }
        }
        if !requireAuthentication {
            isLocked = false
        }
    }

    // MARK: Settings

    public var requireAuthentication: Bool {
        get { defaults.object(forKey: Self.requireAuthenticationKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.requireAuthenticationKey)
            if !newValue { isLocked = false; lockTimer?.cancel() } else if lastUnlock == nil { isLocked = true }
        }
    }

    /// 0 means never.
    public var autoLockMinutes: Int {
        get { defaults.object(forKey: Self.autoLockMinutesKey) as? Int ?? 15 }
        set {
            defaults.set(newValue, forKey: Self.autoLockMinutesKey)
            if !isLocked { scheduleLock() }
        }
    }

    public var lockOnSleep: Bool {
        get { defaults.object(forKey: Self.lockOnSleepKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.lockOnSleepKey) }
    }

    // MARK: Locking

    /// Prompts the user if the vault is locked. Throws `VaultError.cancelled`
    /// when they dismiss the prompt.
    public func ensureUnlocked(reason: String) async throws {
        guard requireAuthentication else { return }
        if !isLocked {
            touch()
            return
        }
        if let pendingUnlock {
            try await pendingUnlock.value
            return
        }
        let task = Task<Void, Error> { @MainActor in
            try await authenticator(reason)
        }
        pendingUnlock = task
        defer { pendingUnlock = nil }
        do {
            try await task.value
            lastError = nil
            isLocked = false
            lastUnlock = .now
            scheduleLock()
        } catch {
            if case VaultError.cancelled = error {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    public func lock() {
        lockTimer?.cancel()
        lockTimer = nil
        if requireAuthentication {
            isLocked = true
        }
    }

    /// Call on user activity that uses secrets to push the auto-lock deadline back.
    public func touch() {
        if !isLocked, requireAuthentication {
            scheduleLock()
        }
    }

    /// Called from the sleep / screen-lock notifications.
    public func systemDidSleep() {
        if lockOnSleep { lock() }
    }

    private func scheduleLock() {
        lockTimer?.cancel()
        let minutes = autoLockMinutes
        guard minutes > 0 else {
            lockTimer = nil
            return
        }
        lockTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }
}
