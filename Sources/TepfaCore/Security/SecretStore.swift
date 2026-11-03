import Foundation
import Security

public enum SecretStoreError: Error, LocalizedError, Sendable, Equatable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
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

    public func exists(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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
