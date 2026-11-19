import Foundation

/// Full container backup: nén .tar.gz, background task, progress bar (PRD Module 3).
final class ContainerArchiver {
    static let shared = ContainerArchiver()
    private let fileManager = FileManager.default

    private init() {}

    /// Nén một thư mục container thành file .tar.gz tại destination.
    /// Trả về URL file backup đã tạo.
    func archive(containerURL: URL, to destination: URL, progress: ((Double) -> Void)? = nil) throws -> URL {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true, attributes: nil)

        let arguments = ["-czf", destination.path, "-C", containerURL.deletingLastPathComponent().path, containerURL.lastPathComponent]
        let command = (["tar"] + arguments).map(CommandRunner.shellQuote).joined(separator: " ")
        let result = CommandRunner.runCommand(command)
        if result.status == 0 {
            progress?(1.0)
            AuditLogger.shared.log(event: .backupCreated(path: destination.path))
            return destination
        }
        let errorMsg = result.output.isEmpty ? "Lỗi nén tar.gz không xác định (mã \(result.status))" : result.output
        throw NSError(domain: "WQTerm.ContainerArchiver", code: Int(result.status),
                      userInfo: [NSLocalizedDescriptionKey: errorMsg])
    }

    /// Liệt kê các file backup đã lưu trong thư mục.
    func listBackups(in directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// Xóa một file backup cũ.
    func deleteBackup(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
