import Foundation
import Testing
@testable import AnkiLearnCore

let fixtureID = "11111111-2222-3333-4444-555555555555"

/// 测试用的 ~/.claude/projects：临时文件夹里放一个项目文件夹，里面是会话记录
func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ankilearn-\(UUID().uuidString)")
    let project = root.appendingPathComponent("-Users-me-Projects-demo")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let fixture = Bundle.module.url(forResource: "Fixtures/\(fixtureID)", withExtension: "jsonl")!
    try FileManager.default.copyItem(at: fixture, to: project.appendingPathComponent("\(fixtureID).jsonl"))
    return root
}

@Suite struct SessionTests {
    @Test func readsOnlyTheConversation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("-Users-me-Projects-demo/\(fixtureID).jsonl")
        let turns = try ClaudeSessions.readTurns(from: url)
        #expect(turns.map(\.role) == [.me, .ai, .me, .ai])
        #expect(turns[0].text == "git rebase 和 merge 有什么区别？")
        // 同一轮的几行 AI 文字并在一起；思考、工具调用、请求记录的副本、子 Agent 都不在
        #expect(turns[1].text == "先看一下仓库。\n\nrebase 把你的提交挪到目标分支最新的提交后面，历史是一条直线；merge 保留两条线，多一个合并提交。")
        #expect(turns[2].text == "那冲突的时候呢？")
        let all = TranscriptText.render(turns)
        for noise in ["别管这段", "想一想", "git log", "commit abc", "副本", "子 Agent", "Caveat", "continued", "Kept model", "/model", "pasted_content"] {
            #expect(!all.contains(noise), "不该出现：\(noise)")
        }
    }

    @Test func listsSessionWithLatestTitleAndLink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = ClaudeSessions.list(root: root)
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == fixtureID)
        #expect(s.title == "git rebase 和 merge")
        #expect(s.project == "demo")
        #expect(s.remoteID == "01ABCdefGHI")
        #expect(s.webURL?.absoluteString == "https://claude.ai/code/session_01ABCdefGHI")
        #expect(s.entrypoint == "cli")
    }

    @Test func scriptedSessionsAreNotListed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("-Users-me-Projects-demo/22222222-2222-3333-4444-555555555555.jsonl")
        try """
        {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Generate a short git branch name"},"uuid":"x","entrypoint":"sdk-cli","cwd":"/tmp"}

        """.write(to: script, atomically: true, encoding: .utf8)
        #expect(ClaudeSessions.list(root: root).map(\.id) == [fixtureID])
        // 用编号或链接找还是找得到
        #expect(ClaudeSessions.find(sessionID: "22222222-2222-3333-4444-555555555555", root: root)?.entrypoint == "sdk-cli")
    }

    @Test func findsSessionByLinkAndByID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClaudeSessions.find(remoteID: "01ABCdefGHI", root: root)?.id == fixtureID)
        #expect(ClaudeSessions.find(remoteID: "01ABC", root: root) == nil)
        #expect(ClaudeSessions.find(sessionID: fixtureID, root: root)?.title == "git rebase 和 merge")
        #expect(ClaudeSessions.find(sessionID: "nope", root: root) == nil)
    }

    @Test func findsBridgeIDDeepInFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 会话中途才连上 claude.ai：bridge 那行在 512KB 以后
        let url = root.appendingPathComponent("-Users-me-Projects-demo/\(fixtureID).jsonl")
        var text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "cse_01ABCdefGHI", with: "cse_other")
        text += String(repeating: "{\"type\":\"attachment\",\"pad\":\"\(String(repeating: "x", count: 1000))\"}\n", count: 600)
        text += "{\"type\":\"bridge-session\",\"bridgeSessionId\":\"cse_LATE123\"}\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(ClaudeSessions.find(remoteID: "LATE123", root: root)?.id == fixtureID)
    }
}

@Suite struct ImportTargetTests {
    @Test func recognisesWhatWasPasted() {
        #expect(ImportTarget.parse("  https://claude.ai/code/session_01AbCdEfGhIjKlMnOpQrStUv \n")
                == .claudeLink(remoteID: "01AbCdEfGhIjKlMnOpQrStUv", url: URL(string: "https://claude.ai/code/session_01AbCdEfGhIjKlMnOpQrStUv")!))
        #expect(ImportTarget.parse("ankilearn://session/11111111-2222-3333-4444-555555555555") == .localSession(id: "11111111-2222-3333-4444-555555555555"))
        #expect(ImportTarget.parse("ABCDEF11-2222-3333-4444-55555555555A") == .localSession(id: "abcdef11-2222-3333-4444-55555555555a"))
        #expect(ImportTarget.parse("/tmp/a b.pdf") == .file(URL(fileURLWithPath: "/tmp/a b.pdf")))
        #expect(ImportTarget.parse("https://example.com/post") == .web(URL(string: "https://example.com/post")!))
        #expect(ImportTarget.parse("随便一句话") == nil)
        #expect(ImportTarget.parse("") == nil)
    }
}

