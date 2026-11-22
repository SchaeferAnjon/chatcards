import Foundation

/// 测试模式：环境变量 E2E=1（或启动参数 -E2E 1）。App 照常跑，窗口不出现在屏幕上（App 里的 TestMode），
/// 也不读写你的真数据：做过的卡片存在临时目录（E2E_DATA_DIR 能指定），Claude 会话从 E2E_CLAUDE_DIR 读（没给就是临时目录里的空文件夹），
/// AnkiConnect 连 E2E_ANKI_URL（本机假的；没给就是没人听的端口，当作 Anki 没开），不往真的 Anki 里写卡
public enum E2EMode {
    public static let isOn: Bool = isOn(environment: ProcessInfo.processInfo.environment,
                                        arguments: ProcessInfo.processInfo.arguments)

    public static func isOn(environment: [String: String], arguments: [String]) -> Bool {
        if environment["E2E"] == "1" { return true }
        guard let i = arguments.firstIndex(of: "-E2E"), i + 1 < arguments.count else { return false }
        return ["1", "yes", "true"].contains(arguments[i + 1].lowercased())
    }

    public static let dataDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["E2E_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatCards-e2e-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    static func url(_ name: String) -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[name], !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
