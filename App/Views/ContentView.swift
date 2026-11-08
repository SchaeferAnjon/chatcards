import AnkiLearnCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 280)
        } detail: {
            Group {
                switch model.page {
                case .home:
                    HomeView()
                case .source(let id):
                    if let source = model.binding(id) {
                        SourceView(source: source)
                    } else {
                        HomeView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.ink.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                if url.isFileURL { model.importFile(url) } else { model.importText(url.absoluteString) }
            }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $model.webImport) { item in
            WebImportView(item: item)
        }
        .sheet(isPresented: $model.connectShown) {
            VStack(spacing: 0) {
                ConnectAnkiView()
                Rectangle().fill(Theme.line).frame(height: 0.5)
                HStack {
                    Spacer()
                    Button("好了") { model.connectShown = false }.keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .frame(width: 600)
            .environmentObject(model)
        }
        .alert("「学习卡 · 问答」的样子你在 Anki 里改过", isPresented: Binding(get: { model.styleQuestion != nil }, set: { if !$0 { model.styleQuestion = nil } })) {
            Button("换成新样子") { model.answerStyleQuestion(replace: true) }
            Button("留着我改的") { model.answerStyleQuestion(replace: false) }
            Button("先不送", role: .cancel) { model.styleQuestion = nil }
        } message: {
            Text("换成新样子会盖掉你改的模板和样式，卡片内容不变。选好以后不再问；Ask Free、GetNewWord 也用这个笔记类型。")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
            Label {
                Text("新建")
            } icon: {
                Image(systemName: "plus").foregroundStyle(Theme.text2)
            }
            .tag(AppModel.Page.home)
            if !model.sources.isEmpty {
                Section("做过的") {
                    ForEach(model.sources) { source in
                        SourceRow(source: source, job: model.jobs[source.id])
                            .tag(AppModel.Page.source(source.id))
                            .contextMenu {
                                Button("重新生成") { model.generate(source.id) }
                                    .disabled(model.jobs[source.id] != nil && !isFailed(model.jobs[source.id]))
                                if let link = source.link, let url = URL(string: link) {
                                    Button("打开原文") { NSWorkspace.shared.open(url) }
                                }
                                Divider()
                                Button("删除", role: .destructive) { model.delete(source.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func isFailed(_ job: AppModel.Job?) -> Bool {
        if case .failed = job { return true }
        return false
    }
}

struct SourceRow: View {
    let source: Source
    let job: AppModel.Job?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.system(size: 13)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            switch job {
            case .reading, .asking: ProgressView().controlSize(.small)
            case .failed: Dot(color: Theme.danger)
            case nil: EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch job {
        case .reading, .asking: return "正在做卡片…"
        case .failed: return "没做成"
        case nil:
            let sent = source.cards.filter(\.inAnki).count
            if source.generatedAt == nil { return "还没做" }
            return sent == 0 ? "\(source.cards.count) 张" : "\(source.cards.count) 张 · \(sent) 张已进 Anki"
        }
    }
}

struct ToastView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let toast = model.toast {
            HStack(alignment: .top, spacing: 10) {
                Dot(color: toast.ok ? Theme.ok : Theme.danger).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(.system(size: 13, weight: .medium))
                    if let detail = toast.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let action = toast.action {
                    Button(label(action)) { model.perform(action) }
                        .buttonStyle(QuietButtonStyle())
                }
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
                .frame(width: 22, height: 22)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minWidth: 300, maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .padding(.bottom, 64)
            .transition(.opacity)
        }
    }

    private func label(_ action: AppModel.Toast.Action) -> String {
        switch action {
        case .openAnkiThenSend: return "打开 Anki 再送"
        case .howToInstall: return "怎么装"
        case .browse: return "在 Anki 里看"
        }
    }
}