@Suite struct ChunkTests {
    @Test func shortConversationIsOneChunk() {
        let turns = [Turn(role: .me, text: "问"), Turn(role: .ai, text: "答")]
        #expect(TranscriptText.chunks(turns, limit: 1000) == ["【我】\n问\n\n【AI】\n答"])
    }

    @Test func splitsBetweenTurnsAndHardSplitsHugeTurns() {
        let turns = [
            Turn(role: .me, text: String(repeating: "a", count: 40)),
            Turn(role: .ai, text: String(repeating: "b", count: 40)),
            Turn(role: .me, text: String(repeating: "c", count: 250)),
        ]
        let chunks = TranscriptText.chunks(turns, limit: 100)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks[0] == "【我】\n" + String(repeating: "a", count: 40) + "\n\n【AI】\n" + String(repeating: "b", count: 40))
        #expect(chunks.joined() .filter { $0 == "c" }.count == 250)
    }

    @Test func plainTextSplitsAtParagraphs() {
        let text = (1...10).map { "第\($0)段" + String(repeating: "字", count: 30) }.joined(separator: "\n\n")
        let chunks = TranscriptText.chunks(plain: text, limit: 80)
        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 80 && $0.hasPrefix("第") })
    }
}

@Suite struct CardParsingTests {
    @Test func toleratesMissingFieldsAndBadCards() throws {
        let json = """
        {"cards":[
          {"q":"rebase 冲突后怎么继续？","a":"`git rebase --continue`","tags":["git"]},
          {"q":"","a":"没有问题的卡不要"},
          {"a":"缺问题"},
          {"q":"merge 和 rebase 的历史有什么不同？","a":"rebase 是直线","more":"merge 多一个合并提交","quote":"历史是一条直线"}
        ]}
        """
        let cards = try CardMaker.parse(json)
        #expect(cards.map(\.q) == ["rebase 冲突后怎么继续？", "merge 和 rebase 的历史有什么不同？"])
        #expect(cards[0].more == "" && cards[0].quote == "")
        #expect(cards[1].more == "merge 多一个合并提交")
    }

    @Test func rejectsNonJSON() {
        #expect(throws: DeepSeekError.badResponse) { try CardMaker.parse("好的，下面是卡片") }
    }

    @Test func dedupesSameQuestion() {
        let cards = [CardDraft(q: "什么是 rebase？", a: "1"), CardDraft(q: "什么是 Rebase", a: "2"), CardDraft(q: "什么是 merge？", a: "3")]
        #expect(CardMaker.dedupe(cards).map(\.a) == ["1", "3"])
    }

    @Test func pointsForAnki() {
        #expect(AnkiHTML.points("只有一条 `x`") == "只有一条 <code>x</code>")
        #expect(AnkiHTML.points("- 第一条\n\n• 第二条 <b>") == "<ul class=\"pts\"><li>第一条</li><li>第二条 &lt;b&gt;</li></ul>")
        #expect(AnkiHTML.points("") == "")
    }

    @Test func noteTypeIsVersioned() {
        #expect(AnkiNoteType.css.hasPrefix("/* \(AnkiNoteType.version)"))
        #expect(!AnkiNoteType.back.contains("id=\"answer\""))
        for field in AnkiNoteType.fieldNames where field != "原文" && field != "补充" {
            #expect(AnkiNoteType.back.contains("{{\(field)}}"))
        }
    }

    @Test func htmlForAnki() {
        #expect(AnkiHTML.from("用 `a<b>` 和 **重点**\n第二行") == "用 <code>a&lt;b&gt;</code> 和 <b>重点</b><br>第二行")
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ankilearn-store-\(UUID().uuidString)/sources.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var source = Source(kind: .claudeSession, title: "会话", origin: fixtureID, link: "https://claude.ai/code/session_x")
        source.cards = [Card(CardDraft(q: "问", a: "答"))]
        source.usage = Usage(input: 10, output: 5)
        let store = SourceStore(url: url)
        try store.save([source])
        #expect(try store.load() == [source])
    }
}
