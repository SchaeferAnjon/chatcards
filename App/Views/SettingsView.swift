import AnkiLearnCore
import SwiftUI

struct SettingsView: View {
    @State private var key = Keychain.read()
    @State private var saved = false
    @AppStorage(Prefs.modelKey) private var model = "deepseek-flash"
    @AppStorage(Prefs.thinkingKey) private var thinking = true
    @AppStorage(Prefs.deckKey) private var deckRoot = "Anki Learn"

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

            Section {
                TextField("牌组", text: $deckRoot)
            } header: {
                Text("Anki")
            } footer: {
                Text("卡片放进「\(deckRoot.isEmpty ? "Anki Learn" : deckRoot)::Claude Code」「…::文档」「…::网页」。要先开着 Anki，装好 AnkiConnect 插件（编号 2055492159）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onChange(of: key) { saved = false }
    }

    private func saveKey() {
        Keychain.save(key)
        key = Keychain.read()
        saved = true
        NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
    }
}
