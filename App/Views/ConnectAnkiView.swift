import AnkiLearnCore
import AppKit
import SwiftUI

/// 这台 Mac 上 Anki 的三件事：装了没有、AnkiConnect 插件装了没有、开着没有。每 2 秒自己查一次
@MainActor
final class AnkiCheck: ObservableObject {
    /// 装好的 Anki 的版本；nil 就是没找到
    @Published var ankiVersion: String?
    @Published var ankiURL: URL?
    @Published var addonInstalled = false
    @Published var connected = false
    @Published var running = false
    @Published var opening = false
    @Published var checkedOnce = false

    static var addonFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Anki2/addons21/\(AnkiConnect.addonCode)")
    }

    func check() async {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppModel.ankiBundleID)
        ankiURL = url
        ankiVersion = url.map { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
        running = AppModel.ankiIsRunning
        do {
            _ = try await AnkiConnect().version()
            connected = true
        } catch {
            connected = false
        }
        addonInstalled = connected || FileManager.default.fileExists(atPath: Self.addonFolder.path)
        if connected { opening = false }
        checkedOnce = true
    }
}

/// 连上 Anki：三个软件（ChatCards、Ask Free、GetNewWord）同一块。设置里的「Anki」页和提示条上的「怎么装」都打开它。
/// 下一步要做的那个按钮是这一屏唯一的实心按钮
struct ConnectAnkiView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var check = AnkiCheck()
    @State private var copied = false

    private enum Step { case install, addon, open, done }

    private var next: Step {
        if check.ankiVersion == nil { return .install }
        if !check.addonInstalled { return .addon }
        if !check.connected { return .open }
        return .done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("连上 Anki").font(.system(size: 22, weight: .semibold))
            Text("做好的卡片送进 Anki 复习。手机上的 AnkiMobile、AnkiDroid 同步以后也有。下面三项每 2 秒自己查一次，不用点检查。")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            diagram.padding(.top, 18)

            VStack(spacing: 0) {
                ankiRow
                Rectangle().fill(Theme.line).frame(height: 0.5)
                addonRow
                Rectangle().fill(Theme.line).frame(height: 0.5)
                openRow
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 0.5))
            .padding(.top, 16)

            Text(check.connected ? "卡片会放进「\(model.topDeck)」牌组。" : "连上以后，卡片放进「\(model.topDeck)」牌组。没连上时卡片留在软件里，连上再送。")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .padding(.top, 12)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                await check.check()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: 示意图：软件 — AnkiConnect — Anki，连上了线变绿

    private var diagram: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                node(Image(nsImage: NSApp.applicationIconImage), "Anki Learn")
                wire
                HStack(spacing: 6) {
                    Dot(color: check.connected ? Theme.ok : check.addonInstalled ? Theme.warn : Theme.text3)
                    Text("AnkiConnect").font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
                .padding(.bottom, 20)
                wire
                node(check.ankiURL.map { Image(nsImage: NSWorkspace.shared.icon(forFile: $0.path)) } ?? Image(systemName: "rectangle.stack"), "Anki")
            }
            Group {
                if check.connected {
                    Text("连上了").foregroundStyle(Theme.ok)
                } else if check.checkedOnce {
                    Text("没连上 · " + (next == .install ? "还没装 Anki" : next == .addon ? "还差 AnkiConnect 插件" : "Anki 没开")).foregroundStyle(Theme.warn)
                } else {
                    Text("正在查…").foregroundStyle(Theme.text2)
                }
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func node(_ icon: Image, _ name: String) -> some View {
        VStack(spacing: 6) {
            icon.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line, lineWidth: 0.5))
            Text(name).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .frame(width: 110)
    }

    private var wire: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0.75))
            p.addLine(to: CGPoint(x: 56, y: 0.75))
        }
        .stroke(check.connected ? Theme.ok : Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: check.connected ? [] : [4, 3]))
        .frame(width: 56, height: 1.5)
        .padding(.bottom, 20)
    }

    // MARK: 三行

    private var ankiRow: some View {
        row(state: check.ankiVersion != nil ? .ok : .warn, title: "Anki 桌面版",
            detail: check.ankiVersion.map { $0.isEmpty ? "装好了" : "装好了 · \($0)" } ?? "这台 Mac 上没找到 Anki") {
            if check.ankiVersion == nil {
                action("下载 Anki", systemImage: "arrow.up.right", solid: next == .install) {
                    NSWorkspace.shared.open(URL(string: "https://apps.ankiweb.net")!)
                }
            }
        }
    }

    private var addonRow: some View {
        row(state: check.addonInstalled ? .ok : check.ankiVersion != nil ? .warn : .idle, title: "AnkiConnect 插件",
            detail: check.addonInstalled ? "装好了 · 编号 \(AnkiConnect.addonCode)" : "编号 \(AnkiConnect.addonCode)，Anki 靠它收卡",
            extra: check.addonInstalled || check.ankiVersion == nil ? nil : AnyView(steps)) {
            if !check.addonInstalled {
                action(copied ? "已复制" : "复制编号", systemImage: copied ? "checkmark" : "doc.on.doc", solid: next == .addon) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AnkiConnect.addonCode, forType: .string)
                    copied = true
                }
                .disabled(check.ankiVersion == nil)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepLine(1, Text("在 Anki 里点「工具 › 附加组件 › 获取附加组件」"))
            stepLine(2, Text("粘贴编号 ") + Text(AnkiConnect.addonCode).font(.system(size: 12, design: .monospaced)) + Text("，点「确定」"))
            stepLine(3, Text("装好以后重启 Anki，这一行会自己变绿"))
        }
        .padding(.top, 8)
    }

    private func stepLine(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11)).foregroundStyle(Theme.text2)
                .frame(width: 17, height: 17)
                .background(Theme.fill, in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 0.5))
            text.font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openRow: some View {
        let detail: String
        if check.connected {
            detail = "连上了"
        } else if check.opening {
            detail = "正在打开…"
        } else if check.running && check.addonInstalled {
            detail = "开着，但插件还没生效：装好插件以后要重启一次 Anki"
        } else {
            detail = "没开"
        }
        return row(state: check.connected ? .ok : check.ankiVersion != nil ? .warn : .idle, title: "Anki 开着", detail: detail) {
            if !check.connected {
                action("打开 Anki", systemImage: nil, solid: next == .open, busy: check.opening) {
                    check.opening = model.openAnki()
                }
                .disabled(check.ankiVersion == nil)
            }
        }
    }

    // MARK: 零件

    private enum RowState { case ok, warn, idle }

    private func row<Actions: View>(state: RowState, title: String, detail: String, extra: AnyView? = nil,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                switch state {
                case .ok:
                    Circle().fill(Theme.ok)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                case .warn:
                    Circle().stroke(Theme.warn, lineWidth: 1.5)
                    Text("!").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warn)
                case .idle:
                    Circle().stroke(Theme.line2, lineWidth: 1.5)
                }
            }
            .frame(width: 20, height: 20)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let extra { extra }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func action(_ title: String, systemImage: String?, solid: Bool, busy: Bool = false, run: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            Text(title)
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
        }
        if solid {
            Button(action: run) { label }.buttonStyle(PrimaryButtonStyle())
        } else {
            Button(action: run) { label }.buttonStyle(OutlineButtonStyle())
        }
    }
}
