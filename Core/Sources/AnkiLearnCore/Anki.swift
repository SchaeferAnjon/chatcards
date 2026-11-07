import Foundation

public enum AnkiError: LocalizedError, Equatable {
    /// 连不上：Anki 没开，或者没装 AnkiConnect 插件
    case notRunning
    case api(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Anki 没开着，或者没装 AnkiConnect 插件"
        case .api(let message): return "Anki 回了一个错误：\(message)"
        case .badResponse: return "Anki 的回答读不懂"
        }
    }
}

/// 送进 Anki 的结果，按卡片编号记
public struct AnkiAddResult: Equatable, Sendable {
    public var added: [UUID] = []
    /// Anki 的这个牌组里已经有一样的问题，没有重复加
    public var duplicates: [UUID] = []
    public var failed: [UUID: String] = [:]
}

/// 卡片在 Anki 里的样子：一个自己的笔记类型，五个字段
public enum AnkiNoteType {
    public static let name = "Anki Learn 卡片"
    static let fieldNames = ["问题", "答案", "补充", "原文", "来源"]

    static let front = """
    <div class="wrap"><div class="q">{{问题}}</div></div>
    """

    static let back = """
    <div class="wrap">
    <div class="q">{{问题}}</div>
    <hr id="answer">
    <div class="a">{{答案}}</div>
    {{#补充}}<div class="more">{{补充}}</div>{{/补充}}
    {{#原文}}<div class="quote">{{原文}}</div>{{/原文}}
    <div class="src">{{来源}}</div>
    </div>
    """

    static let css = """
    .card { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 18px; line-height: 1.6; text-align: left; color: #18191c; background: #fafafb; }
    .wrap { max-width: 640px; margin: 0 auto; padding: 24px 20px; }
    .q { font-size: 21px; font-weight: 600; line-height: 1.45; }
    hr#answer { border: none; border-top: 1px solid rgba(0,0,0,.09); margin: 20px 0; }
    .a { font-size: 19px; }
    .more { margin-top: 12px; font-size: 15px; color: #5f636c; }
    .quote { margin-top: 16px; padding-left: 12px; border-left: 2px solid rgba(84,96,210,.7); font-size: 14px; color: #5f636c; }
    .src { margin-top: 20px; font-size: 12px; color: #969aa2; }
    .src a { color: inherit; }
    code { font-family: Menlo, monospace; font-size: .88em; background: rgba(0,0,0,.05); padding: 1px 5px; border-radius: 4px; }
    .nightMode.card, .night_mode .card { color: #ededef; background: #16171a; }
    .nightMode hr#answer, .night_mode hr#answer { border-top-color: rgba(255,255,255,.08); }
    .nightMode .more, .nightMode .quote, .night_mode .more, .night_mode .quote { color: #8c919b; }
    .nightMode .quote, .night_mode .quote { border-left-color: rgba(138,148,245,.7); }
    .nightMode .src, .night_mode .src { color: #5c6370; }
    .nightMode code, .night_mode code { background: rgba(255,255,255,.08); }
    """

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func fields(for card: Card, source: Source) -> [String: String] {
        let date = dayFormatter.string(from: source.created)
        let kind: String
        switch source.kind {
        case .claudeSession: kind = "Claude Code"
        case .document: kind = "文档"
        case .web: kind = "网页"
        }
        var from = "\(kind) · \(AnkiHTML.escape(source.title)) · \(date)"
        if let link = source.link { from += " · <a href=\"\(AnkiHTML.escape(link))\">原文</a>" }
        return [
            "问题": AnkiHTML.from(card.q),
            "答案": AnkiHTML.from(card.a),
            "补充": AnkiHTML.from(card.more),
            "原文": AnkiHTML.from(card.quote),
            "来源": from,
        ]
    }

    static func tags(for card: Card) -> [String] {
        ["anki-learn"] + card.tags.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: "_") }.filter { !$0.isEmpty }
    }
}

/// 模型写的是纯文字（偶尔带 `代码` 和 **加粗**），Anki 字段是 HTML
public enum AnkiHTML {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let bold = try! NSRegularExpression(pattern: "\\*\\*([^*\\n]+)\\*\\*")

    public static func from(_ text: String) -> String {
        var s = escape(text.trimmingCharacters(in: .whitespacesAndNewlines))
        s = code.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<code>$1</code>")
        s = bold.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<b>$1</b>")
        return s.replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// AnkiConnect（Anki 的插件，只听本机 8765 端口）：发 {action, version, params}，回 {result, error}
public struct AnkiConnect: Sendable {
    public static let defaultURL = URL(string: "http://127.0.0.1:8765")!

    let url: URL
    let session: URLSession

    public init(url: URL = AnkiConnect.defaultURL, session: URLSession? = nil) {
        self.url = url
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    func call(_ action: String, _ params: [String: Any]? = nil) async throws -> Any? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["action": action, "version": 6]
        if let params { body["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw AnkiError.notRunning
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AnkiError.badResponse }
        if let error = json["error"] as? String { throw AnkiError.api(error) }
        return json["result"]
    }

    /// Anki 开着、AnkiConnect 在听就返回它的版本
    public func version() async throws -> Int {
        guard let v = try await call("version") as? Int else { throw AnkiError.badResponse }
        return v
    }

    /// 牌组和笔记类型缺了就建
    func prepare(deck: String) async throws {
        _ = try await call("createDeck", ["deck": deck])
        let names = (try await call("modelNames") as? [String]) ?? []
        guard !names.contains(AnkiNoteType.name) else { return }
        _ = try await call("createModel", [
            "modelName": AnkiNoteType.name,
            "inOrderFields": AnkiNoteType.fieldNames,
            "css": AnkiNoteType.css,
            "isCloze": false,
            "cardTemplates": [["Name": "问答", "Front": AnkiNoteType.front, "Back": AnkiNoteType.back]],
        ])
    }

    /// 把这些卡放进牌组；牌组里已经有同样问题的不重复加
    public func add(_ cards: [Card], from source: Source, deck: String) async throws -> AnkiAddResult {
        _ = try await version()
        try await prepare(deck: deck)
        let notes: [[String: Any]] = cards.map { card in
            [
                "deckName": deck,
                "modelName": AnkiNoteType.name,
                "fields": AnkiNoteType.fields(for: card, source: source),
                "tags": AnkiNoteType.tags(for: card),
                "options": ["allowDuplicate": false, "duplicateScope": "deck"],
            ]
        }
        guard let checks = try await call("canAddNotesWithErrorDetail", ["notes": notes]) as? [[String: Any]],
              checks.count == cards.count else { throw AnkiError.badResponse }

        var result = AnkiAddResult()
        var fresh: [(Card, [String: Any])] = []
        for ((card, note), check) in zip(zip(cards, notes), checks) {
            if check["canAdd"] as? Bool == true {
                fresh.append((card, note))
            } else if let error = check["error"] as? String, error.contains("duplicate") {
                result.duplicates.append(card.id)
            } else {
                result.failed[card.id] = check["error"] as? String ?? "加不进去"
            }
        }
        if !fresh.isEmpty {
            guard let ids = try await call("addNotes", ["notes": fresh.map(\.1)]) as? [Any], ids.count == fresh.count else {
                throw AnkiError.badResponse
            }
            for ((card, _), id) in zip(fresh, ids) {
                if id is NSNull { result.failed[card.id] = "加不进去" } else { result.added.append(card.id) }
            }
        }
        return result
    }

    /// 在 Anki 的卡片浏览器里打开这个牌组
    public func browse(deck: String) async throws {
        _ = try await call("guiBrowse", ["query": "deck:\"\(deck)\""])
    }
}
