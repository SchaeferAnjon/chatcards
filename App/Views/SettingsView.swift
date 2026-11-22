import ChatCardsCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AnkiSettings()
                .tabItem { Label("Anki", systemImage: "rectangle.stack") }
        }
        .frame(width: 600)
    }
}

private struct GeneralSettings: View {
    @State private var key = Keychain.read()
    @State private var saved = false
    @AppStorage(Prefs.modelKey) private var model = "deepseek-flash"
    @AppStorage(Prefs.thinkingKey) private var thinking = true

    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField("sk-…", text: $key)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(saveKey)
                    Button(saved ? "存好了" : "保存", action: saveKey)
                        .disabled(key.trimmingCharacters(in: .whitespaces) == Keychain.read())
                }
                Link("去 DeepSeek 开放平台拿 Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    .font(.system(size: 12))
            } header: {
                Text("DeepSeek API Key")
            } footer: {
                Text("存在这台 Mac 的钥匙串里，只发给 api.deepseek.com。").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Picker("模型", selection: $model) {
                    Text("deepseek-flash（推荐）").tag("deepseek-flash")
                    Text("deepseek-v4-pro").tag("deepseek-v4-pro")
                }
                Toggle("先思考再出卡", isOn: $thinking)
            } header: {
                Text("出卡")
            } footer: {
                Text("开着思考，一段长对话大约 1 分钟，挑得更准；关掉大约 10 秒，会混进一些只对这次有用的细节。deepseek-flash 做一段 1 万字的对话约 1 美分。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: key) { saved = false }
    }

    private func saveKey() {
        Keychain.save(key)
        key = Keychain.read()
        saved = true
        NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
    }
}

private struct AnkiSettings: View {
    @EnvironmentObject private var app: AppModel
    @State private var deck = Prefs.deckName

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConnectAnkiView()
            Rectangle().fill(Theme.line).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("默认牌组").font(.system(size: 13))
                    TextField(Prefs.defaultDeck, text: $deck)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(apply)
                    Button("改", action: apply)
                        .disabled(deck.trimmingCharacters(in: .whitespaces) == Prefs.deckName)
                }
                Text("卡片默认进这个牌组；建好以后在 Anki 里改名也行，这里跟着走。主题不建牌组，写进标签（主题::Git），来源写进「来自::ChatCards」。")
                    .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .onAppear { deck = Prefs.deckName }
        .onReceive(app.$topDeck) { deck = $0 }
    }

    private func apply() {
        Prefs.setDeck(deck)
        deck = Prefs.deckName
        app.topDeck = deck
        app.chosenDeck = nil
        app.refreshDecks()
    }
}
