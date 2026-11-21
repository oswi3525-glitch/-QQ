import Foundation

/// Tên gọi tầng nghiệp vụ cho write-ahead snapshot engine (PRD Module 3 & Nguyên tắc 3).
///
/// `SnapshotManager` là implementation; `SnapshotEngine` là API mà UI và các module
/// nguy hiểm (Gestalt) bắt buộc phải gọi **trước khi ghi đè bất kỳ file nào**.
///
/// ```swift
/// do {
///     try SnapshotEngine.createSnapshot(for: gestaltPath)   // thất bại ⇒ ném lỗi
/// } catch {
///     return                                                // huỷ bỏ lệnh ghi
/// }
/// ```
enum SnapshotEngine {
    /// Backup file MobileGestalt gốc — tên gọi ngắn theo PRD.
    ///
    /// Mọi thao tác ghi Gestalt (preset hoặc key đơn) phải gọi hàm này hoặc
    /// `createSnapshot(for:)` TRƯỚC khi ghi; nếu ném lỗi thì huỷ lệnh ghi.
    @discardableResult
    static func createSnapshot() throws -> SnapshotManager.Snapshot {
        guard let url = GestaltManager.shared.locateCacheFile() else {
            throw GestaltError.cacheNotFound(searched: GestaltManager.systemCacheDirectory)
        }
        return try createSnapshot(for: url)
    }

    /// Tạo snapshot cho `url`. **Ném lỗi** nếu không sao lưu được — call site phải huỷ lệnh ghi.
    @discardableResult
    static func createSnapshot(for url: URL) throws -> SnapshotManager.Snapshot {
        try SnapshotManager.shared.createSnapshot(for: url)
    }

    /// Snapshot + ghi nguyên tử trong một bước không thể tách rời.
    @discardableResult
    static func writeAtomically(_ data: Data, to url: URL) throws -> SnapshotManager.Snapshot? {
        try SnapshotManager.shared.writeAtomically(data, to: url)
    }

    /// Danh sách snapshot của một file cụ thể (mới nhất trước).
    static func snapshots(for url: URL) -> [SnapshotManager.Snapshot] {
        SnapshotManager.shared.listSnapshots().filter { $0.originalPath == url.path }
    }

    /// Khôi phục một snapshot về đúng đường dẫn gốc.
    static func restore(_ snapshot: SnapshotManager.Snapshot) throws {
        try SnapshotManager.shared.restore(snapshot)
    }

    /// Tổng dung lượng đang dùng (byte).
    static var totalBytes: UInt64 {
        SnapshotManager.shared.listSnapshots().reduce(0) { $0 + $1.byteCount }
    }

    /// Hạn mức tổng theo PRD.
    static var maxTotalBytes: UInt64 { SnapshotManager.shared.maxTotalBytes }
}
