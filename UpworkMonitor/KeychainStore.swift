import Foundation
import Security

@MainActor
final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.hina.UpworkMonitor"

    func save<T: Encodable>(_ value: T, for key: String) async throws {
        let data = try JSONEncoder().encode(value)
        let service = self.service
        let status = await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data
            ]
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let updateAttributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                return SecItemAdd(query as CFDictionary, nil)
            }
            return updateStatus
        }.value
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    func load<T: Decodable>(_ type: T.Type, for key: String) async throws -> T? {
        let service = self.service
        let (status, data) = await Task.detached(priority: .userInitiated) { () -> (OSStatus, Data?) in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }.value
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw KeychainError.status(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(key: String) async throws {
        let service = self.service
        let status = await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            return SecItemDelete(query as CFDictionary)
        }.value
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return "Keychain error (\(status))."
        }
    }
}
