import AnkiLearnCore
import SwiftUI

struct SourceView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var source: Source

    private var job: AppModel.Job? { model.jobs[source.id] }
    private var busy: Bool {
        switch job {
        case .reading, .asking: return true
        default: return false
        }
    }
    private var pending: [Card] { source.cards.filter { !$0.inAnki } }
    private var chosen: Int { pending.filter(\.selected).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let job { JobCard(job: job, sourceID: source.id) }
                    if let note = staleNote, !busy { staleCard(note) }
                    if !busy, job == nil, source.generatedAt != nil, source.cards.isEmpty {
                        empty
                    }
                    ForEach($source.cards) { $card in
                        CardRow(card: $card) {
                            source.cards.removeAll { $0.id == card.id }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            if !source.cards.isEmpty {
                Rectangle().fill(Theme.line).frame(height: 0.5)
                bottomBar
            }
        }
    }

    // MARK: 页头

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title).font(.system(size: 17, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let link = source.link, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: { Label("原文", systemImage: "arrow.up.right.square") }
                    .buttonStyle(QuietButtonStyle())
            }
            Button { model.browseInAnki(source.id) } label: { Label("在 Anki 里看", systemImage: "rectangle.stack") }
                .buttonStyle(QuietButtonStyle())
                .disabled(!source.cards.contains(where: \.inAnki))
            Button { model.generate(source.id) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                .buttonStyle(QuietButtonStyle())
                .disabled(busy)
                .help("重新读一遍，换掉还没送进 Anki 的卡")
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private var subtitle: String {
        var parts: [String] = []
        switch source.kind {
        case .claudeSession: parts.append("Claude Code 会话")
        case .document: parts.append("文档")
        case .web: parts.append("网页")
        }
        if let at = source.generatedAt { parts.append(at.formatted(date: .abbreviated, time: .shortened) + " 做的") }
        if let m = source.model { parts.append(m) }
        if let u = source.usage, u.input > 0 { parts.append("读了 \(tokens(u.input)) token，写了 \(tokens(u.output))") }
        return parts.joined(separator: " · ")
    }

    private func tokens(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1f 万", Double(n) / 10_000) : "\(n)"
    }

    /// 会话在卡片做好之后又聊了
    private var staleNote: String? {
        guard source.kind == .claudeSession, let at = source.generatedAt,
              let session = model.sessions.first(where: { $0.id == source.origin }),
              session.modified.timeIntervalSince(at) > 60 else { return nil }
        return "做完卡片以后，这个会话又聊了一些（最后一次 \(session.modified.formatted(.relative(presentation: .named)))）。"
    }

    private func staleCard(_ note: String) -> some View {
        HStack(spacing: 10) {
            Dot(color: Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(note).font(.system(size: 13, weight: .medium))
                Text("重新生成会读整段对话，换掉还没送进 Anki 的卡；已经送进去的留着。").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button("重新生成") { model.generate(source.id) }.buttonStyle(QuietButtonStyle())
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.text3)
            Text("这段内容里没挑出值得记的知识点").font(.system(size: 13, weight: .medium))
            Text("闲聊、进度汇报、只对这一次有用的细节不做成卡片。").font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: 底栏

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                let all = chosen < pending.count
                for i in source.cards.indices where !source.cards[i].inAnki { source.cards[i].selected = all }
            } label: {
                HStack(spacing: 6) {
                    CheckBox(on: chosen > 0 && chosen == pending.count)
                    Text("全选").font(.system(size: 13))
                }
            }
            .buttonStyle(.plain)
            .disabled(pending.isEmpty)

            Text(pending.isEmpty ? "都在 Anki 里了" : "已选 \(chosen) 张，共 \(pending.count) 张没送")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .monospacedDigit()
            Spacer()
            Text("牌组 \(model.deck(for: source))").font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
            Button {
                model.send(source.id)
            } label: {
                if model.sending.contains(source.id) {
                    HStack(spacing: 6) { ProgressView().controlSize(.small).tint(Theme.onInk); Text("正在送…") }
                } else {
                    Text("送进 Anki")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(chosen == 0 || model.sending.contains(source.id) || busy)
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
        .background(Theme.bg)
    }
}

/// 正在读、正在问 DeepSeek、或者出错了
struct JobCard: View {
    @EnvironmentObject private var model: AppModel
    let job: AppModel.Job
    let sourceID: UUID

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch job {
            case .reading:
                ProgressView().controlSize(.small)
                Text("正在读…").font(.system(size: 13, weight: .medium))
                Spacer()
            case .asking(let done, let total, let started):
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(total > 1 ? "DeepSeek 正在挑知识点（\(done)/\(total) 段做完）" : "DeepSeek 正在挑知识点")
                        .font(.system(size: 13, weight: .medium))
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text("已经 \(Int(context.date.timeIntervalSince(started))) 秒；开着思考一段一般要 1 分钟左右")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).monospacedDigit()
                    }
                }
                Spacer()
            case .failed(let message, let needsKey):
                Dot(color: Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("卡片没做成").font(.system(size: 13, weight: .medium))
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.text2).textSelection(.enabled)
                }
                Spacer()
                if needsKey || message == DeepSeekError.noKey.localizedDescription {
                    SettingsLink { Text("打开设置") }.buttonStyle(QuietButtonStyle())
                }
                Button("重试") { model.generate(sourceID) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
    }
}

struct CardRow: View {
    @Binding var card: Card
    let onDelete: () -> Void
    @State private var editing = false
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if !card.inAnki { card.selected.toggle() }
            } label: {
                CheckBox(on: card.inAnki || card.selected, dimmed: card.inAnki)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .help(card.inAnki ? "已经在 Anki 里了" : "勾上的送进 Anki")

            if editing { editor } else { content }

            VStack(spacing: 4) {
                if card.inAnki {
                    Text("已在 Anki").font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize()
                }
                if hover || editing {
                    HStack(spacing: 2) {
                        Button { editing.toggle() } label: {
                            Image(systemName: editing ? "checkmark" : "pencil").frame(width: 24, height: 24)
                        }
                        .help(editing ? "改好了" : "改这张卡")
                        if !editing {
                            Button(action: onDelete) { Image(systemName: "trash").frame(width: 24, height: 24) }
                                .help("不要这张")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .disabled(card.inAnki)
                }
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
        .opacity(card.inAnki || card.selected ? 1 : 0.55)
        .onHover { hover = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.q).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(card.a).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if !card.more.isEmpty {
                Text(card.more).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            if !card.quote.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.quote).frame(width: 2)
                    Text(card.quote).font(.system(size: 12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("问题", text: $card.q, size: 14, weight: .medium)
            field("答案", text: $card.a, size: 13)
            field("补充（可空）", text: $card.more, size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, text: Binding<String>, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text3)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: size, weight: weight))
                .padding(6)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
