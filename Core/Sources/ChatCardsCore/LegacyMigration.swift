import Foundation

/// ChatCards 以前叫 Anki Learn（bundle id com.ankilearn.app）。新版第一次启动把旧版的东西搬过来：
/// 做过的材料和卡片（Application Support/Anki Learn/sources.json）、设置（com.ankilearn.app 的 defaults）、
/// 钥匙串里的 DeepSeek Key（service com.ankilearn.app）。只复制，旧的一样不删，旧版照样能打开。
/// 新版这边已经有的不覆盖；搬完记一笔，以后不再搬。
public enum LegacyMigration {
    public static let oldBundleID = "com.ankilearn.app"
    public static let oldFolderName = "Anki Learn"
    public static let keyAccount = "deepseek-api-key"
    /// 新版 defaults 里记「搬过了」
    public static let doneKey = "migratedFromAnkiLearn"
    /// 旧版设置里的这几项（见 App/AppModel.swift 的 Prefs）
    public static let settingKeys = ["model", "thinking", "ankiDeck", "ankiDeckID", "ankiCustomizedStyle"]

    public struct Report: Equatable, Sendable {
        /// 搬过来几份材料（sources.json 里的条数）
        public var sources = 0
        public var key = false
        public var settings: [String] = []

        public var isEmpty: Bool { sources == 0 && !key && settings.isEmpty }

        public init() {}
    }

    /// - oldSupport / newSupport：旧版、新版放 sources.json 的文件夹
    /// - oldKey：读旧版 Key；currentKey / saveKey：新版的 Key（测试模式下是内存里的那份）
    /// 复制 sources.json 失败时抛错，不记「搬过了」，下次启动再试
    public static func run(oldSupport: URL, newSupport: URL,
                           oldDefaults: UserDefaults?, newDefaults: UserDefaults,
                           oldKey: () -> String, currentKey: () -> String, saveKey: (String) -> Void) throws -> Report {
        guard !newDefaults.bool(forKey: doneKey) else { return Report() }
        var report = Report()
        let fm = FileManager.default
        let oldFile = oldSupport.appendingPathComponent("sources.json")
        let newFile = newSupport.appendingPathComponent("sources.json")
        if fm.fileExists(atPath: oldFile.path), !fm.fileExists(atPath: newFile.path) {
            try fm.createDirectory(at: newSupport, withIntermediateDirectories: true)
            try fm.copyItem(at: oldFile, to: newFile)
            report.sources = (try? SourceStore(url: newFile).load().count) ?? 0
        }
        if let oldDefaults {
            for key in settingKeys where newDefaults.object(forKey: key) == nil {
                guard let value = oldDefaults.object(forKey: key) else { continue }
                newDefaults.set(value, forKey: key)
                report.settings.append(key)
            }
        }
        if currentKey().isEmpty {
            let key = oldKey()
            if !key.isEmpty {
                saveKey(key)
                report.key = true
            }
        }
        newDefaults.set(true, forKey: doneKey)
        return report
    }
}
