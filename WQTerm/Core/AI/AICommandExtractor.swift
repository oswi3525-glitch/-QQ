import Foundation

/// Một lệnh (hoặc script nhiều dòng) mà AI trả về trong khối code.
struct AICommand: Identifiable, Equatable {
    let id = UUID()
    /// Toàn bộ nội dung khối lệnh (các dòng nối bằng `\n`).
    let command: String
    /// Ngôn ngữ của fence, ví dụ `bash`, `sh`, `console`.
    let language: String
    /// `true` nếu chứa lệnh/redirection nguy hiểm — UI bắt buộc xác nhận đỏ.
    let isDangerous: Bool
    /// Danh sách lý do bị đánh dấu nguy hiểm.
    let dangerReasons: [String]

    var summary: String {
        command.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Trích lệnh Terminal từ câu trả lời Markdown của AI (PRD Module 4 — AI Agent).
///
/// Chỉ lấy các khối ```bash / ```sh / ```shell / ```console (hoặc fence không
/// ghi ngôn ngữ). Không bao giờ tự chạy — ChatView hiển thị Alert xác nhận,
/// và lệnh nguy hiểm luôn dùng nút destructive màu đỏ.
enum AICommandExtractor {

    /// Các ngôn ngữ được coi là shell.
    static let shellLanguages: Set<String> = [
        "", "bash", "sh", "shell", "zsh", "fish", "console", "terminal", "shell-session"
    ]

    /// Mẫu lệnh nguy hiểm. `>` bắt cả `>` và `>>`; các từ khoá dùng word boundary
    /// để tránh bắt nhầm `rmdir`/`chmodx`.
    static let dangerousPatterns: [(pattern: String, reason: String)] = [
        (#"\brm\b"#, "rm — xoá file/thư mục"),
        (#"\bmv\b"#, "mv — di chuyển/ghi đè file"),
        (#"\bdd\b"#, "dd — ghi đè block thiết bị"),
        (#"\bchmod\b"#, "chmod — thay đổi quyền"),
        (#"\bchown\b"#, "chown — thay đổi chủ sở hữu"),
        (#"\bsudo\b"#, "sudo — leo thang quyền"),
        (#"\bmkfs(\.\w+)?\b"#, "mkfs — định dạng ổ đĩa"),
        (#"\bfdisk\b"#, "fdisk — sửa phân vùng"),
        (#"\bdiskutil\b"#, "diskutil — thao tác ổ đĩa"),
        (#"\bgit\s+reset\s+--hard\b"#, "git reset --hard — mất thay đổi"),
        (#"\bgit\s+clean\s+-[a-z]*f"#, "git clean -f — xoá file chưa track"),
        (#"\|[^|]*\b(sh|bash|zsh)\b"#, "pipe vào shell"),
        (#">"#, "> / >> — chuyển hướng ghi đè file")
    ]

    /// Trả về toàn bộ lệnh shell trong câu trả lời, gộp thành một script.
    static func firstCommand(in text: String) -> AICommand? {
        let blocks = codeBlocks(in: text).filter { shellLanguages.contains($0.language) }
        let bodies = blocks
            .map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return nil }

        let command = bodies.joined(separator: "\n")
        let analysis = analyze(command)
        return AICommand(command: command,
                         language: blocks.first?.language ?? "bash",
                         isDangerous: !analysis.isEmpty,
                         dangerReasons: analysis)
    }

    /// Trả về từng khối lệnh riêng (dùng cho màn hình xem trước / debug).
    static func commands(in text: String) -> [AICommand] {
        codeBlocks(in: text)
            .filter { shellLanguages.contains($0.language) }
            .compactMap { block in
                let body = block.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                let analysis = analyze(body)
                return AICommand(command: body,
                                 language: block.language,
                                 isDangerous: !analysis.isEmpty,
                                 dangerReasons: analysis)
            }
    }

    /// Tìm các lý do khiến lệnh bị coi là nguy hiểm.
    static func analyze(_ command: String) -> [String] {
        var reasons: [String] = []
        for entry in dangerousPatterns {
            if command.range(of: entry.pattern,
                             options: [.regularExpression, .caseInsensitive]) != nil,
               !reasons.contains(entry.reason) {
                reasons.append(entry.reason)
            }
        }
        return reasons
    }

    /// `true` nếu lệnh cần popup xác nhận màu đỏ.
    static func isDangerous(_ command: String) -> Bool {
        !analyze(command).isEmpty
    }

    // MARK: - Fence parsing

    struct Block {
        let language: String
        let body: String
    }

    /// Tách các khối ```…```, bỏ qua fence chưa đóng.
    static func codeBlocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var language = ""
        var buffer: [String] = []
        var inFence = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(Block(language: language,
                                        body: buffer.joined(separator: "\n")))
                    buffer.removeAll()
                    inFence = false
                    language = ""
                } else {
                    let info = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    language = info.components(separatedBy: .whitespaces)
                        .first?.lowercased() ?? ""
                    inFence = true
                }
                continue
            }
            if inFence { buffer.append(line) }
        }
        return blocks
    }
}
