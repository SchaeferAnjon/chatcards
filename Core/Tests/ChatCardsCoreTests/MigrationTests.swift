import Foundation
import Testing
@testable import ChatCardsCore

/// 从 Anki Learn 搬数据：全在临时目录、临时 defaults 和临时钥匙串条目里做，不碰真数据
@Suite(.serialized) struct MigrationTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chatcards-migrate-\(UUID().uuidString)")
    var oldSupport: URL { root.appendingPathComponent("Anki Learn") }
    var newSupport: URL { root.appendingPathComponent("ChatCards") }
    // defaults 也放在临时目录里：名字是绝对路径时，plist 就写在那个路径
    var oldSuite: String { root.appendingPathComponent("old-defaults").path }
    var newSuite: String { root.appendingPathComponent("new-defaults").path }

    func oldSources() throws -> [Source] {
        var a = Source(kind: .claudeSession, title: "git rebase 和 merge 怎么选", origin: "s1")
        a.cards = [Card(CardDraft(q: "rebase 和 merge 有什么不同？", a: "一条直线 / 一个合并提交"))]
        let b = Source(kind: .web, title: "间隔重复", origin: "https://example.com")
        try SourceStore(url: oldSupport.appendingPathComponent("sources.json")).save([a, b])
        return [a, b]
    }

    func cleanUp(_ names: [String]) {
        try? FileManager.default.removeItem(at: root)
        for n in names { UserDefaults.standard.removePersistentDomain(forName: n) }
    }

    @Test func movesCardsSettingsAndKeyOnce() throws {
        defer { cleanUp([oldSuite, newSuite]) }
        let written = try oldSources()
        let oldDefaults = try #require(UserDefaults(suiteName: oldSuite))
        let newDefaults = try #require(UserDefaults(suiteName: newSuite))
        oldDefaults.set("deepseek-v4-pro", forKey: "model")
        oldDefaults.set(false, forKey: "thinking")
        oldDefaults.set(1_700_000_000_123, forKey: "ankiDeckID")
        oldDefaults.set("不相干", forKey: "somethingElse")

        // 真的钥匙串：两条临时条目，测完删掉
        let oldItem = KeychainItem(service: "chatcards-test-old-\(UUID().uuidString)", account: LegacyMigration.keyAccount)
        let newItem = KeychainItem(service: "chatcards-test-new-\(UUID().uuidString)", account: LegacyMigration.keyAccount)
        defer { oldItem.delete(); newItem.delete() }
        oldItem.save("sk-test-not-a-real-key")
        #expect(oldItem.read() == "sk-test-not-a-real-key")

        let report = try LegacyMigration.run(oldSupport: oldSupport, newSupport: newSupport,
                                             oldDefaults: oldDefaults, newDefaults: newDefaults,
                                             oldKey: oldItem.read, currentKey: newItem.read, saveKey: newItem.save)
        #expect(report.sources == 2)
        #expect(report.key)
        #expect(Set(report.settings) == ["model", "thinking", "ankiDeckID"])

        let moved = try SourceStore(url: newSupport.appendingPathComponent("sources.json")).load()
        #expect(moved == written)
        #expect(newDefaults.string(forKey: "model") == "deepseek-v4-pro")
        #expect(newDefaults.object(forKey: "thinking") as? Bool == false)
        #expect(newDefaults.object(forKey: "ankiDeckID") as? Int == 1_700_000_000_123)
        #expect(newDefaults.object(forKey: "somethingElse") == nil)
        #expect(newItem.read() == "sk-test-not-a-real-key")

        // 旧的一样不删
        #expect(FileManager.default.fileExists(atPath: oldSupport.appendingPathComponent("sources.json").path))
        #expect(oldItem.read() == "sk-test-not-a-real-key")
        #expect(oldDefaults.string(forKey: "model") == "deepseek-v4-pro")

        // 第二次启动不再搬：旧版之后又改了，也不会盖掉新版
        oldDefaults.set("deepseek-flash", forKey: "model")
        oldItem.save("sk-test-changed")
        let again = try LegacyMigration.run(oldSupport: oldSupport, newSupport: newSupport,
                                            oldDefaults: oldDefaults, newDefaults: newDefaults,
                                            oldKey: oldItem.read, currentKey: newItem.read, saveKey: newItem.save)
        #expect(again.isEmpty)
        #expect(newDefaults.string(forKey: "model") == "deepseek-v4-pro")
        #expect(newItem.read() == "sk-test-not-a-real-key")
    }

    @Test func keepsWhatTheNewVersionAlreadyHas() throws {
        defer { cleanUp([oldSuite, newSuite]) }
        _ = try oldSources()
        let mine = Source(kind: .document, title: "新版里做的", origin: "/tmp/a.pdf")
        try SourceStore(url: newSupport.appendingPathComponent("sources.json")).save([mine])
        let oldDefaults = try #require(UserDefaults(suiteName: oldSuite))
        let newDefaults = try #require(UserDefaults(suiteName: newSuite))
        oldDefaults.set("deepseek-v4-pro", forKey: "model")
        newDefaults.set("deepseek-flash", forKey: "model")
        var saved: [String] = []

        let report = try LegacyMigration.run(oldSupport: oldSupport, newSupport: newSupport,
                                             oldDefaults: oldDefaults, newDefaults: newDefaults,
                                             oldKey: { "sk-old" }, currentKey: { "sk-new" }, saveKey: { saved.append($0) })
        #expect(report.isEmpty)
        #expect(try SourceStore(url: newSupport.appendingPathComponent("sources.json")).load() == [mine])
        #expect(newDefaults.string(forKey: "model") == "deepseek-flash")
        #expect(saved.isEmpty)
    }

    @Test func nothingToMoveForANewUser() throws {
        defer { cleanUp([newSuite]) }
        let newDefaults = try #require(UserDefaults(suiteName: newSuite))
        let report = try LegacyMigration.run(oldSupport: oldSupport, newSupport: newSupport,
                                             oldDefaults: nil, newDefaults: newDefaults,
                                             oldKey: { "" }, currentKey: { "" }, saveKey: { _ in Issue.record("不该存 Key") })
        #expect(report.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: newSupport.path))
        #expect(newDefaults.bool(forKey: LegacyMigration.doneKey))
    }
}
