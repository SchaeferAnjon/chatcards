import Foundation

/// 模型出的一张卡（还没进 Anki）
public struct CardDraft: Codable, Equatable, Sendable {
    public var q: String
    public var a: String
    public var more: String
    public var quote: String
    public var tags: [String]

    public init(q: String, a: String, more: String = "", quote: String = "", tags: [String] = []) {
        self.q = q
        self.a = a
        self.more = more
        self.quote = quote
        self.tags = tags
    }

    // 模型偶尔漏字段：缺的补空，问题或答案缺了这张不要
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        q = try c.decode(String.self, forKey: .q)
        a = try c.decode(String.self, forKey: .a)
        more = (try? c.decode(String.self, forKey: .more)) ?? ""
        quote = (try? c.decode(String.self, forKey: .quote)) ?? ""
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }
}

/// 材料是什么：写进请求里，让模型知道在读什么
public enum MaterialKind: Sendable {
    case claudeSession
    case document(title: String)

    var intro: String {
        switch self {
        case .claudeSession:
            return "材料：他和 AI 编程助手 Claude Code 的一段对话记录。【我】是他说的话，【AI】是 AI 的回答。"
        case .document(let title):
            return "材料：一份文档《\(title)》。"
        }
    }
}

public enum CardMaker {
    /// 一段最多这么多字。DeepSeek 能读 1M token，切小一点是为了每段都读得仔细
    public static let chunkLimit = 120_000
    /// 同时发几段
    static let parallel = 3

    public static let systemPrompt = """
    你帮人把学习材料做成 Anki 记忆卡片。请从材料里挑出值得长期记住的知识，做成问答卡片，用 JSON 输出。

    值得做成卡片的：
    - 讲清楚了的概念、原理和「为什么」
    - 以后还用得上的做法：命令、参数、API 和配置的写法、排查问题的步骤
    - 踩过的坑：什么症状、根因是什么、怎么解决
    - 查到的事实（版本、价格、限制）：问题里写明「截至 某年某月」
    - 如果材料是对话：他自己问到、AI 解释过的东西优先

    不要做成卡片的：
    - 只对这一次有用的细节：哪个文件改了哪行、任务编号、临时路径、提交号、界面上某个按钮放哪
    - 他个人的决定和偏好（选了 A 方案、喜欢某种颜色）
    - 闲聊、客套、进度汇报、工具调用的过程
    - 材料里没讲清楚、要你自己补充的知识（不要编）
    - 同一个知识点重复出卡

    卡片的写法：
    - 一张卡只问一个点。问题要离开材料也能看懂：写出具体的工具、语言、场景的名字，不写「这个项目」「上面那个」。
    - 答案尽量短：一句话或一条命令，最好不超过 40 个字；要展开的放进 more，最多 3 句。
    - quote：从材料里原样摘一句支撑这张卡的话，不超过 80 个字，方便回去找出处。
    - 用材料的语言写（材料主要是中文就写中文；命令、代码、专有名词保留原文）。
    - 宁缺毋滥：没有值得记的就返回空数组。

    只输出 JSON，格式：
    {"cards":[{"q":"问题","a":"答案","more":"补充说明，没有就空字符串","quote":"原文摘句","tags":["标签"]}]}
    """

    static func userMessage(_ material: MaterialKind, chunk: String, index: Int, count: Int) -> String {
        let part = count > 1 ? "（这是第 \(index + 1) 段，共 \(count) 段）" : ""
        return "\(material.intro)\(part)\n\n\(chunk)"
    }

    struct Reply: Decodable {
        let cards: [CardDraft]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 一张坏卡不连累整段
            let raw = try c.decode([Lenient].self, forKey: .cards)
            cards = raw.compactMap(\.card)
        }

        enum CodingKeys: String, CodingKey { case cards }

        struct Lenient: Decodable {
            let card: CardDraft?
            init(from decoder: Decoder) throws { card = try? CardDraft(from: decoder) }
        }
    }

    public static func parse(_ content: String) throws -> [CardDraft] {
        guard let data = content.data(using: .utf8), let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw DeepSeekError.badResponse
        }
        return reply.cards.filter {
            !$0.q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 几段一起发，回来的卡按段的顺序排好、去掉问题一样的
    public static func make(chunks: [String], material: MaterialKind, client: DeepSeek,
                            progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> ([CardDraft], Usage) {
        var results = [[CardDraft]](repeating: [], count: chunks.count)
        var usage = Usage()
        var done = 0
        try await withThrowingTaskGroup(of: (Int, [CardDraft], Usage).self) { group in
            var next = 0
            func launch() {
                let i = next
                next += 1
                let message = userMessage(material, chunk: chunks[i], index: i, count: chunks.count)
                group.addTask {
                    let (cards, usage) = try await one(message, client: client)
                    return (i, cards, usage)
                }
            }
            while next < min(parallel, chunks.count) { launch() }
            for try await (i, cards, u) in group {
                results[i] = cards
                usage = usage + u
                done += 1
                progress(done)
                if next < chunks.count { launch() }
            }
        }
        return (dedupe(results.flatMap { $0 }), usage)
    }

    /// 一段：回了空内容或读不懂的 JSON 就再试一次
    static func one(_ message: String, client: DeepSeek) async throws -> ([CardDraft], Usage) {
        var lastError: Error = DeepSeekError.badResponse
        for _ in 0..<2 {
            do {
                let (content, usage) = try await client.json(system: systemPrompt, user: message)
                return (try parse(content), usage)
            } catch let error as DeepSeekError where error == .blankAnswer || error == .badResponse {
                lastError = error
            }
        }
        throw lastError
    }

    public static func dedupe(_ cards: [CardDraft]) -> [CardDraft] {
        var seen = Set<String>()
        return cards.filter { seen.insert(key($0.q)).inserted }
    }

    /// 判断两个问题是不是同一个：忽略大小写、空白和标点
    public static func key(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
