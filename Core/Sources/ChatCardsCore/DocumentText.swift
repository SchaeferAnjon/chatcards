import Foundation
import PDFKit

public enum DocumentError: LocalizedError {
    case unreadable(URL)
    case noText(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "打不开这个文件：\(url.lastPathComponent)"
        case .noText(let url): return "\(url.lastPathComponent) 里读不出文字（扫描版 PDF 还不支持）"
        }
    }
}

/// 文件里的文字：PDF 用系统自带的 PDFKit 读，其余当纯文本读
public enum DocumentText {
    public static func read(_ url: URL) throws -> String {
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw DocumentError.unreadable(url) }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
        } else {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { throw DocumentError.unreadable(url) }
            text = s
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError.noText(url) }
        return text
    }
}
