import Foundation
import SQLite3

/// Trình đọc SQLite chỉ-đọc, dùng thư viện `libsqlite3` có sẵn trên iOS.
///
/// Mở database với `SQLITE_OPEN_READONLY` để không bao giờ ghi đè dữ liệu gốc,
/// sau đó liệt kê danh sách bảng và đọc từng bảng để hiển thị.
final class SQLiteViewer {
    static let shared = SQLiteViewer()

    struct TableInfo: Identifiable, Hashable {
        let name: String
        let rowCount: Int
        let columnNames: [String]

        var id: String { name }
    }

    struct TableData {
        let columnNames: [String]
        let rows: [[String]]
        let truncated: Bool
    }

    enum SQLiteViewerError: LocalizedError {
        case cannotOpen(path: String, message: String)
        case queryFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path, let message):
                return "Không mở được SQLite database \(path): \(message)"
            case .queryFailed(let message):
                return "Truy vấn thất bại: \(message)"
            }
        }
    }

    /// Số dòng tối đa đọc mỗi bảng — tránh treo UI với bảng lớn.
    let rowLimit = 500

    private init() {}

    /// Liệt kê các bảng (và view) trong database.
    func listTables(at url: URL) throws -> [TableInfo] {
        let database = try open(url)
        defer { sqlite3_close(database) }

        let sql = """
        SELECT name FROM sqlite_master
        WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteViewerError.queryFailed(message: errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0) {
                names.append(String(cString: pointer))
            }
        }

        return names.map { name in
            let columns = (try? columns(of: name, database: database)) ?? []
            let count = (try? rowCount(of: name, database: database)) ?? 0
            return TableInfo(name: name, rowCount: count, columnNames: columns)
        }
    }

    /// Đọc nội dung một bảng (giới hạn `rowLimit` dòng).
    func readTable(_ name: String, at url: URL) throws -> TableData {
        let database = try open(url)
        defer { sqlite3_close(database) }

        let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let sql = "SELECT * FROM \(quoted) LIMIT \(rowLimit);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteViewerError.queryFailed(message: errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var headers: [String] = []
        for index in 0..<columnCount {
            headers.append(sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "#\(index)")
        }

        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for index in 0..<columnCount {
                let type = sqlite3_column_type(statement, index)
                switch type {
                case SQLITE_NULL:
                    row.append("NULL")
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, index)
                    row.append("<blob \(BuiltinShell.sizeLabel(UInt64(bytes)))>")
                default:
                    if let pointer = sqlite3_column_text(statement, index) {
                        row.append(String(cString: pointer))
                    } else {
                        row.append("")
                    }
                }
            }
            rows.append(row)
        }

        return TableData(columnNames: headers, rows: rows, truncated: rows.count >= rowLimit)
    }

    // MARK: - Private

    private func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { errorMessage($0) } ?? "không mở được file"
            if let database { sqlite3_close(database) }
            throw SQLiteViewerError.cannotOpen(path: url.path, message: message)
        }
        return database
    }

    private func columns(of table: String, database: OpaquePointer) throws -> [String] {
        let sql = "PRAGMA table_info(\"\\(table.replacingOccurrences(of: "\"", with: "\"\""))\");"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 1) { names.append(String(cString: pointer)) }
        }
        return names
    }

    private func rowCount(of table: String, database: OpaquePointer) throws -> Int {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(quoted);", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "lỗi không xác định"
    }
}
