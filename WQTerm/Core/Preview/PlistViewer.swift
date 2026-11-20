import Foundation

/// Plist viewer: tree view expand/collapse + raw XML, edit có backup write-ahead (PRD Module 7.2).
final class PlistViewer {
    static let shared = PlistViewer()
    private let fileManager = FileManager.default

    private init() {}

    func parse(url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    func rawXML(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
        else { return nil }
        return String(data: xml, encoding: .utf8)
    }

    /// Edit plist với backup write-ahead trước khi ghi (PRD Module 3).
    ///
    /// Thứ tự bắt buộc: `SnapshotEngine.createSnapshot(for: url)` → ghi nguyên tử.
    /// Nếu backup thất bại, hàm **ném lỗi** và file gốc không bị chạm tới.
    func edit(url: URL, newValue: Any) throws {
        // Write-ahead snapshot — thất bại thì dừng, không ghi.
        try SnapshotEngine.createSnapshot(for: url)

        let data = try PropertyListSerialization.data(fromPropertyList: newValue, format: .xml, options: 0)
        try AtomicFileWriter.write(data, to: url)
        AuditLogger.shared.log(event: .fileWrite(path: url.path))
    }

    /// Đặt một key ở cấp cao nhất của plist, có snapshot write-ahead.
    ///
    /// - Returns: Snapshot đã tạo (dùng để khôi phục nếu cần).
    @discardableResult
    func setValue(_ value: String, forKey key: String, at url: URL) throws -> SnapshotManager.Snapshot {
        let snapshot = try SnapshotEngine.createSnapshot(for: url)

        var dictionary = (parse(url: url) as? [String: Any]) ?? [:]
        dictionary[key] = value

        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        try AtomicFileWriter.write(data, to: url)
        AuditLogger.shared.log(event: .fileWrite(path: url.path))
        return snapshot
    }
}
