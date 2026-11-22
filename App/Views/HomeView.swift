import ChatCardsCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var link = ""
    @State private var hasKey = !Keychain.read().isEmpty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把会话做成 Anki 卡片").font(.system(size: 22, weight: .semibold))
                    Text("DeepSeek 读一遍对话，挑出值得记住的知识点做成问答卡；你看过、勾好，再一键送进 Anki。")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                }

                if !hasKey { keyCard }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("粘贴 Claude Code 会话链接（claude.ai/code/session_…）、文件路径或网址", text: $link)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2, lineWidth: 0.5))
                            .onSubmit(submit)
                        Button("做成卡片", action: submit)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("也可以把 PDF、Markdown、会话记录文件拖进窗口；在 Claude Code 里输入 /anki，会把那个会话直接送过来。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }

                sessionList
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { hasKey = !Keychain.read().isEmpty }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in hasKey = !Keychain.read().isEmpty }
    }

    private func submit() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.importText(text)
        link = ""
    }

    private var keyCard: some View {
        HStack(spacing: 10) {
            Dot(color: Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("还差一步：填上 DeepSeek 的 API Key").font(.system(size: 13, weight: .medium))
                Text("做卡片要用它。Key 存在这台 Mac 的钥匙串里。").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            SettingsLink { Text("打开设置") }.buttonStyle(QuietButtonStyle())
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近的 Claude Code 会话").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                Spacer()
                Button {
                    model.refreshSessions()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.loadingSessions)
            }
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.text3)
                    Text(model.loadingSessions ? "正在找会话…" : "这台 Mac 上还没有 Claude Code 会话").font(.system(size: 13, weight: .medium))
                    Text("会话记录在 ~/.claude/projects 里").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { i, session in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 12) }
                        SessionRow(session: session, made: model.sources.first { $0.kind == .claudeSession && $0.origin == session.id })
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
            }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    let made: Source?
    @State private var hover = false

    var body: some View {
        Button {
            model.importSession(session)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let made {
                    Text(made.generatedAt == nil ? "做过，没做成" : "做过 · \(made.cards.count) 张")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                } else if hover {
                    Text("做成卡片").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .background(hover ? Theme.fill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            if let url = session.webURL {
                Button("复制 claude.ai 链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("在访达里显示会话记录") { NSWorkspace.shared.activateFileViewerSelecting([session.fileURL]) }
        }
    }

    private var detail: String {
        let when = session.modified.formatted(.relative(presentation: .named))
        return session.project.isEmpty ? when : "\(session.project) · \(when)"
    }
}

extension Notification.Name {
    static let apiKeyChanged = Notification.Name("apiKeyChanged")
}
