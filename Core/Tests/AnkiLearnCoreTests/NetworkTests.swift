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

    /// 假 Anki：笔记类型按 models 回答，记下建了什么、换了什么
    func fakeAnki(models: [String: (fields: [String], css: String)], decks: [String: Int] = [:],
                  canAdd: [[String: Any]] = [["canAdd": true]], added: [Any] = [1]) {
        StubProtocol.bodies = []
        StubProtocol.handler = { body in
            let params = body["params"] as? [String: Any] ?? [:]
            switch body["action"] as? String {
            case "version": return (200, ["result": 6, "error": NSNull()])
            case "deckNamesAndIds": return (200, ["result": decks, "error": NSNull()])
            case "createDeck": return (200, ["result": 99, "error": NSNull()])
            case "modelNames": return (200, ["result": Array(models.keys), "error": NSNull()])
            case "modelFieldNames": return (200, ["result": models[params["modelName"] as? String ?? ""]?.fields ?? [], "error": NSNull()])
            case "modelStyling": return (200, ["result": ["css": models[params["modelName"] as? String ?? ""]?.css ?? ""], "error": NSNull()])
            case "createModel", "updateModelStyling", "updateModelTemplates": return (200, ["result": NSNull(), "error": NSNull()])
            case "canAddNotesWithErrorDetail": return (200, ["result": canAdd, "error": NSNull()])
            case "addNotes": return (200, ["result": added, "error": NSNull()])
            default: return (200, ["result": NSNull(), "error": "unknown action"])
            }
        }
    }

    var actions: [String] { StubProtocol.bodies.compactMap { $0["action"] as? String } }
    func params(_ action: String) -> [String: Any]? {
        StubProtocol.bodies.last { $0["action"] as? String == action }?["params"] as? [String: Any]
    }

    @Test func ankiAddsNewSkipsDuplicates() async throws {
        fakeAnki(models: ["Basic": (["Front", "Back"], "")],
                 canAdd: [["canAdd": true], ["canAdd": false, "error": "cannot create note because it is a duplicate"], ["canAdd": true]],
                 added: [111, NSNull()])
        var source = Source(kind: .claudeSession, title: "会话 <1>", origin: "x", link: "https://claude.ai/code/session_x")
        source.cards = [Card(CardDraft(q: "新的", a: "`a`", tags: ["git tips"])), Card(CardDraft(q: "有了", a: "b")), Card(CardDraft(q: "坏的", a: "c"))]
        let anki = AnkiConnect(session: StubProtocol.session())
        let result = try await anki.add(source.cards, from: source, deck: "知识")
        #expect(result.added == [source.cards[0].id])
        #expect(result.duplicates == [source.cards[1].id])
        #expect(result.failed.keys.contains(source.cards[2].id))

        #expect(actions == ["version", "modelNames", "createModel", "canAddNotesWithErrorDetail", "addNotes"])
        let model = try #require(params("createModel"))
        #expect(model["modelName"] as? String == "学习卡 · 问答")
        #expect(model["inOrderFields"] as? [String] == StudyCard.fields)
        #expect((model["css"] as? String)?.hasPrefix("/* 卡片家族 v3 */") == true)
        let notes = try #require(params("addNotes")?["notes"] as? [[String: Any]])
        #expect(notes.count == 2)
        let fields = try #require(notes[0]["fields"] as? [String: String])
        #expect(fields["Question"] == "新的")
        #expect(fields["Answer"] == "<code>a</code>")
        #expect(fields["Label"] == "ChatCards · Claude Code")
        #expect(fields["Link"] == "https://claude.ai/code/session_x")
        #expect(notes[0]["tags"] as? [String] == ["来自::ChatCards", "主题::git_tips"])
        #expect(notes[0]["deckName"] as? String == "知识")
        #expect(notes[0]["modelName"] as? String == "学习卡 · 问答")
    }

    /// 只往新的换：Anki 里的旧了才换；比我们新（别的软件先更新了）不动；第一行不是版本号说明你改过，先问
    @Test func ankiRestylesOnlyOlderVersions() async throws {
        let ours = StudyCard.fields
        let cases: [(css: String, choice: CustomizedStyle, restyle: Bool, asks: Bool)] = [
            ("/* 卡片家族 v2 */\n.card {}", .ask, true, false),
            (StudyCard.css, .ask, false, false),
            ("/* 卡片家族 v4 */\n.card {}", .ask, false, false),
            (".card { color: hotpink }", .ask, false, true),
            (".card { color: hotpink }", .keep, false, false),
            (".card { color: hotpink }", .replace, true, false),
        ]
        for c in cases {
            fakeAnki(models: ["学习卡 · 问答": (ours, c.css)])
            let anki = AnkiConnect(session: StubProtocol.session())
            let source = Source(kind: .document, title: "笔记.pdf", origin: "/tmp/笔记.pdf")
            if c.asks {
                await #expect(throws: AnkiError.customizedStyle(model: "学习卡 · 问答")) {
                    _ = try await anki.add([Card(CardDraft(q: "q", a: "a"))], from: source, deck: "知识", customized: c.choice)
                }
                #expect(!actions.contains("addNotes"))
            } else {
                _ = try await anki.add([Card(CardDraft(q: "q", a: "a"))], from: source, deck: "知识", customized: c.choice)
                #expect(actions.contains("addNotes"))
            }
            #expect(!actions.contains("createModel"))
            #expect(actions.contains("updateModelStyling") == c.restyle, "css: \(c.css.prefix(20)) choice: \(c.choice)")
            #expect(actions.contains("updateModelTemplates") == c.restyle)
            if c.restyle {
                let templates = try #require((params("updateModelTemplates")?["model"] as? [String: Any])?["templates"] as? [String: [String: String]])
                #expect(templates["问答"]?["Back"] == StudyCard.back)
            }
        }
    }

    /// 你自己有个同名的笔记类型（字段对不上）：不碰它，建「学习卡 · 问答 2」
    @Test func ankiLeavesSomeoneElsesNoteTypeAlone() async throws {
        fakeAnki(models: ["学习卡 · 问答": (["正面", "背面"], ".card {}")])
        let source = Source(kind: .web, title: "网页", origin: "https://example.com", link: "https://example.com")
        _ = try await AnkiConnect(session: StubProtocol.session()).add([Card(CardDraft(q: "q", a: "a"))], from: source, deck: "知识")
        #expect(params("createModel")?["modelName"] as? String == "学习卡 · 问答 2")
        #expect(!actions.contains("updateModelStyling"))
        let notes = try #require(params("addNotes")?["notes"] as? [[String: Any]])
        #expect(notes[0]["modelName"] as? String == "学习卡 · 问答 2")
    }

    /// 牌组按 id 记：Anki 里改了名跟着走；删了就按名字重建
    @Test func deckFollowsRenameById() async throws {
        let anki = AnkiConnect(session: StubProtocol.session())
        fakeAnki(models: [:], decks: ["Default": 1, "我的知识": 42])
        var deck = try await anki.deck(id: 42, orCreate: "知识")
        #expect(deck.name == "我的知识" && deck.id == 42)
        #expect(!actions.contains("createDeck"))

        fakeAnki(models: [:], decks: ["Default": 1, "知识": 7])
        deck = try await anki.deck(id: 42, orCreate: "知识")
        #expect(deck.name == "知识" && deck.id == 7)
        #expect(!actions.contains("createDeck"))

        fakeAnki(models: [:], decks: ["Default": 1])
        deck = try await anki.deck(id: nil, orCreate: "知识")
        #expect(deck.name == "知识" && deck.id == 99)
        #expect(params("createDeck")?["deck"] as? String == "知识")
    }

    @Test func ankiEditorOpenIsReadable() async {
        StubProtocol.handler = { _ in (200, ["result": NSNull(), "error": "Close the affected editor before this API write, even if its content is saved."]) }
        await #expect(throws: AnkiError.api("Anki 里开着卡片浏览器或「添加」窗口，Anki 不让这时改笔记类型；关掉它再送")) {
            _ = try await AnkiConnect(session: StubProtocol.session()).version()
        }
    }

    @Test func ankiNotRunning() async {
        let anki = AnkiConnect(url: URL(string: "http://127.0.0.1:1")!)
        await #expect(throws: AnkiError.notRunning) { _ = try await anki.version() }
    }
}
