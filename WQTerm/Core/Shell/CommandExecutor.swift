import Foundation

/// Thực thi lệnh shell và hook write-ahead snapshot trước các lệnh ghi (PRD Module 1 & Module 3).
/// Trên iOS, lệnh được chuyển qua CommandRunner.
final class CommandExecutor {
    static let shared = CommandExecutor()
    private let safeMode = SafeMode.shared
    private let fileManager = FileManager.default

    private init() {}

    /// Các từ khóa lệnh ghi cần trigger write-ahead backup trước khi chạy.
    private let writeKeywords: [String] = [
        ">", ">>", "rm ", "mv ", "cp ", "sed -i", "tee ", "dd ", "mkfs", "fdisk"
    ]

    /// Thực thi một lệnh shell trong thư mục làm việc chỉ định.
    /// Trả về (stdout, stderr). Nếu SafeMode bật và là lệnh ghi → từ chối.
    func execute(_ command: String, in workingDirectory: URL) -> (output: String, error: String?) {
        // SafeMode: chặn toàn bộ lệnh ghi
        if let blockReason = safeMode.guardWrite(command: command) {
            AuditLogger.shared.log(event: .fileWrite(path: workingDirectory.path))
            return ("", blockReason)
        }

        // Write-ahead snapshot: sao chép file đích trước khi lệnh ghi chạy.
        // Nếu backup thất bại → huỷ bỏ lệnh ghi (PRD Nguyên tắc 3).
        if isWriteCommand(command) {
            let backedUp = SnapshotManager.shared.createWriteAheadSnapshot(for: command,
                                                                          cwd: workingDirectory.path)
            let targetExists = SnapshotManager.writeTarget(in: command, cwd: workingDirectory.path)
                .map { fileManager.fileExists(atPath: $0.path) } ?? false
            if targetExists && !backedUp {
                return ("", "Huỷ lệnh ghi: không tạo được snapshot write-ahead cho file đích.")
            }
        }

        // Thực thi lệnh qua ios_system.
        let result = runShellCommand(command: command, workingDirectory: workingDirectory.path)

        AuditLogger.shared.log(event: .fileWrite(path: workingDirectory.path))
        return result
    }

    private func isWriteCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return writeKeywords.contains { lower.contains($0) }
    }

    // MARK: - Command execution

    private func runShellCommand(command: String, workingDirectory: String) -> (output: String, error: String?) {
        let command = "cd \(CommandRunner.shellQuote(workingDirectory)) && \(command)"
        let result = CommandRunner.runCommand(command)
        if result.status == 0 {
            return (result.output, nil)
        }
        return ("", result.output.isEmpty ? "Lệnh thoát với mã \(result.status)" : result.output)
    }
}
