import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

final class KeychainSessionStore: @unchecked Sendable {
    private let service = "com.fdecloud.os.secure-values"
    private let legacySessionKey = SecureValueKey(
        kind: .sessionToken,
        workspaceID: nil,
        provider: nil,
        connectorID: nil,
        name: "legacy-session-metadata"
    )

    func save(_ credential: SessionCredential) throws {
        let data = try JSONEncoder().encode(credential)
        try save(String(decoding: data, as: UTF8.self), for: legacySessionKey)
    }

    func load() throws -> SessionCredential? {
        guard let value = try load(for: legacySessionKey),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(SessionCredential.self, from: data)
    }

    func clear() throws {
        try delete(for: legacySessionKey)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

extension KeychainSessionStore: SecureValueStoring {
    func save(_ value: String, for key: SecureValueKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: key.account)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func load(for key: SecureValueKey) throws -> String? {
        var query = baseQuery(account: key.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(for key: SecureValueKey) throws {
        let status = SecItemDelete(baseQuery(account: key.account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
