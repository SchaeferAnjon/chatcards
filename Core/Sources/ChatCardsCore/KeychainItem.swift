import Foundation
import Security

/// 登录钥匙串里的一条普通密码（service + account）
public struct KeychainItem: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// 没有这一条（或你在系统弹窗里没让读）时是空字符串
    public func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 存空字符串就是删掉
    public func save(_ value: String) {
        delete()
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
