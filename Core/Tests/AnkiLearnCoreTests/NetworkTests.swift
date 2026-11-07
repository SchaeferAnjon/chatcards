import Foundation
import Testing
@testable import AnkiLearnCore

/// 假服务器：每个请求交给 handler，回它给的状态码和内容；收到的请求体都记下来
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (([String: Any]) -> (Int, Any)) = { _ in (500, [:]) }
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.bodies.append(body)
        let (status, reply) = Self.handler(body)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func deepSeekReply(_ content: String) -> [String: Any] {
    ["choices": [["message": ["role": "assistant", "content": content]]], "usage": ["prompt_tokens": 100, "completion_tokens": 20]]
}

@Suite(.serialized) struct NetworkTests {
    let client = DeepSeek(key: "sk-test", model: "deepseek-flash", thinking: true, session: StubProtocol.session())

    @Test func deepSeekRequestAndCards() async throws {
        StubProtocol.bodies = []
        StubProtocol.handler = { _ in (200, deepSeekReply("{\"cards\":[{\"q\":\"问\",\"a\":\"答\"}]}")) }
        let (cards, usage) = try await CardMaker.make(chunks: ["【我】\n问"], material: .claudeSession, client: client)
        #expect(cards.map(\.q) == ["问"])
        #expect(usage == Usage(input: 100, output: 20))
        let body = try #require(StubProtocol.bodies.first)
        #expect(body["model"] as? String == "deepseek-flash")
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        #expect((body["thinking"] as? [String: String])?["type"] == "enabled")
        let messages = try #require(body["messages"] as? [[String: String]])
        // JSON 模式要求提示词里有 json 这个词
        #expect(messages[0]["content"]?.lowercased().contains("json") == true)
        #expect(messages[1]["content"]?.contains("Claude Code") == true)
    }

