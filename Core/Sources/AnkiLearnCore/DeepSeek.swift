import Foundation

public enum DeepSeekError: LocalizedError, Equatable {
    case noKey
    case badKey
    case noBalance
    case rateLimited
    case server(Int, String)
    case network(String)
    case badResponse
    /// 打开 JSON 模式后偶尔会回一串空格（DeepSeek 文档写明的已知情况）
    case blankAnswer

    public var errorDescription: String? {
        switch self {
        case .noKey: return "还没填 DeepSeek 的 API Key：在「设置」里填上"
        case .badKey: return "DeepSeek 说 API Key 不对：在「设置」里检查一下"
        case .noBalance: return "DeepSeek 账户余额不够了：去 platform.deepseek.com 充值"
        case .rateLimited: return "DeepSeek 这会儿请求太多，等一分钟再试"
        case .server(let code, let message): return "DeepSeek 出错了（\(code)）：\(message)"
        case .network(let message): return "连不上 DeepSeek：\(message)"
        case .badResponse: return "DeepSeek 回的内容读不懂"
        case .blankAnswer: return "DeepSeek 回了空内容"
        }
    }
}

public struct Usage: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int

    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }

    public static func + (a: Usage, b: Usage) -> Usage { Usage(input: a.input + b.input, output: a.output + b.output) }
}

/// DeepSeek 的对话接口（OpenAI 格式）：https://api-docs.deepseek.com
public struct DeepSeek: Sendable {
    public static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let models = ["deepseek-flash", "deepseek-v4-pro"]

    let key: String
    let model: String
    let thinking: Bool
    let endpoint: URL
    let session: URLSession

    public init(key: String, model: String, thinking: Bool, endpoint: URL = DeepSeek.endpoint, session: URLSession? = nil) {
        self.key = key
        self.model = model
        self.thinking = thinking
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            // 开着思考读一段长对话要一两分钟
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 900
            self.session = URLSession(configuration: config)
        }
    }

    /// 发一次请求，要求回 JSON；返回模型回的那段文字
    public func json(system: String, user: String) async throws -> (String, Usage) {
        guard !key.isEmpty else { throw DeepSeekError.noKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "response_format": ["type": "json_object"],
            "thinking": ["type": thinking ? "enabled" : "disabled"],
            "max_tokens": 64000,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw DeepSeekError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch status {
            case 401: throw DeepSeekError.badKey
            case 402: throw DeepSeekError.noBalance
            case 429: throw DeepSeekError.rateLimited
            default: throw DeepSeekError.server(status, message)
            }
        }
        guard let choices = obj?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw DeepSeekError.badResponse }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeepSeekError.blankAnswer }
        let usage = obj?["usage"] as? [String: Any]
        return (content, Usage(input: usage?["prompt_tokens"] as? Int ?? 0, output: usage?["completion_tokens"] as? Int ?? 0))
    }
}
