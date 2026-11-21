import Foundation

/// Quyết định cách hiển thị một file dựa trên phần mở rộng và magic bytes.
enum PreviewKind: Equatable {
    case plist
    case sqlite
    case zip
    case image
    case text
    case hex
    /// File `.3105` — định dạng đặc thù, probe magic bytes rồi mới quyết định.
    case asset3105

    var displayName: String {
        switch self {
        case .plist: return "Property List"
        case .sqlite: return "SQLite Database"
        case .zip: return "ZIP Archive"
        case .image: return "Hình ảnh"
        case .text: return "Văn bản"
        case .hex: return "Hex"
        case .asset3105: return "Asset .3105"
        }
    }

    var systemImage: String {
        switch self {
        case .plist: return "list.bullet.rectangle"
        case .sqlite: return "cylinder.split.1x2"
        case .zip: return "doc.zipper"
        case .image: return "photo"
        case .text: return "doc.text"
        case .hex: return "number"
        case .asset3105: return "shippingbox"
        }
    }
}

/// Chọn renderer phù hợp cho mỗi file (PRD Module 7).
enum PreviewRouter {
    /// Kích thước tối đa được đọc vào bộ nhớ để preview.
    static let maxInlineBytes: UInt64 = 50 * 1024 * 1024

    static func kind(for url: URL) -> PreviewKind {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "plist", "entitlements", "mobileprovision":
            return .plist
        case "db", "sqlite", "sqlite3", "db3":
            return .sqlite
        case "zip", "ipa", "xcarchive", "jar", "epub":
            return .zip
        case "3105":
            return .asset3105
        case "png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp":
            return .image
        case "txt", "md", "markdown", "json", "xml", "yaml", "yml", "swift",
             "js", "ts", "py", "sh", "c", "h", "m", "cpp", "hpp", "css", "html",
             "htm", "csv", "tsv", "log", "conf", "ini", "toml", "strings":
            return .text
        default:
            break
        }

        // Không rõ phần mở rộng → xét magic bytes.
        return sniffKind(for: url) ?? .hex
    }

    /// Đọc vài byte đầu file để nhận dạng định dạng.
    private static func sniffKind(for url: URL) -> PreviewKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), !head.isEmpty else { return nil }
        let bytes = [UInt8](head)

        if bytes.count >= 15, Array(bytes[0..<15]) == Array("SQLite format 3".utf8) {
            return .sqlite
        }
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03 || bytes[2] == 0x05 {
            return .zip
        }
        if bytes.count >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .image
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return .image
        }
        if bytes.count >= 6, let text = String(bytes: bytes[0..<6], encoding: .utf8),
           text.hasPrefix("bplist") {
            return .plist
        }
        if bytes.count >= 5, let text = String(bytes: bytes[0..<5], encoding: .utf8),
           text.hasPrefix("<?xml") {
            return .text
        }
        // Kiểm tra nội dung có phải UTF-8 đọc được không.
        if let sample = try? Data(contentsOf: url, options: .mappedIfSafe).prefix(4096),
           String(data: SampleData.wrap(sample), encoding: .utf8) != nil {
            return .text
        }
        return nil
    }
}

/// Helper nhỏ để tránh cấp phát thừa khi dò encoding.
private enum SampleData {
    static func wrap(_ slice: Data.SubSequence) -> Data { Data(slice) }
}
