import ChatCardsCore
import Foundation

/// DeepSeek 的 API Key 存在登录钥匙串里；测试模式（E2EMode）只放在内存里，不碰钥匙串
enum Keychain {
    private static let item = KeychainItem(service: "io.github.schaeferanjon.chatcards", account: LegacyMigration.keyAccount)
    private static var memory = ""

    static func read() -> String {
        E2EMode.isOn ? memory : item.read()
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if E2EMode.isOn { memory = trimmed } else { item.save(trimmed) }
    }
}
