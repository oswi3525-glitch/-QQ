import Foundation

/// Write-ahead snapshot engine (PRD Module 3 & Nguyên tắc 3).
///
/// Nguyên tắc: **không bao giờ ghi đè một file mà chưa có bản sao lưu thành công**.
/// Mọi lệnh ghi đi qua `SnapshotManager.shared.createSnapshot(for:)` trước; nếu hàm này
/// ném lỗi thì lệnh ghi phải bị huỷ bỏ.
final class SnapshotManager {
    static let shared = SnapshotManager()

    enum SnapshotError: LocalizedError {
        case sourceMissing(path: String)
        case fileTooLarge(path: String, bytes: UInt64, limit: UInt64)
        case copyFailed(path: String, underlying: String)
        case quotaExceeded(limit: UInt64)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let path):
                return "Không tìm thấy file để backup: \(path)"
            case .fileTooLarge(let path, let bytes, let limit):
                return "File quá lớn để backup (\(Self.label(bytes)) > \(Self.label(limit))): \(path)"
            case .copyFailed(let path, let underlying):
                return "Backup thất bại cho \(path): \(underlying)"
            case .quotaExceeded(let limit):
                return "Đã vượt hạn mức snapshot (\(Self.label(limit)))."
            }
        }

        private static func label(_ bytes: UInt64) -> String {
            BuiltinShell.sizeLabel(bytes)
        }
    }

    /// Một bản snapshot đã tạo.
    struct Snapshot: Identifiable, Equatable {
        let id = UUID()
        let originalPath: String
        let snapshotURL: URL
        let createdAt: Date
        let byteCount: UInt64
    }

    private let fm = FileManager.default

    /// Giới hạn theo PRD: tổng ≤ 2GB, mỗi file < 100MB.
    let maxTotalBytes: UInt64 = 2 * 1024 * 1024 * 1024
    let maxFileBytes: UInt64 = 100 * 1024 * 1024

    private init() {}

    /// Thư mục gốc chứa snapshot: `Documents/.terminal/backups/snapshots`.
    var snapshotsRoot: URL {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(".terminal/backups/snapshots", isDirectory: true)
    }

    // MARK: - Create

    /// Tạo snapshot từ vị trí tĩnh — API mà tầng UI / Gestalt sử dụng:
    /// `SnapshotEngine.createSnapshot(for: url)`.
    ///
    /// - Important: Hàm này **ném lỗi** nếu không sao lưu được. Mọi call site
    ///   ghi dữ liệu bắt buộc phải bắt lỗi và huỷ bỏ thao tác ghi.
    @discardableResult
    static func createSnapshot(for url: URL) throws -> Snapshot {
        try shared.createSnapshot(for: url)
    }

    /// Tạo snapshot cho một file **trước khi ghi đè**.
    ///
    /// - Ném lỗi nếu không thể sao lưu ⇒ caller phải huỷ bỏ thao tác ghi.
    /// - Trả về `Snapshot` mô tả bản sao đã tạo.
    @discardableResult
    func createSnapshot(for url: URL) throws -> Snapshot {
        guard fm.fileExists(atPath: url.path) else {
            throw SnapshotError.sourceMissing(path: url.path)
        }

        let attributes = try fm.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount <= maxFileBytes else {
            throw SnapshotError.fileTooLarge(path: url.path, bytes: byteCount, limit: maxFileBytes)
        }

        let directory = try makeSnapshotDirectory()
        let destination = directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)

        do {
            try fm.copyItem(at: url, to: destination)
        } catch {
            throw SnapshotError.copyFailed(path: url.path, underlying: error.localizedDescription)
        }

        let snapshot = Snapshot(originalPath: url.path,
                                snapshotURL: destination,
                                createdAt: Date(),
                                byteCount: byteCount)

    // Ghi metadata để Restore biết file gốc nằm ở đâu. Nếu không ghi được
    // manifest thì snapshot này vô dụng → xoá luôn, không để backup rác.
    do {
        try writeManifest(for: snapshot)
    } catch {
        discard(snapshot)
        throw SnapshotError.copyFailed(path: url.path,
                                       underlying: "Không ghi được manifest: \(error.localizedDescription)")
    }
    enforceQuota()
        AuditLogger.shared.log(event: .writeAheadSnapshot(command: "createSnapshot", target: url.path))
        return snapshot
    }

    /// Tương thích API cũ (CommandExecutor / PlistViewer / Restore).
    /// Trả về `true` nếu đã backup thành công.
    @discardableResult
    func createWriteAheadSnapshot(for command: String, cwd: String) -> Bool {
        guard let target = Self.writeTarget(in: command, cwd: cwd) else { return false }
        guard fm.fileExists(atPath: target.path) else { return false }
        do {
            try createSnapshot(for: target)
            return true
        } catch {
            AuditLogger.shared.log(event: .writeAheadSnapshot(command: command, target: target.path))
            return false
        }
    }

    /// Ghi file một cách an toàn: backup trước, rồi ghi nguyên tử.
    ///
    /// Đây là API duy nhất mà UI nên dùng để sửa nội dung file — nó đảm bảo
    /// hai bước (snapshot → atomic write) không thể tách rời.
    @discardableResult
    func writeAtomically(_ data: Data, to url: URL) throws -> Snapshot? {
        // Bước 1: bắt buộc backup nếu file đã tồn tại.
        let snapshot = fm.fileExists(atPath: url.path) ? try createSnapshot(for: url) : nil

        // Bước 2: ghi ra file tạm rồi rename() đè lên file gốc.
        try AtomicFileWriter.write(data, to: url)
        AuditLogger.shared.log(event: .fileWrite(path: url.path))
        return snapshot
    }

    // MARK: - List / restore

    /// Danh sách snapshot, mới nhất trước.
    func listSnapshots() -> [Snapshot] {
        guard let directories = try? fm.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return directories
            .filter { isDirectory($0) }
            .flatMap { directory -> [Snapshot] in
                let manifest = readManifest(in: directory)
                let files = (try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                return files
                    .filter { !$0.lastPathComponent.hasSuffix(".json") }
                    .map { file in
                        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        let created = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? Date.distantPast
                        return Snapshot(originalPath: manifest[file.lastPathComponent] ?? file.lastPathComponent,
                                        snapshotURL: file,
                                        createdAt: created,
                                        byteCount: UInt64(size))
                    }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Khôi phục một file từ snapshot về đúng đường dẫn gốc.
    func restore(_ snapshot: Snapshot) throws {
        let destination = URL(fileURLWithPath: snapshot.originalPath)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true, attributes: nil)
        let data = try Data(contentsOf: snapshot.snapshotURL)
        try AtomicFileWriter.write(data, to: destination)
        AuditLogger.shared.log(event: .backupRestored(path: destination.path))
    }

    func deleteSnapshotFile(at url: URL) {
        try? fm.removeItem(at: url)
        // Dọn thư mục rỗng sau khi xoá file cuối cùng.
        let parent = url.deletingLastPathComponent()
        if let remaining = try? fm.contentsOfDirectory(atPath: parent.path), remaining.isEmpty {
            try? fm.removeItem(at: parent)
        }
    }

    /// Xoá hoàn toàn một snapshot (kể cả manifest) khi thao tác ghi thất bại,
    /// để không để lại backup rác cho một lần ghi không bao giờ xảy ra.
    func discard(_ snapshot: Snapshot) {
        let directory = snapshot.snapshotURL.deletingLastPathComponent()
        try? fm.removeItem(at: snapshot.snapshotURL)
        try? fm.removeItem(at: directory.appendingPathComponent(".manifest.json"))
        if let remaining = try? fm.contentsOfDirectory(atPath: directory.path), remaining.isEmpty {
            try? fm.removeItem(at: directory)
        }
    }

    // MARK: - Private

    private func makeSnapshotDirectory() throws -> URL {
        try fm.createDirectory(at: snapshotsRoot, withIntermediateDirectories: true, attributes: nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4))
        let directory = snapshotsRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func writeManifest(for snapshot: Snapshot) throws {
        let directory = snapshot.snapshotURL.deletingLastPathComponent()
        let manifestURL = directory.appendingPathComponent(".manifest.json", isDirectory: false)
        let payload: [String: String] = [snapshot.snapshotURL.lastPathComponent: snapshot.originalPath]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: manifestURL, options: .atomic)
    }

    private func readManifest(in directory: URL) -> [String: String] {
        let manifestURL = directory.appendingPathComponent(".manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Xoá các snapshot cũ nhất khi tổng dung lượng vượt 2GB.
    private func enforceQuota() {
        let snapshots = listSnapshots().sorted { $0.createdAt < $1.createdAt }
        var total = snapshots.reduce(UInt64(0)) { $0 + $1.byteCount }
        var index = 0
        while total > maxTotalBytes, index < snapshots.count {
            let oldest = snapshots[index]
            deleteSnapshotFile(at: oldest.snapshotURL)
            total -= min(total, oldest.byteCount)
            index += 1
        }
    }

    // MARK: - Target extraction

    /// Tìm file đích của một lệnh ghi (`cmd > file`, `cp a b`, `rm x`...).
    /// Trả về `nil` nếu không xác định được một file đơn lẻ.
    static func writeTarget(in command: String, cwd: String) -> URL? {

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = URL(fileURLWithPath: cwd)

        func resolve(_ path: String) -> URL {
            path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : base.appendingPathComponent(path)
        }

        // `cmd > file` / `cmd >> file`
        for token in [">>", ">"] {
            if let range = trimmed.range(of: token) {
                let tail = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first
                if let tail, !tail.isEmpty { return resolve(String(tail)) }
            }
        }

        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let command0 = tokens.first else { return nil }
        switch command0 {
        case "cp", "mv":
            guard tokens.count >= 3 else { return nil }
            return resolve(tokens[tokens.count - 1])
        case "rm", "rmdir", "touch":
            guard tokens.count >= 2 else { return nil }
            return resolve(tokens[tokens.count - 1])
        default:
            return nil
        }
    }
}
