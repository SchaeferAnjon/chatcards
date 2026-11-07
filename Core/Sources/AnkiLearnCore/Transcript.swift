import Foundation

/// 对话里的一轮：我说的，或者 AI 回的（连续几条同一方的话并成一轮）
public struct Turn: Equatable, Sendable {
    public enum Role: String, Sendable { case me, ai }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public enum TranscriptText {
    static func block(_ turn: Turn) -> String {
        "\(turn.role == .me ? "【我】" : "【AI】")\n\(turn.text)"
    }

    public static func render(_ turns: [Turn]) -> String {
        turns.map(block).joined(separator: "\n\n")
    }

    /// 对话切成每段不超过 limit 个字的几段，在两轮之间切
    public static func chunks(_ turns: [Turn], limit: Int) -> [String] {
        pack(turns.map(block), limit: limit)
    }

    /// 普通文档（PDF、网页、Markdown）：在段落之间切
    public static func chunks(plain text: String, limit: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pack(paragraphs, limit: limit)
    }

    /// 一块一块往一段里放，放不下就开新的一段；一块本身就超长时按字硬切
    private static func pack(_ blocks: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for block in blocks {
            if block.count > limit {
                flush()
                var rest = Substring(block)
                while !rest.isEmpty {
                    let end = rest.index(rest.startIndex, offsetBy: limit, limitedBy: rest.endIndex) ?? rest.endIndex
                    chunks.append(String(rest[..<end]))
                    rest = rest[end...]
                }
            } else if current.isEmpty {
                current = block
            } else if current.count + 2 + block.count <= limit {
                current += "\n\n" + block
            } else {
                flush()
                current = block
            }
        }
        flush()
        return chunks
    }
}
