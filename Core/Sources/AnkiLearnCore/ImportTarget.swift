import Foundation

/// 粘贴进来的一段文字指的是什么
public enum ImportTarget: Equatable, Sendable {
    /// claude.ai/code/session_<id> 链接
    case claudeLink(remoteID: String, url: URL)
    /// 本机会话编号（ankilearn://session/<编号>，/anki 命令送来的）
    case localSession(id: String)
    case file(URL)
    case web(URL)

    private static let sessionLink = try! NSRegularExpression(pattern: "claude\\.ai/code/session_([A-Za-z0-9]+)")
    private static let uuid = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    public static func parse(_ raw: String) -> ImportTarget? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let m = sessionLink.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
            let id = String(text[r])
            return .claudeLink(remoteID: id, url: URL(string: "https://claude.ai/code/session_\(id)")!)
        }
        if let url = URL(string: text), url.scheme == "ankilearn", url.host == "session" {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : .localSession(id: id)
        }
        if uuid.firstMatch(in: text, range: range) != nil { return .localSession(id: text.lowercased()) }
        if let url = URL(string: text), url.isFileURL { return .file(url) }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return .file(URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            return .web(url)
        }
        return nil
    }
}
