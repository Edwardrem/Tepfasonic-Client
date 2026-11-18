import Foundation
import Security

public enum SecretStoreError: Error, LocalizedError, Sendable, Equatable {
    case keychain(OSStatus)
    case itemNotFound(String)
    case destinationNotEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .itemNotFound(let account):
            return "The Keychain has no item for \(account)."
        case .destinationNotEmpty(let account):
            return "The Keychain already has an item for \(account)."
        }
    }
}

/// Generic-password Keychain items under one service name. Secrets never
/// touch the SwiftData store or disk; the UI gates reads through `Vault`.
///
/// The login (file-based) keychain is used rather than the data-protection
/// keychain because the latter needs an application identifier entitlement
/// that only a Developer ID / App Store signature provides.
public struct SecretStore: Sendable {
    /// `TEPFA_KEYCHAIN_SERVICE` overrides the service so QA runs keep their own items.
    public static let defaultService = ProcessInfo.processInfo.environment["TEPFA_KEYCHAIN_SERVICE"] ?? "com.tepfasonic.client"
    public static let shared = SecretStore(service: defaultService)

    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Creates or replaces the item.
    public func set(_ data: Data, account: String, label: String? = nil) throws {
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label ?? "Tepfasonic: \(account)",
        ]
        let update = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        attributes.merge(baseQuery(account: account)) { current, _ in current }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(attributes as CFDictionary, nil)
        guard add == errSecSuccess else { throw SecretStoreError.keychain(add) }
    }

    public func set(_ string: String, account: String, label: String? = nil) throws {
        try set(Data(string.utf8), account: account, label: label)
    }

    /// Returns nil when there is no such item.
    public func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError.keychain(status)
        }
    }

    public func string(account: String) throws -> String? {
        try data(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Like `exists`, but reports a Keychain failure instead of treating it as "no item".
    public func itemExists(account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw SecretStoreError.keychain(status)
        }
    }

    public func exists(account: String) -> Bool {
        (try? itemExists(account: account)) ?? false
    }

    /// Whether the item starts with `prefix`, or false when there is no item. The value is read here,
    /// compared and never returned, so a caller learns one fact about the secret and not the secret.
    public func itemHasPrefix(account: String, prefix: String) throws -> Bool {
        guard let value = try string(account: account) else { return false }
        return value.hasPrefix(prefix)
    }

    /// Moves the item to another account without reading its data: one update of the account attribute and
    /// the label. Throws (and changes nothing) when the source is missing or the destination already has an
    /// item, so a move can never overwrite a key.
    public func move(from source: String, to destination: String, label: String) throws {
        if try itemExists(account: destination) {
            throw SecretStoreError.destinationNotEmpty(destination)
        }
        let attributes: [String: Any] = [
            kSecAttrAccount as String: destination,
            kSecAttrLabel as String: label,
        ]
        let status = SecItemUpdate(baseQuery(account: source) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw SecretStoreError.itemNotFound(source)
        // Another writer filled the destination between the check and the update.
        case errSecDuplicateItem: throw SecretStoreError.destinationNotEmpty(destination)
        default: throw SecretStoreError.keychain(status)
        }
    }

    /// Deleting a missing item is not an error.
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }

    /// Every account stored under this service.
    public func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    /// Removes every item under this service.
    public func deleteAll() throws {
        for account in try accounts() {
            try delete(account: account)
        }
    }
}
