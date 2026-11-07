import Foundation

/// 一张卡：模型出的，用户可以改、可以不勾
public struct Card: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var q: String
    public var a: String
    public var more: String
    public var quote: String
    public var tags: [String]
    public var selected: Bool
    /// 已经在 Anki 里了（这次加进去的，或者 Anki 里本来就有一样的问题）
    public var inAnki: Bool

    public init(_ draft: CardDraft) {
        id = UUID()
        q = draft.q
        a = draft.a
        more = draft.more
        quote = draft.quote
        tags = draft.tags
        selected = true
        inAnki = false
    }
}

/// 做卡片的一份材料：一个会话、一个文件或一个网页
public struct Source: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case claudeSession, document, web
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// 会话编号、文件路径或网址：重新生成时从这里再读一遍
    public var origin: String
    /// 能点开看原文的链接（claude.ai 上的会话、网页）
    public var link: String?
    /// 网页：打开时取下来的正文（重新生成时网页不一定还打得开）
    public var text: String?
    public var created: Date
    public var cards: [Card]
    public var generatedAt: Date?
    public var model: String?
    public var usage: Usage?

    public init(kind: Kind, title: String, origin: String, link: String? = nil) {
        id = UUID()
        self.kind = kind
        self.title = title
        self.origin = origin
        self.link = link
        created = Date()
        cards = []
    }
}

/// 所有材料和卡片存在一个 JSON 文件里
public struct SourceStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anki Learn", isDirectory: true)
            .appendingPathComponent("sources.json")
    }

    public func load() throws -> [Source] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Source].self, from: Data(contentsOf: url))
    }

    public func save(_ sources: [Source]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sources).write(to: url, options: .atomic)
    }
}
