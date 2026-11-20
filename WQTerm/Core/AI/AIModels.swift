import Foundation

/// Tin nhắn trong hội thoại AI.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String
    /// `true` khi tin nhắn đang được stream (hiển thị spinner thay vì nội dung).
    var isStreaming: Bool
    let createdAt: Date

    init(id: UUID = UUID(),
         role: Role,
         content: String,
         isStreaming: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}

/// Lỗi trả về từ LiteRouter (hoặc lỗi mạng/parse).
enum AIServiceError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint(String)
    case http(status: Int, body: String)
    case emptyResponse
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Chưa có API key. Nhập key trong tab AI trước khi chat."
        case .invalidEndpoint(let value):
            return "Endpoint không hợp lệ: \(value). Cần dạng https://host/api/v1/chat/completions."
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "(không có nội dung)" : String(trimmed.prefix(400))
            return "LiteRouter trả về HTTP \(status): \(detail)"
        case .emptyResponse:
            return "Phản hồi rỗng từ server."
        case .decoding(let reason):
            return "Không phân tích được phản hồi: \(reason)"
        case .transport(let reason):
            return "Lỗi mạng: \(reason)"
        }
    }
}
