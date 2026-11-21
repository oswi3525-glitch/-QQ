import Foundation
import Combine

/// Client gọi LiteRouter (`/api/v1/chat/completions`) — Module 4.
///
/// Đặc điểm thiết kế:
/// - Dùng `URLSession` thuần, **không** dùng SDK OpenAI để tránh lỗi C-extension
///   khi nhúng qua Python/Node; script `ai.py` trong Resources cũng chỉ dùng
///   `requests` vì cùng lý do.
/// - API key đọc từ Keychain qua `AIProviderStore` (không lưu UserDefaults).
/// - Endpoint mặc định: `https://literouter.fun/api/v1/chat/completions`.
final class AIService: ObservableObject {
    static let shared = AIService()

    /// Model mặc định theo yêu cầu dự án (Groq).
    static let defaultModel = "llama-3.3-70b-versatile"
    /// Endpoint mặc định: Groq OpenAI-compatible (`Authorization: Bearer`).
    static let defaultEndpoint = "https://api.groq.com/openai/v1/chat/completions"

    /// Toàn bộ hội thoại hiện tại, chia sẻ giữa tab AI và nút "Ask AI" trong viewer.
    @Published var messages: [ChatMessage] = []
    /// `true` khi đang chờ phản hồi.
    @Published private(set) var isSending = false
    @Published var endpoint: String
    @Published var model: String

    private let store = AIProviderStore.shared
    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let endpointKey = "WQTerm.AI.Endpoint"
    private let modelKey = "WQTerm.AI.Model"
    private let session: URLSession

    private init() {
        endpoint = defaults.string(forKey: endpointKey) ?? Self.defaultEndpoint
        model = defaults.string(forKey: modelKey) ?? Self.defaultModel

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    // MARK: - Cấu hình

    /// Lưu endpoint; chuỗi rỗng ⇒ quay về LiteRouter mặc định.
    func saveEndpoint(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = trimmed.isEmpty ? Self.defaultEndpoint : trimmed
        defaults.set(endpoint, forKey: endpointKey)
    }

    /// Lưu model; chuỗi rỗng ⇒ quay về model mặc định.
    func saveModel(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        model = trimmed.isEmpty ? Self.defaultModel : trimmed
        defaults.set(model, forKey: modelKey)
    }

    /// API key đang dùng để gọi AI.
    ///
    /// Ưu tiên key Groq (mặc định của tab AI); nếu trống thì thử lần lượt
    /// các provider còn lại để tương thích cấu hình cũ.
    var apiKey: String? {
        for provider in [AIProvider.groq, .gemini, .codex, .claude] {
            if let value = try? store.key(provider), !value.isEmpty { return value }
        }
        return nil
    }

    var hasAPIKey: Bool { apiKey != nil }

    /// Lưu API key vào Keychain (provider Groq — mặc định của tab AI).
    func saveAPIKey(_ value: String) throws {
        try store.saveKey(value, for: .groq)
    }

    /// Xoá API key Groq khỏi Keychain.
    func deleteAPIKey() throws {
        try store.deleteKey(for: .groq)
    }

    /// Kiểm tra API key + model bằng một request tối thiểu.
    ///
    /// Không đụng tới lịch sử chat. Ném lỗi có mô tả rõ ràng để UI hiển thị.
    func validateConnection() async throws {
        guard let key = apiKey else { throw AIServiceError.missingAPIKey }
        _ = try await requestCompletion(prompt: "ping",
                                        apiKey: key,
                                        useHistory: false,
                                        maxTokens: 8)
    }

    // MARK: - Hội thoại

    func clearConversation() {
        messages = []
    }

    /// Gửi một prompt và trả về nội dung trả lời (đã lưu vào `messages`).
    @discardableResult
    func send(_ prompt: String) async throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIServiceError.emptyResponse }
        guard let key = apiKey else { throw AIServiceError.missingAPIKey }

        messages.append(ChatMessage(role: .user, content: trimmed))
        let placeholder = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(placeholder)

        DispatchQueue.main.async { self.isSending = true }
        defer { DispatchQueue.main.async { self.isSending = false } }

