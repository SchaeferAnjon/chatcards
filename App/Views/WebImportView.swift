import SwiftUI
import WebKit

/// 不在这台 Mac 上的会话、普通网页：在这里打开（登录状态留着），对话出来以后取下页面上的字
struct WebImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: AppModel.WebImport
    @StateObject private var page = ImportPage()
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(problem ?? item.note).font(.system(size: 12)).foregroundStyle(problem == nil ? Theme.text2 : Theme.danger).lineLimit(2)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("用这页做卡片", action: take)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(page.loading)
            }
            .padding(12)
            Rectangle().fill(Theme.line).frame(height: 0.5)
            WebViewBox(view: page.view)
        }
        .frame(width: 960, height: 680)
        .onAppear { page.view.load(URLRequest(url: item.url)) }
    }

    private func take() {
        page.view.evaluateJavaScript("[document.title, document.body.innerText]") { result, error in
            guard let parts = result as? [String], parts.count == 2 else {
                problem = "取不到这页的字：\(error?.localizedDescription ?? "页面还没打开")"
                return
            }
            let text = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 50 else {
                problem = "这页上还没有正文（只有 \(text.count) 个字）：等对话出来再点"
                return
            }
            model.importWeb(url: page.view.url ?? item.url, title: parts[0], text: text)
        }
    }
}

@MainActor
final class ImportPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    @Published var loading = true
    /// 网页自己开的小窗（Apple 登录这类）：放进一个独立窗口，关掉时网页会把结果传回原页
    private var popups: [NSWindow] = []

    override init() {
        let config = WKWebViewConfiguration()
        // 用默认的数据仓：登录过一次，下次还在
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "登录"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popups.first(where: { $0.contentView === webView }) else { return }
        window.close()
        popups.removeAll { $0 === window }
    }
}

struct WebViewBox: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
