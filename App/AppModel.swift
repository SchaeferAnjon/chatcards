import AppKit
import AnkiLearnCore
import SwiftUI

/// 设置里的几项（UserDefaults）
enum Prefs {
    static let modelKey = "model"
    static let thinkingKey = "thinking"
    static let deckKey = "deckRoot"

    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "deepseek-flash" }
    static var thinking: Bool { UserDefaults.standard.object(forKey: thinkingKey) as? Bool ?? true }
    static var deckRoot: String {
        let s = UserDefaults.standard.string(forKey: deckKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? "Anki Learn" : s
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Page: Hashable {
        case home
        case source(UUID)
    }

    /// 一份材料正在做什么
    enum Job: Equatable {
        case reading
        case asking(done: Int, total: Int, started: Date)
        case failed(String, needsKey: Bool)
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var ok: Bool
        var title: String
        var detail: String?
        /// Anki 没开时带一个「打开 Anki 再送」
        var retrySend: UUID?
    }

    struct WebImport: Identifiable {
        let id = UUID()
        var url: URL
        var note: String
    }

    @Published var page: Page = .home
    @Published var sources: [Source] = []
    @Published var sessions: [SessionInfo] = []
    @Published var loadingSessions = false
    @Published var jobs: [UUID: Job] = [:]
    @Published var sending: Set<UUID> = []
    @Published var toast: Toast?
    @Published var webImport: WebImport?

    private let store = SourceStore(url: SourceStore.defaultURL)
    private var toastTask: Task<Void, Never>?

    init() {
        do {
            sources = try store.load()
        } catch {
            show(Toast(ok: false, title: "读不了以前做的卡片", detail: error.localizedDescription))
        }
        refreshSessions()
    }

    func source(_ id: UUID) -> Source? { sources.first { $0.id == id } }

    func binding(_ id: UUID) -> Binding<Source>? {
        guard sources.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.source(id) ?? Source(kind: .document, title: "", origin: "") },
            set: { new in
                guard let i = self.sources.firstIndex(where: { $0.id == id }) else { return }
                self.sources[i] = new
                self.save()
            })
    }

    func refreshSessions() {
        loadingSessions = true
        Task.detached(priority: .userInitiated) {
            let list = ClaudeSessions.list()
            await MainActor.run {
                self.sessions = list
                self.loadingSessions = false
            }
        }
    }

    func save() {
        do {
            try store.save(sources)
        } catch {
            show(Toast(ok: false, title: "卡片没存上", detail: error.localizedDescription))
        }
    }

    // MARK: - 拿进来

    /// 粘贴的、/anki 送来的、菜单「从剪贴板导入」的，都走这里
    func importText(_ text: String) {
        switch ImportTarget.parse(text) {
        case .claudeLink(let remoteID, let url):
            if let info = ClaudeSessions.find(remoteID: remoteID) {
                importSession(info)
            } else {
                webImport = WebImport(url: url, note: "这个会话不在这台 Mac 上，在网页里打开它（第一次要登录 claude.ai），对话出来以后点「用这页做卡片」。")
            }
        case .localSession(let id):
            if let info = ClaudeSessions.find(sessionID: id) {
                importSession(info)
            } else {
                show(Toast(ok: false, title: "这台 Mac 上找不到这个会话", detail: id))
            }
        case .file(let url):
            importFile(url)
        case .web(let url):
            webImport = WebImport(url: url, note: "网页打开以后点「用这页做卡片」。要登录的网站先在这里登录。")
        case nil:
            show(Toast(ok: false, title: "认不出这是什么", detail: "粘贴 claude.ai/code 的会话链接、文件路径或网址"))
        }
    }

    func importSession(_ info: SessionInfo) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = sources.first(where: { $0.kind == .claudeSession && $0.origin == info.id }) {
            page = .source(existing.id)
            // 上次没做成就接着做；做成了的不自动重做（会换掉还没送进 Anki 的卡），页面上提示会话有新内容
            if existing.generatedAt == nil { generate(existing.id) }
            refreshSessions()
            return
        }
        add(Source(kind: .claudeSession, title: info.title, origin: info.id, link: info.webURL?.absoluteString))
    }

    func importFile(_ url: URL) {
        if url.pathExtension == "jsonl" {
            let id = url.deletingPathExtension().lastPathComponent
            if let info = ClaudeSessions.find(sessionID: id) {
                importSession(info)
            } else {
                add(Source(kind: .claudeSession, title: url.lastPathComponent, origin: url.path))
            }
            return
        }
        if let existing = sources.first(where: { $0.kind == .document && $0.origin == url.path }) {
            page = .source(existing.id)
            return
        }
        add(Source(kind: .document, title: url.deletingPathExtension().lastPathComponent, origin: url.path))
    }

    func importWeb(url: URL, title: String, text: String) {
        webImport = nil
        var source = Source(kind: .web, title: title.isEmpty ? (url.host ?? url.absoluteString) : title, origin: url.absoluteString, link: url.absoluteString)
        source.text = text
        add(source)
    }

    private func add(_ source: Source) {
        sources.insert(source, at: 0)
        page = .source(source.id)
        save()
        generate(source.id)
    }

    func delete(_ id: UUID) {
        sources.removeAll { $0.id == id }
        jobs[id] = nil
        if page == .source(id) { page = .home }
        save()
    }

    // MARK: - 出卡片

    func generate(_ id: UUID) {
        guard let source = source(id), jobs[id] == nil || isFailed(id) else { return }
        let key = Keychain.read()
        guard !key.isEmpty else {
            jobs[id] = .failed(DeepSeekError.noKey.localizedDescription, needsKey: true)
            return
        }
        jobs[id] = .reading
        let model = Prefs.model
        let client = DeepSeek(key: key, model: model, thinking: Prefs.thinking)
        Task {
            do {
                let (chunks, material) = try await Task.detached(priority: .userInitiated) { try Self.read(source) }.value
                jobs[id] = .asking(done: 0, total: chunks.count, started: Date())
                let (drafts, usage) = try await CardMaker.make(chunks: chunks, material: material, client: client) { done in
                    Task { @MainActor in
                        if case .asking(_, let total, let started) = self.jobs[id] { self.jobs[id] = .asking(done: done, total: total, started: started) }
                    }
                }
                guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
                // 已经进了 Anki 的留着；新出的卡里问题一样的不要
                let kept = sources[i].cards.filter(\.inAnki)
                let keys = Set(kept.map { CardMaker.key($0.q) })
                sources[i].cards = kept + drafts.filter { !keys.contains(CardMaker.key($0.q)) }.map(Card.init)
                sources[i].generatedAt = Date()
                sources[i].model = model
                sources[i].usage = (sources[i].usage ?? Usage()) + usage
                jobs[id] = nil
                save()
            } catch {
                jobs[id] = .failed(error.localizedDescription, needsKey: (error as? DeepSeekError) == .badKey)
            }
        }
    }

    private func isFailed(_ id: UUID) -> Bool {
        if case .failed = jobs[id] { return true }
        return false
    }

    nonisolated static func read(_ source: Source) throws -> ([String], MaterialKind) {
        switch source.kind {
        case .claudeSession:
            let url: URL
            if source.origin.hasPrefix("/") {
                url = URL(fileURLWithPath: source.origin)
            } else if let info = ClaudeSessions.find(sessionID: source.origin) {
                url = info.fileURL
            } else {
                throw SessionReadError.unreadable(ClaudeSessions.defaultRoot.appendingPathComponent(source.origin + ".jsonl"))
            }
            let turns = try ClaudeSessions.readTurns(from: url)
            return (TranscriptText.chunks(turns, limit: CardMaker.chunkLimit), .claudeSession)
        case .document:
            let text = try DocumentText.read(URL(fileURLWithPath: source.origin))
            return (TranscriptText.chunks(plain: text, limit: CardMaker.chunkLimit), .document(title: source.title))
        case .web:
            let text = source.text ?? ""
            return (TranscriptText.chunks(plain: text, limit: CardMaker.chunkLimit), .document(title: source.title))
        }
    }

    // MARK: - 送进 Anki

    func deck(for source: Source) -> String {
        switch source.kind {
        case .claudeSession: return "\(Prefs.deckRoot)::Claude Code"
        case .document: return "\(Prefs.deckRoot)::文档"
        case .web: return "\(Prefs.deckRoot)::网页"
        }
    }

    func send(_ id: UUID) {
        guard let source = source(id), !sending.contains(id) else { return }
        let cards = source.cards.filter { $0.selected && !$0.inAnki }
        guard !cards.isEmpty else { return }
        sending.insert(id)
        let deck = deck(for: source)
        Task {
            defer { sending.remove(id) }
            do {
                let result = try await AnkiConnect().add(cards, from: source, deck: deck)
                guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
                let done = Set(result.added + result.duplicates)
                for j in sources[i].cards.indices where done.contains(sources[i].cards[j].id) {
                    sources[i].cards[j].inAnki = true
                }
                save()
                var parts: [String] = []
                if !result.duplicates.isEmpty { parts.append("\(result.duplicates.count) 张 Anki 里已经有了，跳过") }
                if !result.failed.isEmpty { parts.append("\(result.failed.count) 张没加进去：\(result.failed.values.first ?? "")") }
                show(Toast(ok: result.failed.isEmpty, title: "加了 \(result.added.count) 张到「\(deck)」", detail: parts.isEmpty ? nil : parts.joined(separator: "；")))
            } catch AnkiError.notRunning {
                show(Toast(ok: false, title: "Anki 没开着，卡片还没送进去", detail: "要先打开 Anki（装了 AnkiConnect 插件）", retrySend: id))
            } catch {
                show(Toast(ok: false, title: "没送进 Anki", detail: error.localizedDescription))
            }
        }
    }

    /// 打开 Anki，等 AnkiConnect 能连上（最多 30 秒）再送
    func openAnkiThenSend(_ id: UUID) {
        toast = nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.ankiweb.anki") else {
            show(Toast(ok: false, title: "这台 Mac 上没找到 Anki", detail: "去 apps.ankiweb.net 下载"))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        sending.insert(id)
        Task {
            let anki = AnkiConnect()
            for _ in 0..<30 {
                if (try? await anki.version()) != nil {
                    sending.remove(id)
                    send(id)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            sending.remove(id)
            show(Toast(ok: false, title: "Anki 开了，但连不上 AnkiConnect", detail: "在 Anki 的「工具 › 附加组件」里看看 AnkiConnect 装了没有"))
        }
    }

    func browseInAnki(_ id: UUID) {
        guard let source = source(id) else { return }
        let deck = deck(for: source)
        Task {
            do {
                try await AnkiConnect().browse(deck: deck)
            } catch {
                show(Toast(ok: false, title: "打不开 Anki 的卡片浏览器", detail: error.localizedDescription))
            }
        }
    }

    // MARK: - 提示条

    func show(_ t: Toast) {
        toast = t
        toastTask?.cancel()
        let id = t.id
        toastTask = Task {
            try? await Task.sleep(for: .seconds(t.retrySend == nil ? (t.ok ? 5 : 6) : 15))
            if !Task.isCancelled, toast?.id == id { toast = nil }
        }
    }
}