        do {
            let reply = try await requestCompletion(prompt: trimmed, apiKey: key)
            updatePlaceholder(placeholder.id, content: reply, streaming: false)
            AuditLogger.shared.log(event: .aiCLICall(tool: "literouter:\(model)"))
            return reply
        } catch {
            updatePlaceholder(placeholder.id,
                              content: "⚠️ \(error.localizedDescription)",
                              streaming: false)
            throw error
        }
    }

    /// Cập nhật nội dung của tin nhắn placeholder (assistant đang chờ).
    private func updatePlaceholder(_ id: UUID, content: String, streaming: Bool) {
        DispatchQueue.main.async {
            guard let index = self.messages.firstIndex(where: { $0.id == id }) else { return }
            self.messages[index].content = content
            self.messages[index].isStreaming = streaming
        }
    }

    // MARK: - Gọi API

    /// Thực hiện POST tới endpoint tương thích OpenAI (hoặc Gemini native).
    ///
    /// - Parameters:
    ///   - useHistory: gửi kèm lịch sử chat (tắt khi validate key).
    ///   - maxTokens: giới hạn token cho request kiểm tra.
    func requestCompletion(prompt: String,
                           apiKey: String,
                           useHistory: Bool = true,
                           maxTokens: Int? = nil) async throws -> String {
        guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
            throw AIServiceError.invalidEndpoint(endpoint)
        }

        if Self.isGeminiNativeEndpoint(url) {
            return try await requestGeminiNative(prompt: prompt,
                                                 apiKey: apiKey,
                                                 useHistory: useHistory,
                                                 maxTokens: maxTokens)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("WQTerm/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        var payloadMessages: [[String: String]] = [
            ["role": "system",
             "content": "Bạn là trợ lý kỹ thuật của WQTerm trên iOS. "
                + "Trả lời ngắn gọn, chính xác, dùng Markdown khi hữu ích. "
                + "Khi đưa lệnh Terminal, bọc trong khối ```bash để người dùng xác nhận."]
        ]
        if useHistory {
            // Gửi kèm tối đa 12 lượt gần nhất để giữ ngữ cảnh mà không phình token.
            let history = messages
                .filter { $0.role != .system && !$0.isStreaming && !$0.content.isEmpty }
                .suffix(12)
                .filter { $0.content != prompt }
            for message in history {
                payloadMessages.append(["role": message.role.rawValue, "content": message.content])
            }
        }
        payloadMessages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "temperature": 0.4,
            "stream": false
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        return try Self.parseCompletion(data)
    }

    // MARK: - Gemini native

    private static func isGeminiNativeEndpoint(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.contains("generativelanguage.googleapis.com") && !value.contains("/openai/")
    }

    /// Gọi Gemini API gốc (`models/{model}:generateContent`).
    private func requestGeminiNative(prompt: String,
                                     apiKey: String,
                                     useHistory: Bool,
                                     maxTokens: Int?) async throws -> String {
        var base = endpoint
        while base.hasSuffix("/") { base.removeLast() }
        let urlString: String
        if base.contains("/models") {
            urlString = "\(base)/\(model):generateContent"
        } else {
            urlString = "\(base)/models/\(model):generateContent"
        }
        guard let url = URL(string: urlString) else {
            throw AIServiceError.invalidEndpoint(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("WQTerm/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        var contents: [[String: Any]] = []
        if useHistory {
            let history = messages
                .filter { $0.role != .system && !$0.isStreaming && !$0.content.isEmpty }
                .suffix(12)
                .filter { $0.content != prompt }
            for message in history {
                let role = message.role == .assistant ? "model" : "user"
                contents.append(["role": role, "parts": [["text": message.content]]])
            }
        }
        contents.append(["role": "user", "parts": [["text": prompt]]])

        var generationConfig: [String: Any] = ["temperature": 0.4]
        if let maxTokens { generationConfig["maxOutputTokens"] = maxTokens }
        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        return try Self.parseGeminiCompletion(data)
    }

    /// Chạy request và chuẩn hoá lỗi HTTP/transport.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIServiceError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIServiceError.http(status: http.statusCode, body: text)
        }
        return data
    }

    /// Phân tích response Gemini native: `candidates[0].content.parts[].text`.
    static func parseGeminiCompletion(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.decoding("response Gemini không phải JSON object")
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIServiceError.http(status: 200, body: message)
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AIServiceError.decoding("thiếu 'candidates[0].content.parts'")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIServiceError.emptyResponse }
        return text
    }

    /// Phân tích response tương thích OpenAI: `choices[0].message.content`.
    ///
    /// Chấp nhận thêm `choices[0].text` (legacy completion) để tương thích router.
    static func parseCompletion(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.decoding("response không phải JSON object")
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIServiceError.http(status: 200, body: message)
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIServiceError.decoding("thiếu 'choices'")
        }
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let text = first["text"] as? String, !text.isEmpty {
            return text
        }
        throw AIServiceError.emptyResponse
    }
}

