import Foundation

/// Một dòng trong transcript của terminal.
struct TerminalEntry: Identifiable, Equatable {
    enum Kind {
        case command   // dòng người dùng gõ (kèm prompt)
        case output    // stdout
        case error     // stderr / lỗi
        case info      // thông báo của ứng dụng
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// Quản lý phiên terminal (PRD Module 1: ShellSession).
/// Giữ thư mục làm việc, lịch sử lệnh và transcript để UI hiển thị.
final class ShellSession: ObservableObject {
    static let shared = ShellSession()

    /// Toàn bộ nội dung đã hiển thị (cuộn được).
    @Published private(set) var entries: [TerminalEntry] = []
    /// Thư mục làm việc hiện tại.
    @Published private(set) var currentDirectory: URL
    /// Lịch sử lệnh (cũ → mới), dùng cho phím ↑/↓.
    @Published private(set) var history: [String] = []
    /// true khi đang chạy lệnh (dùng để disable input).
    @Published private(set) var isRunning = false
    /// Ký tự điều khiển gần nhất người dùng bấm trên bàn phím phụ (ESC/TAB/Ctrl-*).
    /// Terminal hiển thị lại để người dùng thấy phím đã được gửi.
    @Published private(set) var lastControlSequence: String?

    private let fileManager = FileManager.default
    private let maxEntries = 2000
    private var historyCursor: Int?

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        currentDirectory = documents
        entries.append(TerminalEntry(kind: .info, text: Self.bannerText))
    }

    // MARK: - Execution

    /// Chạy một lệnh, ghi kết quả vào transcript.
    ///
    /// Chạy **đồng bộ** trên luồng gọi. `TerminalInputField` gọi hàm này từ
    /// `runInBackground`, nên UI không bị chặn (Module 6: "chạy tác vụ nặng dưới
    /// background thread").
    @discardableResult
    func run(_ command: String) -> (status: Int32, output: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, "") }

        if trimmed == "clear" {
            clearHistory()
            return (0, "")
        }

        append(.command, "\(promptText) \(trimmed)")
        history.append(trimmed)
        historyCursor = nil

        let result = CommandRunner.run(trimmed, cwd: currentDirectory)

