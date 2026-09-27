import Foundation
import Security

public enum KeychainStore {
    public static let service = "local.codex.YiDuTranslator"
    private static let account = "deepseek-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public static func load() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return key
    }

    public static func save(_ key: String) throws {
        let normalized = try normalizedAPIKey(key)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: LocalizedError, CustomStringConvertible {
    public let status: OSStatus
    public var errorDescription: String? {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return "无法访问钥匙串，请解锁 Mac 并允许译读访问已保存的密钥。"
        case errSecUserCanceled:
            return "已取消钥匙串授权。"
        default:
            return "钥匙串操作失败（错误码 \(status)）。请重试。"
        }
    }
    public var description: String { errorDescription ?? "钥匙串操作失败。" }
}
