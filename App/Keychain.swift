import AnkiLearnCore
import Foundation
import Security

/// DeepSeek 的 API Key 存在登录钥匙串里；测试模式（E2EMode）只放在内存里，不碰钥匙串
enum Keychain {
    private static let service = "com.ankilearn.app"
    private static let account = "deepseek-api-key"
    private static var memory = ""

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String {
        if E2EMode.isOn { return memory }
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if E2EMode.isOn { memory = trimmed; return }
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
