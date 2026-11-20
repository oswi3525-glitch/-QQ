import Foundation

/// Đọc/ghi file cache MobileGestalt (PRD Module 2 & Module 9).
///
/// Ba nguyên tắc bất biến (không được vi phạm ở bất kỳ call site nào):
/// 1. **Compatibility gate** — iOS 27.3 Beta 2 trở đi thì vô hiệu hoá hoàn toàn.
/// 2. **Write-ahead snapshot** — luôn `SnapshotEngine.createSnapshot(for:)` trước khi ghi;
///    backup thất bại ⇒ ném lỗi ⇒ lệnh ghi bị huỷ.
/// 3. **Atomic rename** — ghi ra file tạm rồi `rename()`, không bao giờ ghi đè trực tiếp.
final class GestaltManager {
    static let shared = GestaltManager()

    /// Đường dẫn chuẩn của MobileGestalt cache trên các bản iOS còn khai thác được.
    static let systemCacheDirectory = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"

    /// Các tên file cache đã gặp trên nhiều bản iOS khác nhau.
    static let cacheFileNames = ["com.apple.MobileGestalt.plist", "com.apple.MobileGestalt"]

    /// Các key hay dùng, gom nhóm theo mục đích để UI hiển thị gợi ý.
    static let commonKeys: [String] = [
        "UserAssignedDeviceName",
        "DeviceName",
        "ProductType",
        "ProductVersion",
        "BuildVersion",
        "SerialNumber",
        "UniqueDeviceID",
        "ModelNumber",
        "HardwareModel",
        "RegionCode",
        "AirplaneMode"
    ]

    /// Snapshot ứng với lần ghi gần nhất — dùng cho nút "Khôi phục" trên UI.
    private(set) var lastSnapshot: SnapshotManager.Snapshot?

    /// Toạ độ file cache MobileGestalt đã phát hiện (nil nếu không tìm được).
    private(set) var locatedPath: String?

    private let fm = FileManager.default
    private let compatibility = IOSCompatibility.shared

    private init() {}

    // MARK: - Discovery

    /// Tìm file cache MobileGestalt thông qua App Group + worse_query.
    ///
    /// Thứ tự thử:
    /// 1. `/var/containers/Shared/SystemGroup/.../Library/Caches/` (đường dẫn chuẩn).
    /// 2. Symlink do worse_query tạo trong App Group container.
    /// 3. Cache đã lưu từ lần chạy trước (nếu file vẫn còn).
    func locateCacheFile() -> URL? {
        if let existing = locatedPath, fm.fileExists(atPath: existing) {
            return URL(fileURLWithPath: existing)
        }

        for directory in candidateDirectories() {
            for name in Self.cacheFileNames {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    locatedPath = candidate.path
                    AuditLogger.shared.log(event: .gestaltRead(path: candidate.path))
                    return candidate
                }
            }
        }

