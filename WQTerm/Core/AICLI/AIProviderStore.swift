import Foundation
import SwiftUI

/// Một nhà cung cấp AI mà WQTerm hỗ trợ.
enum AIProvider: String, CaseIterable, Identifiable {
    case groq
    case gemini
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .codex: return "Codex (OpenAI)"
        }
    }

    /// Tên biến môi trường mà CLI tương ứng đọc key.
    var environmentKey: String {
        switch self {
        case .groq: return "GROQ_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .claude: return "ANTHROPIC_API_KEY"
        case .codex: return "OPENAI_API_KEY"
        }
    }

    /// Đường dẫn tương đối tới CLI trong bundle. Groq dùng script Python nhúng.
    var binaryRelativePath: String {
        switch self {
        case .groq: return "Resources/Scripts/ai_cli.py"
        case .gemini: return "Resources/node_modules/.bin/gemini"
        case .claude: return "Resources/node_modules/.bin/claude"
        case .codex: return "Resources/node_modules/.bin/codex"
        }
    }

    /// Khoá Keychain dùng để lưu API key.
    var keychainAccount: String { "WQTerm.AIKey.\(displayName)" }

    var systemImage: String {
        switch self {
        case .groq: return "bolt.fill"
        case .gemini: return "sparkle"
        case .claude: return "brain"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Đọc/ghi API key cho các nhà cung cấp AI, lưu trong Keychain.
///
/// Key không bao giờ được ghi ra UserDefaults hay file — chỉ Keychain với
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()

    /// `true` nếu Keychain đã có key cho provider tương ứng.
    @Published private(set) var configured: [AIProvider: Bool] = [:]

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let baseURLKey = "WQTerm.AI.BaseURL"
    /// Endpoint tuỳ chỉnh cho các gateway tương thích OpenAI (ví dụ dịch vụ router).
    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: baseURLKey) }
    }

    private init() {
        baseURL = defaults.string(forKey: baseURLKey) ?? Self.defaultBaseURL
        refresh()
    }

    /// Endpoint mặc định — Groq (OpenAI-compatible).
    static let defaultBaseURL = "https://api.groq.com/openai/v1"

    /// Đọc lại trạng thái cấu hình của tất cả provider.
    func refresh() {
        var result: [AIProvider: Bool] = [:]
        for provider in AIProvider.allCases {
            let stored = (try? key(provider)) ?? nil
            result[provider] = (stored?.isEmpty == false)
        }
        configured = result
    }

    /// Đọc API key (nil nếu chưa lưu).
    func key(_ provider: AIProvider) throws -> String? {
        guard let data = try KeychainService.shared.read(key: provider.keychainAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Mặt nạ để hiển thị key mà không lộ toàn bộ.
    func maskedKey(_ provider: AIProvider) -> String? {
        // `try?` trên hàm trả `String?` đã flatten sẵn thành `String?`.
        guard let value = try? key(provider), !value.isEmpty else { return nil }
        guard value.count > 8 else { return String(repeating: "•", count: value.count) }
        return String(value.prefix(4)) + String(repeating: "•", count: 8) + String(value.suffix(4))
    }

    /// Lưu API key vào Keychain.
    func saveKey(_ value: String, for provider: AIProvider) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProviderError.emptyKey }
        // Keychain item không nên quá dài — chặn rác do dán nhầm.
        guard trimmed.count <= 512 else { throw AIProviderError.keyTooLong }
        try KeychainService.shared.write(key: provider.keychainAccount, data: Data(trimmed.utf8))
        AuditLogger.shared.log(event: .aiCLICall(tool: provider.rawValue))
        refresh()
    }

    /// Xoá API key khỏi Keychain.
    func deleteKey(for provider: AIProvider) throws {
        try KeychainService.shared.delete(key: provider.keychainAccount)
        refresh()
    }

    /// Biến môi trường cần truyền cho CLI.
    func environment(for provider: AIProvider) -> [String: String] {
        var environment: [String: String] = [:]

        // Gán nil vào dictionary sẽ xoá key, nên chỉ ghi khi có giá trị thật.
        if let value = try? key(provider), !value.isEmpty {
            environment[provider.environmentKey] = value
        }
        if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            environment["OPENAI_BASE_URL"] = baseURL
            environment["ANTHROPIC_BASE_URL"] = baseURL
        }
        return environment
    }

    /// Kiểm tra CLI tương ứng có tồn tại trong bundle không.
    ///
    /// Dùng `Bundle.main.path(forResource:ofType:inDirectory:)` để hoạt động cả khi
    /// `Resources/node_modules` được copy dạng folder reference.
    func cliExists(_ provider: AIProvider) -> Bool {
        let relative = provider.binaryRelativePath
        if let _ = Bundle.main.path(forResource: (relative as NSString).lastPathComponent,
                                    ofType: nil,
                                    inDirectory: (relative as NSString).deletingLastPathComponent) {
            return true
        }
        return FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appendingPathComponent(relative).path
        )
    }

    /// Lưu endpoint tuỳ chỉnh; chuỗi rỗng ⇒ quay về LiteRouter mặc định.
    func saveBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = trimmed.isEmpty ? Self.defaultBaseURL : trimmed
        AuditLogger.shared.log(event: .fileWrite(path: baseURL))
    }
}

enum AIProviderError: LocalizedError {
    case emptyKey
    case keyTooLong
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyKey: return "API key không được để trống."
        case .keyTooLong: return "API key quá dài (tối đa 512 ký tự)."
        case .keychainUnavailable: return "Không truy cập được Keychain."
        }
    }
}
