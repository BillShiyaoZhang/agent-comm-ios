import Foundation
#if canImport(Security)
import Security
#endif

/// Apple platforms persist secrets in the device-only Keychain; other hosts use memory only.
public final class SecureStore: @unchecked Sendable {
    private let namespace: String
    #if !canImport(Security)
    private static let lock = NSLock()
    private static var memory: [String: Data] = [:]
    #endif

    public init(namespace: String) { self.namespace = namespace }

    public func data(key: String) throws -> Data? {
        #if canImport(Security)
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WorkspaceClientError.secureStorage(Int(status)) }
        return result as? Data
        #else
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.memory[namespace + "\u{0}" + key]
        #endif
    }

    public func set(_ data: Data, for key: String) throws {
        #if canImport(Security)
        let query = baseQuery(key)
        let values: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw WorkspaceClientError.secureStorage(Int(added)) }
        } else if status != errSecSuccess { throw WorkspaceClientError.secureStorage(Int(status)) }
        #else
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.memory[namespace + "\u{0}" + key] = data
        #endif
    }

    public func remove(key: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceClientError.secureStorage(Int(status)) }
        #else
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.memory.removeValue(forKey: namespace + "\u{0}" + key)
        #endif
    }

    #if canImport(Security)
    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace, kSecAttrAccount as String: key]
    }
    #endif
}