    @Test func blankAnswerIsRetriedOnce() async throws {
        StubProtocol.bodies = []
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            return (200, deepSeekReply(calls == 1 ? "   " : "{\"cards\":[]}"))
        }
        let (cards, _) = try await CardMaker.make(chunks: ["x"], material: .document(title: "t"), client: client)
        #expect(cards.isEmpty)
        #expect(StubProtocol.bodies.count == 2)
    }

    @Test func chunksComeBackInOrder() async throws {
        StubProtocol.handler = { body in
            let text = ((body["messages"] as? [[String: String]])?[1]["content"]) ?? ""
            let n = text.contains("第 1 段") ? 1 : text.contains("第 2 段") ? 2 : 3
            return (200, deepSeekReply("{\"cards\":[{\"q\":\"第\(n)段的问题\",\"a\":\"a\"}]}"))
        }
        let (cards, usage) = try await CardMaker.make(chunks: ["a", "b", "c"], material: .claudeSession, client: client)
        #expect(cards.map(\.q) == ["第1段的问题", "第2段的问题", "第3段的问题"])
        #expect(usage.input == 300)
    }

    @Test func deepSeekErrorsAreReadable() async throws {
        StubProtocol.handler = { _ in (401, ["error": ["message": "Authentication Fails"]]) }
        await #expect(throws: DeepSeekError.badKey) { _ = try await client.json(system: "json", user: "x") }
        StubProtocol.handler = { _ in (402, ["error": ["message": "Insufficient Balance"]]) }
        await #expect(throws: DeepSeekError.noBalance) { _ = try await client.json(system: "json", user: "x") }
        let noKey = DeepSeek(key: "", model: "deepseek-flash", thinking: true, session: StubProtocol.session())
        await #expect(throws: DeepSeekError.noKey) { _ = try await noKey.json(system: "json", user: "x") }
    }

    @Test func ankiAddsNewSkipsDuplicates() async throws {
        StubProtocol.bodies = []
        StubProtocol.handler = { body in
            switch body["action"] as? String {
            case "version": return (200, ["result": 6, "error": NSNull()])
            case "createDeck": return (200, ["result": 1, "error": NSNull()])
            case "modelNames": return (200, ["result": ["Basic"], "error": NSNull()])
            case "createModel": return (200, ["result": [:], "error": NSNull()])
            case "canAddNotesWithErrorDetail":
                return (200, ["result": [["canAdd": true], ["canAdd": false, "error": "cannot create note because it is a duplicate"], ["canAdd": true]], "error": NSNull()])
            case "addNotes": return (200, ["result": [111, NSNull()], "error": NSNull()])
            default: return (200, ["result": NSNull(), "error": "unknown action"])
            }
        }
        var source = Source(kind: .claudeSession, title: "会话 <1>", origin: "x", link: "https://claude.ai/code/session_x")
        source.cards = [Card(CardDraft(q: "新的", a: "`a`", tags: ["git tips"])), Card(CardDraft(q: "有了", a: "b")), Card(CardDraft(q: "坏的", a: "c"))]
        let anki = AnkiConnect(session: StubProtocol.session())
        let result = try await anki.add(source.cards, from: source, deck: "Anki Learn::Claude Code")
        #expect(result.added == [source.cards[0].id])
        #expect(result.duplicates == [source.cards[1].id])
        #expect(result.failed.keys.contains(source.cards[2].id))

        let actions = StubProtocol.bodies.compactMap { $0["action"] as? String }
        #expect(actions == ["version", "createDeck", "modelNames", "createModel", "canAddNotesWithErrorDetail", "addNotes"])
        let added = try #require(StubProtocol.bodies.last?["params"] as? [String: Any])
        let notes = try #require(added["notes"] as? [[String: Any]])
        #expect(notes.count == 2)
        let fields = try #require(notes[0]["fields"] as? [String: String])
        #expect(fields["问题"] == "新的")
        #expect(fields["答案"] == "<code>a</code>")
        #expect(fields["来源"]?.contains("会话 &lt;1&gt;") == true)
        #expect(fields["来源"]?.range(of: #"<span class="src-date">\d{4}-\d{2}-\d{2}</span>"#, options: .regularExpression) != nil)
        #expect(fields["来源"]?.contains(#"<a class="src-link" href="https://claude.ai/code/session_x">打开原文</a>"#) == true)
        #expect(notes[0]["tags"] as? [String] == ["anki-learn", "git_tips"])
        #expect(notes[0]["deckName"] as? String == "Anki Learn::Claude Code")
    }

    @Test func ankiUpgradesOldNoteTypeOnce() async throws {
        for (css, expectUpdate) in [("/* old */ .card {}", true), (AnkiNoteType.css, false)] {
            StubProtocol.bodies = []
            StubProtocol.handler = { body in
                switch body["action"] as? String {
                case "version": return (200, ["result": 6, "error": NSNull()])
                case "createDeck": return (200, ["result": 1, "error": NSNull()])
                case "modelNames": return (200, ["result": [AnkiNoteType.name], "error": NSNull()])
                case "modelStyling": return (200, ["result": ["css": css], "error": NSNull()])
                case "updateModelStyling", "updateModelTemplates": return (200, ["result": NSNull(), "error": NSNull()])
                case "canAddNotesWithErrorDetail": return (200, ["result": [["canAdd": true]], "error": NSNull()])
                case "addNotes": return (200, ["result": [1], "error": NSNull()])
                default: return (200, ["result": NSNull(), "error": "unknown action"])
                }
            }
            let source = Source(kind: .document, title: "笔记.pdf", origin: "/tmp/笔记.pdf")
            _ = try await AnkiConnect(session: StubProtocol.session()).add([Card(CardDraft(q: "q", a: "a"))], from: source, deck: "d")
            let actions = StubProtocol.bodies.compactMap { $0["action"] as? String }
            #expect(actions.contains("createModel") == false)
            #expect(actions.contains("updateModelStyling") == expectUpdate)
            #expect(actions.contains("updateModelTemplates") == expectUpdate)
            if expectUpdate {
                let t = try #require(StubProtocol.bodies.first { $0["action"] as? String == "updateModelTemplates" }?["params"] as? [String: Any])
                let templates = try #require((t["model"] as? [String: Any])?["templates"] as? [String: [String: String]])
                #expect(templates["问答"]?["Back"]?.contains("原话") == true)
            }
            // 没有链接的文档：来源里没有「打开原文」
            let added = try #require(StubProtocol.bodies.last?["params"] as? [String: Any])
            let fields = try #require((added["notes"] as? [[String: Any]])?.first?["fields"] as? [String: String])
            #expect(fields["来源"]?.contains("src-link") == false)
        }
    }

    @Test func ankiNotRunning() async {
        let anki = AnkiConnect(url: URL(string: "http://127.0.0.1:1")!)
        await #expect(throws: AnkiError.notRunning) { _ = try await anki.version() }
    }
}