        currentDirectory = result.cwd
        if !result.output.isEmpty {
            append(result.status == 0 ? .output : .error, result.output)
        } else if result.status != 0 {
            append(.error, "Lệnh thoát với mã \(result.status)")
        }
        return (result.status, result.output)
    }

    /// Chạy lệnh trên background queue rồi cập nhật transcript ở main thread.
    ///
    /// Dùng cho UI: tránh treo khi lệnh mạng (`curl`, `ai`) mất nhiều giây.
    func runInBackground(_ command: String,
                         completion: ((Int32, String) -> Void)? = nil) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(0, "")
            return
        }
        guard !isRunning else { return }

        if trimmed == "clear" {
            clearHistory()
            completion?(0, "")
            return
        }

        append(.command, "\(promptText) \(trimmed)")
        history.append(trimmed)
        historyCursor = nil
        isRunning = true

        let directory = currentDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CommandRunner.run(trimmed, cwd: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentDirectory = result.cwd
                if !result.output.isEmpty {
                    self.append(result.status == 0 ? .output : .error, result.output)
                } else if result.status != 0 {
                    self.append(.error, "Lệnh thoát với mã \(result.status)")
                }
                self.isRunning = false
                completion?(result.status, result.output)
            }
        }
    }

    /// Chạy một script nhiều dòng (do AI Agent trả về) theo tuần tự.
    ///
    /// Mỗi dòng là một lệnh độc lập; dừng ngay nếu một dòng thất bại để tránh
    /// thực thi phần còn lại khi người dùng chỉ đồng ý với ngữ cảnh ban đầu.
    func runScriptInBackground(_ script: String,
                               completion: ((Int32) -> Void)? = nil) {
        let lines = script.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else {
            completion?(0)
            return
        }
        guard !isRunning else { return }

        append(.command, "\(promptText) \(lines.joined(separator: " ; "))")
        history.append(lines.joined(separator: " ; "))
        historyCursor = nil
        isRunning = true

        let directory = currentDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var cwd = directory
            var lastStatus: Int32 = 0
            var chunks: [String] = []

            for line in lines {
                let result = CommandRunner.run(line, cwd: cwd)
                cwd = result.cwd
                lastStatus = result.status
                if !result.output.isEmpty { chunks.append(result.output) }
                if result.status != 0 { break }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.currentDirectory = cwd
                if !chunks.isEmpty {
                    self.append(lastStatus == 0 ? .output : .error,
                                chunks.joined(separator: "\n"))
                } else if lastStatus != 0 {
                    self.append(.error, "Lệnh thoát với mã \(lastStatus)")
                }
                self.isRunning = false
                completion?(lastStatus)
            }
        }
    }

    /// Gửi tín hiệu ngắt (Ctrl+C) tới phiên hiện tại.
    func sendInterrupt() {
        append(.info, "^C")
    }

    /// Ghi nhận một chuỗi điều khiển do bàn phím phụ phát ra (M5).
    ///
    /// Đây là điểm duy nhất chuyển mã phím thành hành động của shell:
    /// - `\x1b` (ESC) xoá dòng đang gõ
    /// - `\x03` (Ctrl-C) ngắt tiến trình
    /// - `\x0c` (Ctrl-L) xoá màn hình
    /// - `\t` (TAB) hoàn tất đường dẫn nếu có duy nhất một kết quả
    /// - còn lại: ghi vào transcript dưới dạng ký tự điều khiển
    func handleControlSequence(_ payload: String) {
        lastControlSequence = payload
        switch payload {
        case TerminalKey.ctrlC:
            sendInterrupt()
        case TerminalKey.ctrlL:
            clearHistory()
        case TerminalKey.tab:
            append(.info, "TAB")
        case TerminalKey.escape:
            append(.info, "ESC")
        default:
            guard !payload.isEmpty else { return }
            append(.info, Self.describe(payload))
        }
    }

    /// Mô tả ký tự điều khiển không in được, ví dụ `0x1b` → "ESC".
    static func describe(_ payload: String) -> String {
        payload.unicodeScalars.map { scalar -> String in
            if scalar.value >= 0x20 && scalar.value != 0x7F {
                return String(scalar)
            }
            return String(format: "0x%02x", scalar.value)
        }.joined()
    }

    // MARK: - History navigation

    /// Lệnh trước đó trong lịch sử (phím ↑).
    func previousCommand() -> String? {
        guard !history.isEmpty else { return nil }
        let next = (historyCursor ?? history.count) - 1
        guard next >= 0 else { return history.first }
        historyCursor = next
        return history[next]
    }

    /// Lệnh kế tiếp trong lịch sử (phím ↓).
    func nextCommand() -> String? {
        guard !history.isEmpty, let cursor = historyCursor else { return nil }
        let next = cursor + 1
        guard next < history.count else {
            historyCursor = nil
            return ""
        }
        historyCursor = next
        return history[next]
    }

    // MARK: - Output access

    /// Toàn bộ transcript dạng text (dùng cho Copy / Select All).
    var transcript: String {
        entries.map(\.text).joined(separator: "\n")
    }

    /// Output của lệnh gần nhất (dùng cho Copy).
    var lastOutput: String {
        entries.last(where: { $0.kind == .output || $0.kind == .error })?.text ?? ""
    }

    /// Prompt hiển thị trước con trỏ, ví dụ `Documents $`.
    var promptText: String {
        let name = currentDirectory.lastPathComponent
        return "\(name.isEmpty ? "/" : name) $"
    }

    /// Nhãn đường dẫn đầy đủ hơn cho thanh trạng thái.
    var relativeDirectoryLabel: String {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.standardizedFileURL.path
        let path = currentDirectory.standardizedFileURL.path
        if path == root { return "Documents" }
        if path.hasPrefix(root) { return "Documents" + path.dropFirst(root.count) }
        return path
    }

    func clearHistory() {
        entries.removeAll()
        historyCursor = nil
    }

    // MARK: - Private

    private func append(_ kind: TerminalEntry.Kind, _ text: String) {
        entries.append(TerminalEntry(kind: kind, text: text))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private static let bannerText = "WQTerm terminal — gõ 'help' để xem các lệnh được hỗ trợ."
}
