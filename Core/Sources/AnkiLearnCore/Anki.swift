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

/// 卡片在 Anki 里的样子：一个自己的笔记类型，五个字段。样式是 design/anki-cards 的方向 B「答案接棒」：
/// 一张纸，翻过来问题变灰、答案同样大接过重心，出处压成纸底一条，原话收进折叠
public enum AnkiNoteType {
    public static let name = "Anki Learn 卡片"
    static let fieldNames = ["问题", "答案", "补充", "原文", "来源"]
    static let templateName = "问答"
    /// CSS 第一行带它：Anki 里已有的笔记类型第一行不是它，就换成这一版的模板和样式
    static let version = "Anki Learn card · v2"

    static let front = """
    <div class="bl">
      <div class="qside">
        <div class="meta">{{Subdeck}}</div>
        <div class="q">{{问题}}</div>
      </div>
    </div>
    """

    /// 不用 {{FrontSide}}：纸要把问题和答案包在同一个元素里；也不用 id="answer"，免得 Anki 翻面时把长卡的问题滚走
    static let back = """
    <div class="bl flipped">
      <div class="qside">
        <div class="meta">{{Subdeck}}</div>
        <div class="q">{{问题}}</div>
      </div>
      <div class="aside">
        <div class="a">{{答案}}</div>
        {{#补充}}<div class="more">{{补充}}</div>{{/补充}}
      </div>
      <div class="foot">
        <div class="src">{{来源}}</div>
        {{#原文}}<details class="said"><summary>原话</summary><div class="quote">{{原文}}</div></details>{{/原文}}
      </div>
    </div>
    """

    static let css = """
    /* Anki Learn card · v2 · B 答案接棒 */
    .card {
      --bg: #FFFFFF; --surface: #F4F4F6;
      --text: #18191C; --text2: #5F636C; --text3: #969AA2;
      --border: rgba(0,0,0,.09); --accent: #5460D2;
      --sans: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", "Microsoft YaHei UI", "Noto Sans CJK SC", system-ui, sans-serif;
      --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
      --backdrop: #F2F2F4; --sheet: #FFFFFF; --band: #F8F8FA;
      --shadow: 0 1px 2px rgba(0,0,0,.04), 0 12px 32px -12px rgba(0,0,0,.10);
      margin: 0;
      color: var(--text);
      font-family: var(--sans); font-size: 17px; line-height: 1.6; text-align: left;
      letter-spacing: 0; font-kerning: normal; text-autospace: normal;
      -webkit-font-smoothing: antialiased; overflow-wrap: break-word;
    }
    .card.nightMode, .nightMode .card, .card.night_mode, .night_mode .card {
      --bg: #16171A; --surface: rgba(255,255,255,.07);
      --text: #EDEDEF; --text2: #9A9FA8; --text3: #6E7480;
      --border: rgba(255,255,255,.09); --accent: #8A94F5;
      --backdrop: #0F1012; --sheet: #1B1C1F; --band: #202125; --shadow: none;
    }

    /* 字段里的东西：行内代码、加粗、链接、图片、列表（也照顾在 Anki 里手改过的字段） */
    .card code { font-family: var(--mono); font-size: .88em; padding: .08em .36em; border-radius: 5px; background: var(--surface); overflow-wrap: anywhere; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
    .card pre { font-family: var(--mono); font-size: 14px; line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; background: var(--surface); padding: 12px 14px; border-radius: 8px; margin: 8px 0; }
    .card pre code { padding: 0; background: none; font-size: inherit; }
    .card b, .card strong { font-weight: 600; }
    .card a { color: var(--accent); text-decoration: none; }
    .card img { max-width: 100%; height: auto; border-radius: 8px; }
    .card ul, .card ol { margin: 4px 0; padding-left: 1.4em; }
    .src { font-size: 13px; line-height: 1.6; color: var(--text2); }
    .src .src-sep { color: var(--text3); white-space: pre; }
    .src a { font-weight: 500; }
    .src .src-kind, .src .src-date, .src a { white-space: nowrap; }
    /* 分类已经在问题上面写了，来源里不再重复 */
    .src .src-kind, .src .src-kind + .src-sep { display: none; }

    /* ===== 方向 B：答案接棒 ===== */
    .card { padding: 40px 24px 64px; background: var(--backdrop); }
    .bl { max-width: 620px; margin: 0 auto; background: var(--sheet); border: 1px solid var(--border); border-radius: 12px; box-shadow: var(--shadow); overflow: hidden; }
    .bl .qside { padding: 28px 32px 30px; }
    .bl .meta { font-size: 12px; line-height: 1.5; color: var(--text2); margin-bottom: 8px; }
    .bl .q { font-size: 24px; line-height: 1.45; font-weight: 600; text-wrap: pretty; }
    .bl.flipped .q { color: var(--text2); }
    .bl .aside { padding: 24px 32px 28px; border-top: 1px solid var(--border); }
    .bl .a { font-size: 24px; line-height: 1.45; font-weight: 600; text-wrap: pretty; }
    .bl .a code { font-size: .84em; }
    .bl .more { margin-top: 14px; font-size: 16px; line-height: 1.65; color: var(--text2); text-wrap: pretty; }
    .bl .pts { list-style: none; margin: 0; padding: 0; }
    .bl .pts li { position: relative; padding-left: 16px; }
    .bl .pts li + li { margin-top: 6px; }
    .bl .pts li::before { content: ""; position: absolute; left: 3px; top: .74em; width: 5px; height: 5px; border-radius: 50%; background: var(--text3); }
    .bl .foot { padding: 14px 32px 16px; border-top: 1px solid var(--border); background: var(--band); }
    .bl .src { display: flex; flex-wrap: wrap; align-items: baseline; }
    .bl .src .src-title { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bl .src .src-link { margin-left: auto; padding-left: 16px; }
    .bl .src .src-sep:has(+ .src-link) { display: none; }
    .bl .said { margin-top: 6px; }
    .bl .said > summary { display: inline-flex; align-items: center; gap: 8px; list-style: none; cursor: pointer; font-size: 13px; font-weight: 500; color: var(--text2); padding: 2px 0; }
    .bl .said > summary::-webkit-details-marker { display: none; }
    .bl .said > summary::before { content: ""; width: 5px; height: 5px; margin: 0 2px; border-right: 1.5px solid var(--text3); border-bottom: 1.5px solid var(--text3); transform: rotate(-45deg); transition: transform .15s; }
    .bl .said[open] > summary::before { transform: rotate(45deg); }
    .bl .said .quote { margin: 6px 0 2px 17px; font-size: 15px; line-height: 1.6; color: var(--text2); text-wrap: pretty; }

    @media (max-width: 520px) {
      .card { padding: 0; background: var(--sheet); font-size: 16px; }
      .bl { max-width: none; border: 0; border-radius: 0; box-shadow: none; }
      .bl .qside { padding: 20px 16px 22px; }
      .bl .q { font-size: 20px; }
      .bl .aside { padding: 20px 16px 22px; }
      .bl .a { font-size: 20px; }
      .bl .more { font-size: 15px; }
      .bl .foot { padding: 12px 16px 16px; }
      .bl .said > summary { padding: 8px 0; margin: -6px 0; }
    }
    """

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func fields(for card: Card, source: Source) -> [String: String] {
        [
            "问题": AnkiHTML.from(card.q),
            "答案": AnkiHTML.from(card.a),
            "补充": AnkiHTML.points(card.more),
            "原文": AnkiHTML.from(card.quote),
            "来源": sourceLine(source),
        ]
    }

