import AppKit
import SwiftUI

@main
struct ChatCardsApp: App {
    @StateObject private var model = AppModel()

    init() {
        // 测试模式（E2E=1）：在读偏好、开窗口之前换好，见 TestMode
        TestMode.install()
    }

    var body: some Scene {
        // 只有一个主窗口：/anki 送来的链接也进这个窗口，不另开
        Window("ChatCards", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
                .onOpenURL { model.importText($0.absoluteString) }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("从剪贴板导入链接") {
                    if let text = NSPasteboard.general.string(forType: .string) { model.importText(text) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
