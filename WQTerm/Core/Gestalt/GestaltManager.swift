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

    /// Các preset có sẵn (tham khảo GestaltX / GestaltEdit).
    /// Tên key là tên cộng đồng thường gặp; một số bản iOS có thể đổi key —
    /// người dùng luôn có nút "Khôi phục snapshot" nếu kết quả không như ý.
    enum Preset: String, CaseIterable, Identifiable {
        case dynamicIsland
        case alwaysOnDisplay
        case actionButton
        case cameraControl
        case collisionSOS

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dynamicIsland: return "Dynamic Island"
            case .alwaysOnDisplay: return "Always-On Display (AOD)"
            case .actionButton: return "Action Button"
            case .cameraControl: return "Camera Control"
            case .collisionSOS: return "Collision SOS"
            }
        }

        var systemImage: String {
            switch self {
            case .dynamicIsland: return "rectangle.on.rectangle"
            case .alwaysOnDisplay: return "sun.max"
            case .actionButton: return "switch.2"
            case .cameraControl: return "camera"
            case .collisionSOS: return "phone.fill"
            }
        }

        var detail: String {
            switch self {
            case .dynamicIsland: return "Bật/tắt và đổi layout (thanh/pill)."
            case .alwaysOnDisplay: return "Bật/tắt AOD, độ sáng và hiệu ứng."
            case .actionButton: return "Gán chức năng cho nút tác vụ."
            case .cameraControl: return "Bật/tắt và cấu hình nút Camera Control."
            case .collisionSOS: return "Gọi khẩn cấp khi phát hiện va chạm."
            }
        }

        /// Giá trị ghi khi bật preset.
        var enabledValues: [String: String] {
            switch self {
            case .dynamicIsland:
                return ["DynamicIsland": "1", "DeviceSupportsDynamicIsland": "1", "DynamicIslandType": "2"]
            case .alwaysOnDisplay:
                return ["AlwaysOnDisplay": "1", "AODAlwaysOn": "1", "AlwaysOnDisplayBrightness": "100"]
            case .actionButton:
                return ["ActionButton": "1", "ActionButtonFunction": "silent"]
            case .cameraControl:
                return ["CameraControl": "1", "CameraControlEnabled": "1", "CameraControlFunction": "zoom"]
            case .collisionSOS:
                return ["CollisionSOS": "1", "CollisionDetectionEnabled": "1"]
            }
        }

        /// Giá trị ghi khi tắt preset (vẫn giữ cấu hình phụ, chỉ tắt công tắc chính).
        var disabledValues: [String: String] {
            Dictionary(uniqueKeysWithValues: enabledValues.keys.map { ($0, "0") })
        }
    }

    /// Snapshot ứng với lần ghi gần nhất — dùng cho nút "Khôi phục" trên UI.
    private(set) var lastSnapshot: SnapshotManager.Snapshot?

    /// Toạ độ file cache MobileGestalt đã phát hiện (nil nếu không tìm được).
    private(set) var locatedPath: String?

    private let fm = FileManager.default
    private let compatibility = IOSCompatibility.shared
    private static var writeExtensionRequested = false

    private init() {}

    /// Thử xin sandbox extension read-write bằng cơ chế worse_query sẵn có
    /// (SandboxAccess dùng đúng signature 3 tham số). Không giả lập quyền —
    /// sau đó vẫn phải probe ghi thực tế mới được phép ghi.
    private func ensureWriteExtension(for url: URL) {
        guard !Self.writeExtensionRequested else { return }
        Self.writeExtensionRequested = true
        SandboxAccess.grantReadWrite(to: url.resolvingSymlinksInPath().path)
    }

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

    /// Báo cáo khả năng truy cập — dùng cho UI chẩn đoán, KHÔNG được suy ra
    /// rằng "đọc được" thì "ghi được".
    struct AccessReport {
        let cacheFound: Bool
        let readOK: Bool
        let writable: Bool
        let writeErrorCode: Int32?
        let hasSystemGroupEntitlement: Bool

        var summary: String {
            if !cacheFound { return "Không tìm thấy file cache" }
            if !readOK { return "Đọc thất bại" }
            if writable { return "Đọc/ghi OK" }
            return hasSystemGroupEntitlement
                ? "Chỉ có quyền đọc — kernel từ chối ghi (errno \(writeErrorCode.map(String.init) ?? "?"))"
                : "Chỉ có quyền đọc — thiếu entitlement systemgroup (errno \(writeErrorCode.map(String.init) ?? "?"))"
        }
    }

    /// Kiểm tra thực tế: đọc thử + probe tạo file tạm trong thư mục cache.
    func accessReport() -> AccessReport {
        guard let url = locateCacheFile() else {
            return AccessReport(cacheFound: false, readOK: false, writable: false,
                                writeErrorCode: nil, hasSystemGroupEntitlement: false)
        }
        let readable = (try? read()) != nil
        ensureWriteExtension(for: url)
        let directory = url.resolvingSymlinksInPath().deletingLastPathComponent()
        let code = AtomicFileWriter.writabilityError(in: directory)
        let hasGroup = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "systemgroup.com.apple.mobilegestaltcache"
        ) != nil
        return AccessReport(cacheFound: true, readOK: readable, writable: code == nil,
                            writeErrorCode: code, hasSystemGroupEntitlement: hasGroup)
    }

    /// Đọc toàn bộ plist dưới dạng dictionary. Lỗi I/O và lỗi định dạng được
    /// phân biệt rõ ràng để UI không gộp chung thành "Không thể đọc Gestalt".
    func read() throws -> [String: Any] {
        let url = try requireCacheFile()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GestaltError.readFailed(reason: error.localizedDescription)
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw GestaltError.invalidFormat(path: url.path)
        }
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

    // MARK: - Presets

    /// Trạng thái bật/tắt hiện tại của các preset (đọc từ cache, không ghi).
    func presetStates() -> [Preset: Bool] {
        guard let dictionary = try? read() else { return [:] }
        var states: [Preset: Bool] = [:]
        for preset in Preset.allCases {
            let primaryKey = Array(preset.enabledValues.keys).first ?? preset.rawValue
            let raw = Self.describe(dictionary[primaryKey]).lowercased()
            states[preset] = ["1", "true", "yes", "on"].contains(raw)
        }
        return states
    }

    /// Áp dụng một preset (bật hoặc tắt) qua cùng pipeline an toàn.
    @discardableResult
    func apply(preset: Preset, enabled: Bool) throws -> GestaltWriteOutcome {
        let values = enabled ? preset.enabledValues : preset.disabledValues
        return try performWrite(values, label: preset.rawValue)
    }

    // MARK: - Safe write pipeline

    /// Ghi một tham số vào MobileGestalt cache.
    ///
    /// Pipeline: gate → preflight quyền → snapshot → đọc → sửa → ghi đã xác minh
    /// → đọc lại so sánh → rollback nếu sai → dọn snapshot rác nếu không đổi gì.
    @discardableResult
    func write(key: String, value: String) throws -> GestaltWriteOutcome {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GestaltError.emptyKey }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GestaltError.invalidValue(reason: "Giá trị không được để trống.")
        }
        guard trimmedKey.utf8.count <= 512, value.utf8.count <= 4096 else {
            throw GestaltError.invalidValue(reason: "Khoá hoặc giá trị quá dài.")
        }
        return try performWrite([trimmedKey: value], label: trimmedKey)
    }

    /// Trái tim của luồng ghi an toàn. Mọi lỗi đều có nhánh xử lý riêng.
    private func performWrite(_ changes: [String: String], label: String) throws -> GestaltWriteOutcome {
        // 1. Compatibility gate (chính sách, không phải quyền truy cập).
        guard compatibility.canWriteGestalt else {
            let reason = compatibility.gestaltBlockReason ?? "Không hỗ trợ trên phiên bản iOS này."
            AuditLogger.shared.log(event: .gestaltWriteBlocked(reason: reason))
            throw GestaltError.disabled(reason: reason)
        }

        let url = try requireCacheFile()

        // 2. Preflight QUYỀN GHI trước khi tạo bất kỳ backup nào.
        //    Đọc được file KHÔNG có nghĩa là ghi được (đây là nguyên nhân errno 1).
        ensureWriteExtension(for: url)
        let directory = url.resolvingSymlinksInPath().deletingLastPathComponent()
        if let code = AtomicFileWriter.writabilityError(in: directory) {
            let reason = "errno \(code) — kernel từ chối tạo file tạm tại thư mục cache. "
                + "Thiết bị này chỉ cho phép đọc MobileGestalt; dữ liệu gốc được giữ nguyên."
            AuditLogger.shared.log(event: .gestaltWriteBlocked(reason: "permission \(code)"))
            throw GestaltError.notWritable(reason: reason)
        }

        // 3. Backup write-ahead (bắt buộc).
        let snapshot: SnapshotManager.Snapshot
        do {
            snapshot = try SnapshotEngine.createSnapshot()
        } catch {
            AuditLogger.shared.log(event: .gestaltWriteBlocked(reason: error.localizedDescription))
            throw GestaltError.snapshotFailed(reason: error.localizedDescription)
        }

        // Snapshot chỉ được giữ lại khi ghi thành công. Mọi lỗi trước đó xoá nó.
        var keepSnapshot = false
        defer {
            if !keepSnapshot { SnapshotManager.shared.discard(snapshot) }
        }

        // 4. Đọc nội dung gốc (đã xử lý lỗi đọc trong read()).
        let original = try read()
        var updated = original
        for (key, value) in changes { updated[key] = value }

        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: updated,
                                                      format: .binary, options: 0)
        } catch {
            throw GestaltError.invalidValue(reason: error.localizedDescription)
        }

        // 5. Ghi an toàn + xác minh nội dung trong AtomicFileWriter.
        do {
            try AtomicFileWriter.write(data, to: url)
        } catch let writeError as AtomicFileWriter.WriteError {
            switch writeError.category {
            case .permission:
                throw GestaltError.notWritable(reason: writeError.localizedDescription)
            case .verification:
                throw GestaltError.verificationFailed(reason: writeError.localizedDescription)
            case .io:
                throw GestaltError.writeFailed(reason: writeError.localizedDescription)
            }
        } catch {
            throw GestaltError.writeFailed(reason: error.localizedDescription)
        }

        // 6. Đọc lại để xác nhận từng khoá thay đổi đúng giá trị.
        var mismatch: String?
        do {
            let after = try read()
            mismatch = changes.first { key, expected in
                Self.describe(after[key]) != expected
            }?.key
        } catch {
            mismatch = "toàn bộ file (đọc lại thất bại: \(error.localizedDescription))"
        }

        if let mismatch {
            // 7. Rollback tự động về bản gốc.
            do {
                let backup = try Data(contentsOf: snapshot.snapshotURL)
                try AtomicFileWriter.write(backup, to: url)
                let restored = try read()
                guard restored.count == original.count else {
                    throw GestaltError.verificationFailed(reason: "rollback không khớp số khoá")
                }
                for (key, expected) in original where Self.describe(restored[key]) != Self.describe(expected) {
                    throw GestaltError.verificationFailed(reason: "rollback sai khoá \(key)")
                }
            } catch {
                // Giữ snapshot lại để người dùng còn đường khôi phục thủ công.
                keepSnapshot = true
                lastSnapshot = snapshot
                throw GestaltError.rollbackFailed(reason: "\(error.localizedDescription). "
                    + "Snapshot vẫn được giữ lại để khôi phục thủ công.")
            }
            throw GestaltError.verificationFailed(reason: "khoá \(mismatch) không đúng sau khi ghi; "
                + "đã tự động khôi phục dữ liệu gốc.")
        }

        keepSnapshot = true
        lastSnapshot = snapshot
        AuditLogger.shared.log(event: .gestaltWrite(key: label))
        return GestaltWriteOutcome(snapshot: snapshot,
                                   verified: true,
                                   changedKeys: Array(changes.keys).sorted())
    }

    /// Khôi phục từ snapshot gần nhất. Dùng chung pipeline ghi đã xác minh.
    func restoreLastSnapshot() throws {
        guard let snapshot = lastSnapshot else { throw GestaltError.noSnapshot }
        let destination = URL(fileURLWithPath: snapshot.originalPath)
        let data: Data
        do {
            data = try Data(contentsOf: snapshot.snapshotURL)
        } catch {
            throw GestaltError.readFailed(reason: error.localizedDescription)
        }
        do {
            try AtomicFileWriter.write(data, to: destination)
        } catch let writeError as AtomicFileWriter.WriteError {
            switch writeError.category {
            case .permission: throw GestaltError.notWritable(reason: writeError.localizedDescription)
            case .verification: throw GestaltError.verificationFailed(reason: writeError.localizedDescription)
            case .io: throw GestaltError.writeFailed(reason: writeError.localizedDescription)
            }
        }
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

/// Kết quả một lần ghi đã được xác minh bởi đọc lại file.
struct GestaltWriteOutcome {
    let snapshot: SnapshotManager.Snapshot
    let verified: Bool
    let changedKeys: [String]
}

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
    case readFailed(reason: String)
    case invalidFormat(path: String)
    case emptyKey
    case invalidValue(reason: String)
    case snapshotFailed(reason: String)
    case notWritable(reason: String)
    case writeFailed(reason: String)
    case verificationFailed(reason: String)
    case rollbackFailed(reason: String)
    case noSnapshot

    /// Nhóm lỗi để UI tô màu và chọn hướng xử lý.
    var category: String {
        switch self {
        case .disabled, .notWritable: return "permission"
        case .readFailed, .invalidFormat, .cacheNotFound: return "read"
        case .snapshotFailed, .noSnapshot: return "backup"
        case .verificationFailed, .rollbackFailed: return "verification"
        case .emptyKey, .invalidValue: return "validation"
        case .writeFailed: return "write"
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled(let reason):
            return "Tính năng Gestalt bị vô hiệu hoá. \(reason)"
        case .cacheNotFound(let searched):
            return "Không tìm thấy MobileGestalt cache. Đã thử: \(searched)"
        case .readFailed(let reason):
            return "Không đọc được file Gestalt: \(reason)"
        case .invalidFormat(let path):
            return "File Gestalt không phải property list hợp lệ: \(path)"
        case .emptyKey:
            return "Tên tham số không được để trống."
        case .invalidValue(let reason):
            return "Giá trị không hợp lệ: \(reason)"
        case .snapshotFailed(let reason):
            return "Backup thất bại — đã HUỶ lệnh ghi để bảo vệ dữ liệu gốc. Lý do: \(reason)"
        case .notWritable(let reason):
            return "Không có quyền ghi MobileGestalt. \(reason)"
        case .writeFailed(let reason):
            return "Ghi file Gestalt thất bại: \(reason)"
        case .verificationFailed(let reason):
            return "Xác minh dữ liệu thất bại: \(reason)"
        case .rollbackFailed(let reason):
            return "Khôi phục dữ liệu gốc thất bại: \(reason)"
        case .noSnapshot:
            return "Chưa có bản backup nào trong phiên này để khôi phục."
        }
    }
}

