import Foundation

/// Trích nội dung file để gửi cho AI (Module 3 — "Ask AI" trong màn hình xem file).
///
/// Chiến lược:
/// - File text/JSON/plist → đọc trực tiếp, cắt theo `limit`.
/// - SQLite → liệt kê bảng + vài dòng đầu mỗi bảng (không dump cả database).
/// - ZIP/IPA → liệt kê entry.
/// - Nhị phân → mô tả metadata + hexdump ngắn.
///
/// Luôn trả chuỗi có mô tả rõ nguồn gốc, để câu trả lời của AI bám đúng ngữ cảnh.
enum FileContextExtractor {

    /// Trích ngữ cảnh cho `url`, giới hạn `limit` byte.
    static func extract(url: URL, limit: Int) -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return "(không tìm thấy file \(url.lastPathComponent))"
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let kind = PreviewRouter.kind(for: url)
        var output: [String] = [
            "Kích thước: \(BuiltinShell.sizeLabel(UInt64(size)))",
            "Định dạng nhận diện: \(kind.displayName)"
        ]

        switch kind {
        case .sqlite:
            output.append(contentsOf: sqliteSummary(url: url))
        case .zip:
            output.append(contentsOf: zipSummary(url: url))
        case .plist:
            if let xml = PlistViewer.shared.rawXML(url: url) {
                output.append("Nội dung plist (XML):\n```xml")
                output.append(String(xml.prefix(limit)))
                output.append("```")
            } else {
                output.append(contentsOf: hexSummary(url: url, limit: min(limit, 2048)))
            }
        case .text:
            if let data = try? Data(contentsOf: url) {
                let text = String(data: data.prefix(limit), encoding: .utf8) ?? ""
                output.append("Nội dung:\n```")
                output.append(text)
                output.append("```")
            }
        case .image:
            output.append("Đây là file ảnh; nội dung nhị phân không gửi kèm.")
        case .hex:
            output.append(contentsOf: hexSummary(url: url, limit: min(limit, 2048)))
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Private

    private static func sqliteSummary(url: URL) -> [String] {
        do {
            let tables = try SQLiteViewer.shared.listTables(at: url)
            guard !tables.isEmpty else { return ["Database không có bảng nào."] }

            var lines = ["Các bảng (\(tables.count)):"]
            for table in tables.prefix(8) {
                lines.append("- \(table.name): \(table.rowCount) dòng, cột: "
                             + table.columnNames.joined(separator: ", "))
                if let data = try? SQLiteViewer.shared.readTable(table.name, at: url),
                   let header = data.columnNames.isEmpty ? nil : data.columnNames.joined(separator: " | ") {
                    lines.append("  header: \(header)")
                    for row in data.rows.prefix(3) {
                        lines.append("  " + row.joined(separator: " | "))
                    }
                }
            }
            return lines
        } catch {
            return ["Không đọc được SQLite: \(error.localizedDescription)"]
        }
    }

    private static func zipSummary(url: URL) -> [String] {
        let entries = (try? ZipArchive.listEntries(url)) ?? []
        guard !entries.isEmpty else { return ["Archive rỗng hoặc không đọc được central directory."] }

        var lines = ["Archive có \(entries.count) entry. 40 entry đầu:"]
        for entry in entries.prefix(40) {
            let suffix = entry.isDirectory ? "/" : " (\(BuiltinShell.sizeLabel(entry.uncompressedSize)))"
            lines.append("  \(entry.name)\(suffix)")
        }
        return lines
    }

    private static func hexSummary(url: URL, limit: Int) -> [String] {
        let dump = HexViewer.shared.hexDump(url: url, limit: limit)
        let format = HexViewer.shared.detectFormat(url: url)
        return [
            "Định dạng theo magic bytes: \(format)",
            "Hexdump (\(limit) byte đầu):",
            "```",
            dump,
            "```"
        ]
    }
}