        // Không thấy ở đường dẫn chuẩn: nhờ worse_query dò qua App Group.
        if let discovered = discoverThroughWorseQuery() {
            locatedPath = discovered.path
            AuditLogger.shared.log(event: .gestaltRead(path: discovered.path))
            return discovered
        }
        return nil
    }

    private func candidateDirectories() -> [String] {
        var directories = [Self.systemCacheDirectory]
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wqterm.app") {
            directories.append(group.appendingPathComponent("Library/Caches").path)
            directories.append(group.path)
        }
        return directories
    }

    /// Nhờ worse_query mount container MobileGestalt rồi dò file cache bên trong.
    private func discoverThroughWorseQuery() -> URL? {
        guard compatibility.canWriteGestalt else { return nil }
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wqterm.app") else {
            return nil
        }
        do {
            let container = try WorseQuery.shared.mountContainer(for: "com.apple.mobilegestaltcache")
            let caches = container.appendingPathComponent("Library/Caches")
            for name in Self.cacheFileNames {
                let candidate = caches.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            // WorseQuery mount vào group container — thử luôn thư mục gốc.
            for name in Self.cacheFileNames {
                let candidate = group.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        } catch {
            AuditLogger.shared.log(event: .sandboxMountFailed(bundleID: "com.apple.mobilegestaltcache",
                                                             error: error.localizedDescription))
        }
        return nil
    }

    // MARK: - Read

    /// Đọc toàn bộ plist dưới dạng dictionary (chỉ các giá trị scalar).
    func read() throws -> [String: Any] {
        let url = try requireCacheFile()
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw GestaltError.invalidFormat(path: url.path)
        }
        return dictionary
    }

    /// Danh sách tham số để hiển thị lên UI, đã sắp xếp.
    /// Các key phổ biến (`commonKeys`) luôn nằm đầu danh sách.
    func readableParameters() throws -> [GestaltParameter] {
        let dictionary = try read()
        return dictionary.keys
            .sorted { lhs, rhs in
                let lhsRank = Self.commonKeys.firstIndex(of: lhs) ?? Int.max
                let rhsRank = Self.commonKeys.firstIndex(of: rhs) ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { GestaltParameter(key: $0, value: Self.describe(dictionary[$0])) }
    }

    /// Rút gọn giá trị bất kỳ thành chuỗi hiển thị được (không crash với type lạ).
    static func describe(_ value: Any?) -> String {
        guard let value else { return "(nil)" }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let data = value as? Data { return "<\(data.count) bytes>" }
        if let array = value as? [Any] { return array.map { describe($0) }.joined(separator: ", ") }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted()
                .map { "\($0): \(describe(dictionary[$0]))" }
                .joined(separator: ", ")
        }
        return String(describing: value)
    }

    // MARK: - Write (snapshot → atomic rename)

    /// Ghi một tham số vào MobileGestalt cache.
    ///
    /// Luồng bắt buộc:
    /// 1. Kiểm tra compatibility — 27.3 Beta 2 trở đi thì ném `GestaltError.disabled`.
    /// 2. `SnapshotEngine.createSnapshot(for:)` — **thất bại thì dừng, không ghi**.
    /// 3. Ghi ra file tạm cùng thư mục → `fsync` → `rename()`.
    ///
    /// - Returns: Snapshot vừa tạo (để UI hiển thị đường dẫn khôi phục).
    @discardableResult
    func write(key: String, value: String) throws -> SnapshotManager.Snapshot {
        // 1. Compatibility gate.
        guard compatibility.canWriteGestalt else {
            let reason = compatibility.gestaltBlockReason ?? "Không hỗ trợ trên phiên bản iOS này."
            AuditLogger.shared.log(event: .gestaltWriteBlocked(reason: reason))
            throw GestaltError.disabled(reason: reason)
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GestaltError.emptyKey
        }

        let url = try requireCacheFile()

        // 2. Write-ahead snapshot — BẮT BUỘC, thất bại thì huỷ lệnh ghi.
        let snapshot: SnapshotManager.Snapshot
        do {
            snapshot = try SnapshotEngine.createSnapshot(for: url)
        } catch {
            AuditLogger.shared.log(event: .gestaltWriteBlocked(reason: error.localizedDescription))
            throw GestaltError.snapshotFailed(reason: error.localizedDescription)
        }

        // 3. Sửa plist trong bộ nhớ rồi ghi nguyên tử.
        var dictionary = try read()
        dictionary[key] = value
        let updated = try PropertyListSerialization.data(fromPropertyList: dictionary,
                                                        format: .binary,
                                                        options: 0)
        do {
            try AtomicFileWriter.write(updated, to: url)
        } catch {
            throw GestaltError.writeFailed(reason: error.localizedDescription)
        }

        lastSnapshot = snapshot
        AuditLogger.shared.log(event: .gestaltWrite(key: key))
        return snapshot
    }

    /// Khôi phục lại file Gestalt từ snapshot đã tạo trước lần ghi gần nhất.
    func restoreLastSnapshot() throws {
        guard let snapshot = lastSnapshot else { throw GestaltError.noSnapshot }
        let destination = URL(fileURLWithPath: snapshot.originalPath)
        let data = try Data(contentsOf: snapshot.snapshotURL)
        try AtomicFileWriter.write(data, to: destination)
        AuditLogger.shared.log(event: .gestaltRestored(path: destination.path))
    }

    // MARK: - Helpers

    /// Trả về URL cache hoặc ném lỗi mô tả rõ ràng.
    private func requireCacheFile() throws -> URL {
        guard let url = locateCacheFile() else {
            throw GestaltError.cacheNotFound(searched: Self.systemCacheDirectory)
        }
        return url
    }
}

// MARK: - Models

/// Một tham số MobileGestalt hiển thị trên UI.
struct GestaltParameter: Identifiable, Hashable {
    let key: String
    let value: String

    var id: String { key }
}

// MARK: - Errors

enum GestaltError: LocalizedError {
    case disabled(reason: String)
    case cacheNotFound(searched: String)
    case invalidFormat(path: String)
    case emptyKey
    case snapshotFailed(reason: String)
    case writeFailed(reason: String)
    case noSnapshot

    var errorDescription: String? {
        switch self {
        case .disabled(let reason):
            return "Tính năng Gestalt bị vô hiệu hoá. \(reason)"
        case .cacheNotFound(let searched):
            return "Không tìm thấy MobileGestalt cache. Đã thử: \(searched)"
        case .invalidFormat(let path):
            return "File Gestalt không phải property list hợp lệ: \(path)"
        case .emptyKey:
            return "Tên tham số không được để trống."
        case .snapshotFailed(let reason):
            return "Backup thất bại — đã HUỶ lệnh ghi để bảo vệ dữ liệu gốc. Lý do: \(reason)"
        case .writeFailed(let reason):
            return "Ghi file Gestalt thất bại: \(reason)"
        case .noSnapshot:
            return "Chưa có bản backup nào trong phiên này để khôi phục."
        }
    }
}

