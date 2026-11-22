import AppKit
import ChatCardsCore
import SwiftUI

/// 设置里的几项（UserDefaults）
enum Prefs {
    static let modelKey = "model"
    static let thinkingKey = "thinking"
    /// 卡片默认进的牌组；建好以后按 id 记，你在 Anki 里改名也跟得上
    static let deckKey = "ankiDeck"
    static let deckIDKey = "ankiDeckID"
    /// 你在 Anki 里改过「学习卡 · 问答」的模板时选的：replace 换成新样子，keep 留着你改的
    static let styleKey = "ankiCustomizedStyle"
    static let defaultDeck = "知识"

    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "deepseek-flash" }
    static var thinking: Bool { UserDefaults.standard.object(forKey: thinkingKey) as? Bool ?? true }
    static var deckName: String {
        let s = UserDefaults.standard.string(forKey: deckKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? defaultDeck : s
    }
    static var deckID: Int? {
        get { UserDefaults.standard.object(forKey: deckIDKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: deckIDKey) }
    }
    /// 你在 Anki 里改了默认牌组的名字：设置里也跟着写新名字
    static func followRename(_ name: String) {
        if name != deckName { UserDefaults.standard.set(name, forKey: deckKey) }
    }
    /// 设置里改了名字：下次送卡按新名字找或建
    static func setDeck(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard name != deckName else { return }
        UserDefaults.standard.set(name.isEmpty ? nil : name, forKey: deckKey)
        deckID = nil
    }
    static var customizedStyle: CustomizedStyle {
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(CustomizedStyle.init) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
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
        enum Action: Equatable {
            /// Anki 没开：「打开 Anki 再送」
            case openAnkiThenSend(UUID)
            /// 连不上插件：「怎么装」打开连上 Anki 那一块
            case howToInstall
            /// 送好了：「在 Anki 里看」
            case browse(UUID)
        }

        let id = UUID()
        var ok: Bool
        var title: String
        var detail: String?
        var action: Action?
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
    /// 「连上 Anki」那一块（提示条上点「怎么装」）
    @Published var connectShown = false
    /// 你在 Anki 里改过模板：问换不换，答了再送这份材料
    @Published var styleQuestion: UUID?
    /// 默认牌组现在在 Anki 里叫什么，和底栏菜单里能选的（默认的和它下面你自己建的）
    @Published var topDeck = Prefs.deckName
    @Published var deckChoices: [String] = [Prefs.deckName]
    /// 底栏菜单里选的；nil 就是默认牌组
    @Published var chosenDeck: String?

    private let store = SourceStore(url: SourceStore.defaultURL)
    private var toastTask: Task<Void, Never>?

    init() {
        let moved = Self.migrateFromAnkiLearn()
        do {
            sources = try store.load()
        } catch {
            show(Toast(ok: false, title: "读不了以前做的卡片", detail: error.localizedDescription))
        }
        switch moved {
        case .success(let report) where !report.isEmpty:
            var parts: [String] = []
            if report.sources > 0 { parts.append("\(report.sources) 份做过的材料") }
            if report.key { parts.append("DeepSeek Key") }
            if !report.settings.isEmpty { parts.append("设置") }
            show(Toast(ok: true, title: "从 Anki Learn 搬过来了", detail: parts.joined(separator: "、") + "都在。Anki Learn 那边的没删。"))
        case .failure(let error):
            show(Toast(ok: false, title: "没能从 Anki Learn 搬来做过的卡片", detail: "下次打开再试。\(error.localizedDescription)"))
        default:
            break
        }
        refreshSessions()
    }

    /// 以前叫 Anki Learn：第一次启动把旧版的卡片、设置和 Key 搬过来，只复制不删（见 LegacyMigration）。
    /// 测试模式下只在给了 E2E_LEGACY_SUPPORT 时搬，旧数据从测试给的地方读，不碰钥匙串（读别的程序存的条目系统会弹窗）：
    /// E2E_LEGACY_SUPPORT（放 sources.json 的文件夹）、E2E_LEGACY_DEFAULTS（defaults 的名字，可以是 plist 的绝对路径）、E2E_LEGACY_KEY（旧版的 Key）
    private static func migrateFromAnkiLearn() -> Result<LegacyMigration.Report, Error> {
        let env = ProcessInfo.processInfo.environment
        let oldSupport: URL, oldDefaults: UserDefaults?, oldKey: () -> String
        if E2EMode.isOn {
            guard let dir = env["E2E_LEGACY_SUPPORT"], !dir.isEmpty else { return .success(.init()) }
            oldSupport = URL(fileURLWithPath: dir, isDirectory: true)
            oldDefaults = env["E2E_LEGACY_DEFAULTS"].flatMap { UserDefaults(suiteName: $0) }
            oldKey = { env["E2E_LEGACY_KEY"] ?? "" }
        } else {
            oldSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(LegacyMigration.oldFolderName, isDirectory: true)
            oldDefaults = UserDefaults(suiteName: LegacyMigration.oldBundleID)
            oldKey = { KeychainItem(service: LegacyMigration.oldBundleID, account: LegacyMigration.keyAccount).read() }
        }
        return Result {
            try LegacyMigration.run(
                oldSupport: oldSupport, newSupport: SourceStore.defaultURL.deletingLastPathComponent(),
                oldDefaults: oldDefaults, newDefaults: .standard,
                oldKey: oldKey, currentKey: Keychain.read, saveKey: Keychain.save)
        }
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
                webImport = WebImport(url: url, note: "这个会话不在这台 Mac 上，在网页里打开它。第一次要登录 claude.ai：用邮箱或 Apple 登录，Google 登录在这里会被 Google 拦下。对话出来以后点「用这页做卡片」。")
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
            webImport = WebImport(url: url, note: "网页打开以后点「用这页做卡片」。要登录的网站先在这里登录（Google 账号登录在这里会被 Google 拦下，用邮箱或别的方式）。")
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

    var deckForSending: String { chosenDeck ?? topDeck }

    /// 读 Anki 里的牌组：默认的那个按 id 找现在的名字，再列出它下面你自己建的
    func refreshDecks() {
        Task {
            do {
                let decks = try await AnkiConnect().deckNamesAndIds()
                let top = Prefs.deckID.flatMap { id in decks.first { $0.value == id }?.key } ?? Prefs.deckName
                Prefs.followRename(top)
                topDeck = top
                deckChoices = [top] + decks.keys.filter { $0.hasPrefix(top + "::") }.sorted()
                if let chosen = chosenDeck, !deckChoices.contains(chosen) { chosenDeck = nil }
            } catch AnkiError.notRunning {
                // Anki 没开：菜单里只有默认的，送的时候再说
            } catch {
                show(Toast(ok: false, title: "读不到 Anki 里的牌组", detail: error.localizedDescription))
            }
        }
    }

    func send(_ id: UUID) {
        guard let source = source(id), !sending.contains(id) else { return }
        let cards = source.cards.filter { $0.selected && !$0.inAnki }
        guard !cards.isEmpty else { return }
        sending.insert(id)
        let chosen = chosenDeck
        Task {
            defer { sending.remove(id) }
            let anki = AnkiConnect()
            do {
                _ = try await anki.version()
                let deck: String
                if let chosen {
                    deck = chosen
                } else {
                    let top = try await anki.deck(id: Prefs.deckID, orCreate: Prefs.deckName)
                    Prefs.deckID = top.id
                    Prefs.followRename(top.name)
                    topDeck = top.name
                    deck = top.name
                }
                let result = try await anki.add(cards, from: source, deck: deck, customized: Prefs.customizedStyle)
                guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
                let done = Set(result.added + result.duplicates)
                for j in sources[i].cards.indices where done.contains(sources[i].cards[j].id) {
                    sources[i].cards[j].inAnki = true
                }
                save()
                var parts: [String] = []
                if !result.duplicates.isEmpty { parts.append("\(result.duplicates.count) 张 Anki 里已经有了，跳过") }
                if !result.failed.isEmpty { parts.append("\(result.failed.count) 张没加进去：\(result.failed.values.first ?? "")") }
                if parts.isEmpty { parts.append("来源和主题写进了标签") }
                show(Toast(ok: result.failed.isEmpty, title: "加了 \(result.added.count) 张到「\(deck)」", detail: parts.joined(separator: "；"),
                           action: result.added.isEmpty && result.duplicates.isEmpty ? nil : .browse(id)))
            } catch AnkiError.notRunning {
                if Self.ankiIsRunning {
                    show(Toast(ok: false, title: "Anki 开着，但连不上 AnkiConnect 插件", detail: "装好插件、重启 Anki 再送，勾着的都还在。", action: .howToInstall))
                } else {
                    show(Toast(ok: false, title: "Anki 没开着，卡片还没送进去", detail: "打开 Anki 就能送，勾着的都还在。", action: .openAnkiThenSend(id)))
                }
            } catch AnkiError.customizedStyle {
                styleQuestion = id
            } catch {
                show(Toast(ok: false, title: "没送进 Anki", detail: error.localizedDescription))
            }
        }
    }

    /// 你在 Anki 里改过「学习卡 · 问答」的模板：答了以后记下来，不再问，接着送
    func answerStyleQuestion(replace: Bool) {
        Prefs.customizedStyle = replace ? .replace : .keep
        if let id = styleQuestion {
            styleQuestion = nil
            send(id)
        }
    }

    nonisolated static let ankiBundleID = "net.ankiweb.anki"
    static var ankiIsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: ankiBundleID).isEmpty }

    /// 打开 Anki（不抢到前面）；没装就去下载页
    @discardableResult
    func openAnki() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.ankiBundleID) else {
            show(Toast(ok: false, title: "这台 Mac 上没找到 Anki", detail: "去 apps.ankiweb.net 下载", action: .howToInstall))
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }

    /// 打开 Anki，等 AnkiConnect 能连上（最多 30 秒）再送
    func openAnkiThenSend(_ id: UUID) {
        toast = nil
        guard openAnki() else { return }
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
            show(Toast(ok: false, title: "Anki 开着，但连不上 AnkiConnect 插件", detail: "装好插件、重启 Anki 再送，勾着的都还在。", action: .howToInstall))
        }
    }

    /// 在 Anki 的卡片浏览器里只看这份材料送进去的卡
    func browseInAnki(_ id: UUID) {
        guard let source = source(id) else { return }
        let cards = source.cards.filter(\.inAnki)
        guard !cards.isEmpty else { return }
        Task {
            do {
                try await AnkiConnect().browse(query: AnkiConnect.query(for: cards))
            } catch {
                show(Toast(ok: false, title: "打不开 Anki 的卡片浏览器", detail: error.localizedDescription))
            }
        }
    }

    func perform(_ action: Toast.Action) {
        toast = nil
        switch action {
        case .openAnkiThenSend(let id): openAnkiThenSend(id)
        case .howToInstall: connectShown = true
        case .browse(let id): browseInAnki(id)
        }
    }

    // MARK: - 提示条

    func show(_ t: Toast) {
        toast = t
        toastTask?.cancel()
        let id = t.id
        toastTask = Task {
            try? await Task.sleep(for: .seconds(t.action == nil ? (t.ok ? 5 : 6) : 15))
            if !Task.isCancelled, toast?.id == id { toast = nil }
        }
    }
}