    /// 来源一行拆成带 class 的几段：分类由正面的 {{Subdeck}} 写了，样式里藏掉 src-kind；去掉标签读出来还是「Claude Code · 标题 · 日期 · 打开原文」
    static func sourceLine(_ source: Source) -> String {
        let kind: String
        switch source.kind {
        case .claudeSession: kind = "Claude Code"
        case .document: kind = "文档"
        case .web: kind = "网页"
        }
        let sep = "<span class=\"src-sep\"> · </span>"
        var line = "<span class=\"src-kind\">\(kind)</span>\(sep)<span class=\"src-title\">\(AnkiHTML.escape(source.title))</span>"
        line += "\(sep)<span class=\"src-date\">\(dayFormatter.string(from: source.created))</span>"
        if let link = source.link {
            line += "\(sep)<a class=\"src-link\" href=\"\(AnkiHTML.escape(link))\">打开原文</a>"
        }
        return line
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

    /// 补充：模型一行写一条；两条以上写成要点，一条就是一段
    public static func points(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[-•·*]\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return from(text) }
        return "<ul class=\"pts\">" + lines.map { "<li>\(from($0))</li>" }.joined() + "</ul>"
    }

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
        guard !names.contains(AnkiNoteType.name) else {
            try await upgradeIfNeeded()
            return
        }
        _ = try await call("createModel", [
            "modelName": AnkiNoteType.name,
            "inOrderFields": AnkiNoteType.fieldNames,
            "css": AnkiNoteType.css,
            "isCloze": false,
            "cardTemplates": [["Name": AnkiNoteType.templateName, "Front": AnkiNoteType.front, "Back": AnkiNoteType.back]],
        ])
    }

    /// 笔记类型是老版本建的：换上这一版的模板和样式（只改文字和样式，不加删字段，Anki 不会要求单向同步）
    func upgradeIfNeeded() async throws {
        let styling = try await call("modelStyling", ["modelName": AnkiNoteType.name]) as? [String: Any]
        let css = styling?["css"] as? String ?? ""
        guard !css.contains(AnkiNoteType.version) else { return }
        _ = try await call("updateModelStyling", ["model": ["name": AnkiNoteType.name, "css": AnkiNoteType.css]])
        _ = try await call("updateModelTemplates", ["model": [
            "name": AnkiNoteType.name,
            "templates": [AnkiNoteType.templateName: ["Front": AnkiNoteType.front, "Back": AnkiNoteType.back]],
        ]])
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
