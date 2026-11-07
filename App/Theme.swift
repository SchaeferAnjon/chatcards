import SwiftUI
import AppKit

/// 和 GetNewWord、Ask Free 同一套颜色：浅色深色各一套，主色是墨黑（深色模式近白）
enum Theme {
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let bg = dyn(rgb(250, 250, 251), rgb(22, 23, 26))
    static let card = dyn(rgb(255, 255, 255), rgb(35, 36, 40))
    static let fill = dyn(rgb(0, 0, 0, 0.04), rgb(255, 255, 255, 0.05))
    static let sel = dyn(rgb(0, 0, 0, 0.07), rgb(255, 255, 255, 0.08))
    static let line = dyn(rgb(0, 0, 0, 0.09), rgb(255, 255, 255, 0.08))
    static let line2 = dyn(rgb(0, 0, 0, 0.16), rgb(255, 255, 255, 0.14))
    static let text = dyn(rgb(24, 25, 28), rgb(237, 237, 239))
    static let text2 = dyn(rgb(95, 99, 108), rgb(140, 145, 155))
    static let text3 = dyn(rgb(150, 154, 162), rgb(92, 99, 112))
    static let ink = dyn(rgb(24, 25, 28), rgb(237, 237, 239))
    static let onInk = dyn(rgb(255, 255, 255), rgb(22, 23, 26))
    static let quote = dyn(rgb(84, 96, 210, 0.7), rgb(138, 148, 245, 0.7))
    static let ok = dyn(rgb(40, 150, 90), rgb(92, 194, 133))
    static let warn = dyn(rgb(205, 125, 20), rgb(242, 158, 64))
    static let danger = dyn(rgb(200, 60, 60), rgb(230, 92, 92))
}

/// 一屏一个的实心主按钮
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.ink.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 无边框的次要按钮：图标加字
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(enabled ? Theme.text2 : Theme.text3)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hover || configuration.isPressed ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hover = $0 }
    }
}

/// 4 圆角的方形复选框，选中墨黑
struct CheckBox: View {
    let on: Bool
    var dimmed = false
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(on ? (dimmed ? Theme.text3 : Theme.ink) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? .clear : Theme.line2, lineWidth: 1))
            .overlay {
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onInk) }
            }
            .frame(width: 16, height: 16)
    }
}

/// 状态点：只把状态色放在点上
struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}
