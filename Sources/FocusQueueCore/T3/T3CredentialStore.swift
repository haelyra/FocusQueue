import Foundation
import Security

/// A T3 Code OAuth access token. There is no refresh token. `description` never shows the token.
public struct T3Credential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var accessToken: String
    public var expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken; self.expiresAt = expiresAt
    }

    public var description: String {
        "T3Credential(accessToken: <redacted>, expiresAt: \(expiresAt.map { String(describing: $0) } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["accessToken": "<redacted>", "expiresAt": expiresAt as Any], displayStyle: .struct)
    }

    public func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

/// Where the T3 Code token lives. The live store is the Keychain; tests use `InMemoryT3CredentialStore`.
public protocol T3CredentialStoring: Sendable {
    /// Replaces any existing credential for the server.
    func save(_ credential: T3Credential, server: String) throws
    func load(server: String) throws -> T3Credential?
    /// Deleting a missing credential does not throw.
    func delete(server: String) throws
}

public enum T3CredentialAccount {
    /// The Keychain account for a server: the URL trimmed, lowercased, with no trailing slash.
    public static func normalized(_ server: String) -> String {
        var value = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

public enum T3CredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    case keychain(operation: String, status: Int32)
    case corruptItem

    public var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message)"
        case .corruptItem: return "The saved T3 Code credential could not be read."
        }
    }
}

/// A generic-password Keychain item: service `com.focusqueue.t3`, account = normalized server URL.
public struct KeychainT3CredentialStore: T3CredentialStoring {
    public static let defaultService = "com.focusqueue.t3"
    public let service: String

    public init(service: String = KeychainT3CredentialStore.defaultService) { self.service = service }

    private func query(_ server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: T3CredentialAccount.normalized(server)]
    }

    public func save(_ credential: T3Credential, server: String) throws {
        let data = try JSONEncoder.t3Credential.encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(query(server) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw T3CredentialStoreError.keychain(operation: "update", status: updateStatus)
        }
        var item = query(server)
        item.merge(attributes) { _, new in new }
        item[kSecAttrLabel as String] = "Focus Queue T3 Code access"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw T3CredentialStoreError.keychain(operation: "add", status: addStatus) }
    }

    public func load(server: String) throws -> T3Credential? {
        var search = query(server)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw T3CredentialStoreError.keychain(operation: "read", status: status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder.t3Credential.decode(T3Credential.self, from: data) else {
            throw T3CredentialStoreError.corruptItem
        }
        return credential
    }

    public func delete(server: String) throws {
        let status = SecItemDelete(query(server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw T3CredentialStoreError.keychain(operation: "delete", status: status)
        }
    }
}

/// Credentials held in memory only, keyed by normalized server URL. For tests.
public final class InMemoryT3CredentialStore: T3CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: T3Credential] = [:]

    public init(_ items: [String: T3Credential] = [:]) {
        for (server, credential) in items { self.items[T3CredentialAccount.normalized(server)] = credential }
    }

    public func save(_ credential: T3Credential, server: String) throws {
        lock.withLock { items[T3CredentialAccount.normalized(server)] = credential }
    }
    public func load(server: String) throws -> T3Credential? {
        lock.withLock { items[T3CredentialAccount.normalized(server)] }
    }
    public func delete(server: String) throws {
        _ = lock.withLock { items.removeValue(forKey: T3CredentialAccount.normalized(server)) }
    }
    public var isEmpty: Bool { lock.withLock { items.isEmpty } }
}

private extension JSONEncoder {
    static var t3Credential: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
}

private extension JSONDecoder {
    static var t3Credential: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
