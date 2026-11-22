import Foundation

/// 本机的一个 Claude Code 会话（~/.claude/projects/<文件夹>/<会话编号>.jsonl）
public struct SessionInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileURL: URL
    public let title: String
    /// 会话在哪个文件夹里跑的（只留最后一段）
    public let project: String
    public let modified: Date
    /// 连到 claude.ai 的会话才有：claude.ai/code/session_<它>
    public let remoteID: String?
    /// 怎么开的：cli（终端）、claude-vscode、sdk-ts（Dispatch 的 Agents 窗口）、sdk-cli（claude -p 脚本）
    public let entrypoint: String

    public var webURL: URL? {
        remoteID.flatMap { URL(string: "https://claude.ai/code/session_\($0)") }
    }
}

public enum SessionReadError: LocalizedError {
    case unreadable(URL)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "读不了会话记录：\(url.path)"
        case .empty: return "这个会话里没有能读的对话"
        }
    }
}

public enum ClaudeSessions {
    public static let defaultRoot: URL = {
        if E2EMode.isOn {
            if let raw = ProcessInfo.processInfo.environment["E2E_CLAUDE_DIR"], !raw.isEmpty {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            }
            return E2EMode.dataDirectory.appendingPathComponent("claude-projects", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }()

    /// 最近的会话，新的在前。不列：一句真正的提问都没有的，和 claude -p 脚本跑的（录音整理、designer 复审、起分支名这类）
    public static func list(root: URL = defaultRoot, limit: Int = 50) -> [SessionInfo] {
        var result: [SessionInfo] = []
        for (url, modified) in sessionFiles(root) {
            if let info = info(url: url, modified: modified), info.entrypoint != "sdk-cli" { result.append(info) }
            if result.count == limit { break }
        }
        return result
    }

    public static func find(sessionID: String, root: URL = defaultRoot) -> SessionInfo? {
        guard let (url, modified) = sessionFiles(root).first(where: { $0.0.deletingPathExtension().lastPathComponent == sessionID }) else { return nil }
        return info(url: url, modified: modified)
    }

    /// claude.ai/code/session_<remoteID> 对应的本机会话：会话记录里有一行 bridgeSessionId = cse_<remoteID>。
    /// 先看每个文件开头（通常在第 5 行左右），找不到再整个文件找（会话中途才连上 claude.ai 的）
    public static func find(remoteID: String, root: URL = defaultRoot) -> SessionInfo? {
        let needle = Data("\"bridgeSessionId\":\"cse_\(remoteID)\"".utf8)
        let files = sessionFiles(root)
        for (url, modified) in files where head(of: url, bytes: 512 * 1024)?.range(of: needle) != nil {
            return info(url: url, modified: modified)
        }
        for (url, modified) in files {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.range(of: needle) != nil else { continue }
            return info(url: url, modified: modified)
        }
        return nil
    }

    /// 读出对话：只留我说的话和 AI 的回答，工具调用、工具结果、思考过程、子 Agent、系统提醒都去掉
    public static func readTurns(from url: URL) throws -> [Turn] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw SessionReadError.unreadable(url) }
        var turns: [Turn] = []
        forEachLine(data) { line in
            guard let (role, text) = message(in: line) else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].text += "\n\n" + text
            } else {
                turns.append(Turn(role: role, text: text))
            }
        }
        guard !turns.isEmpty else { throw SessionReadError.empty }
        return turns
    }

    // MARK: - 内部

    static func sessionFiles(_ root: URL) -> [(URL, Date)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { continue }
            for url in items where url.pathExtension == "jsonl" {
                let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                files.append((url, date))
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    static func info(url: URL, modified: Date) -> SessionInfo? {
        guard let head = head(of: url, bytes: 512 * 1024) else { return nil }
        var remoteID: String?
        var cwd: String?
        var entrypoint: String?
        var firstPrompt: String?
        var title: String?
        forEachLine(head) { line in
            guard let obj = json(line) else { return }
            if remoteID == nil, obj["type"] as? String == "bridge-session", let id = obj["bridgeSessionId"] as? String, id.hasPrefix("cse_") {
                remoteID = String(id.dropFirst(4))
            }
            if obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String { title = t }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if entrypoint == nil, let e = obj["entrypoint"] as? String { entrypoint = e }
            if firstPrompt == nil, let (role, text) = message(obj), role == .me { firstPrompt = text }
        }
        // 标题会随着对话改，最新的在文件末尾
        if let tail = tail(of: url, bytes: 128 * 1024) {
            forEachLine(tail) { line in
                guard let obj = json(line), obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String else { return }
                title = t
            }
        }
        guard let firstPrompt else { return nil }
        let fallback = firstPrompt.split(separator: "\n").first.map(String.init) ?? firstPrompt
        return SessionInfo(
            id: url.deletingPathExtension().lastPathComponent,
            fileURL: url,
            title: title ?? String(fallback.prefix(60)),
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
            modified: modified,
            remoteID: remoteID,
            entrypoint: entrypoint ?? "cli"
        )
    }

    private static let userMark = Data("\"role\":\"user\"".utf8)
    private static let aiMark = Data("\"role\":\"assistant\"".utf8)

    /// 一行会话记录是不是一句对话；先看行首 400 字节有没有 role，没有就不解析（会话记录里大部分行是附件和请求记录，有的很大）
    static func message(in line: Data) -> (Turn.Role, String)? {
        let head = line.startIndex..<min(line.endIndex, line.startIndex + 400)
        guard line.range(of: userMark, in: head) != nil || line.range(of: aiMark, in: head) != nil,
              let obj = json(line) else { return nil }
        return message(obj)
    }

    static func message(_ obj: [String: Any]) -> (Turn.Role, String)? {
        let role: Turn.Role
        switch obj["type"] as? String {
        case "user": role = .me
        case "assistant": role = .ai
        default: return nil
        }
        if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return nil }
        guard let message = obj["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let s = message["content"] as? String {
            parts = [s]
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let text = role == .me ? cleanUserText(parts.joined(separator: "\n")) : parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (role, text)
    }

    private static let machineTags = try! NSRegularExpression(
        pattern: "<(system-reminder|command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat|task-notification|user-prompt-submit-hook)>.*?</\\1>",
        options: [.dotMatchesLineSeparators])
    private static let pasteTags = try! NSRegularExpression(pattern: "</?pasted_content[^>]*>")

    /// 去掉 Claude Code 自己塞进用户消息里的东西（系统提醒、斜杠命令、命令输出），粘贴的内容留下、只去掉标签
    static func cleanUserText(_ s: String) -> String {
        var t = machineTags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        t = pasteTags.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func forEachLine(_ data: Data, _ body: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { body(data[start..<end]) }
            start = end + 1
        }
    }

    static func head(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: bytes)
    }

    static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return try? handle.readToEnd()
    }
}
