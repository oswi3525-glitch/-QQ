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
    func edit(url: URL, newValue: Any) throws {
        // Write-ahead snapshot
        SnapshotManager.shared.createWriteAheadSnapshot(for: "plist edit", cwd: url.deletingLastPathComponent().path)
        let data = try PropertyListSerialization.data(fromPropertyList: newValue, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        AuditLogger.shared.log(event: .fileWrite(path: url.path))
    }
}
