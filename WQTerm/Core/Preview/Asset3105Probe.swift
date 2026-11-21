import Foundation

/// Dò và giải nén file `.3105` (Module 7 — định dạng đặc thù).
///
/// `.3105` không phải định dạng chuẩn của Apple. Trên thực tế file thường là
/// ZIP/plist/text được đổi đuôi, đôi khi có thêm header riêng trước dữ liệu ZIP.
/// Probe này:
/// - nhận diện bằng magic bytes (không tin phần mở rộng),
/// - tìm signature ZIP nằm lệch đầu file và tạo bản copy đã cắt header,
/// - liệt kê entry / trích text / hex để người dùng xem trước,
/// - giải nén an toàn qua `ZipArchive.extract` (chống zip-slip).
enum Asset3105Probe {

    enum Kind: String {
        case zip
        case plist
        case sqlite
        case image
        case pdf
        case text
        case unknown

        var label: String {
            switch self {
            case .zip: return "ZIP / archive"
            case .plist: return "Property List"
            case .sqlite: return "SQLite"
            case .image: return "Hình ảnh"
            case .pdf: return "PDF"
            case .text: return "Văn bản"
            case .unknown: return "Chưa nhận diện"
            }
        }

        var systemImage: String {
            switch self {
            case .zip: return "doc.zipper"
            case .plist: return "list.bullet.rectangle"
            case .sqlite: return "cylinder.split.1x2"
            case .image: return "photo"
            case .pdf: return "doc.richtext"
            case .text: return "doc.text"
            case .unknown: return "questionmark.square.dashed"
            }
        }
    }

    struct Inspection {
        let sourceURL: URL
        /// URL dùng để đọc ZIP. Nếu file có header lạ, đây là bản copy đã cắt header.
        let workingURL: URL
        let kind: Kind
        let magic: String
        let fileSize: UInt64
        /// Số byte header bị bỏ qua trước signature ZIP (0 nếu ZIP nằm ngay đầu).
        let zipOffset: Int
        let entries: [ZipArchive.Entry]
        let textPreview: String?
        let notes: [String]

        var canExtract: Bool { kind == .zip && !entries.isEmpty }
        var entryCount: Int { entries.count }
        var unpackedSize: UInt64 { entries.reduce(0) { $0 + $1.uncompressedSize } }
    }

    /// Đọc tối đa 64KB để preview text.
    private static let previewLimit = 64 * 1024

    // MARK: - Inspect

    static func inspect(url: URL) -> Inspection {
        let fileSize = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let head = readHead(url: url, limit: 4096)
        let magic = head.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        var notes: [String] = []
        var kind = detectKind(head: head, url: url)
        var workingURL = url
        var zipOffset = 0

        if kind != .zip, let offset = findZipStart(in: head), offset > 0 {
            kind = .zip
            zipOffset = offset
            notes.append("Tìm thấy signature ZIP tại offset \(offset); đã bỏ qua header.")
            if let trimmed = makeTrimmedCopy(url: url, offset: offset) {
                workingURL = trimmed
            } else {
                notes.append("Không tạo được bản copy ZIP đã cắt header.")
            }
        } else if kind == .zip, let offset = findZipStart(in: head) {
            zipOffset = offset
            if offset > 0 {
                notes.append("Signature ZIP nằm tại offset \(offset).")
                if let trimmed = makeTrimmedCopy(url: url, offset: offset) {
                    workingURL = trimmed
                }
            }
        }

        var entries: [ZipArchive.Entry] = []
        if kind == .zip {
            entries = (try? ZipArchive.listEntries(workingURL)) ?? []
            if entries.isEmpty {
                notes.append("Không đọc được central directory của ZIP.")
            }
        }

        var textPreview: String?
        switch kind {
        case .text:
            textPreview = readText(url: url, limit: previewLimit)
        case .plist:
            if let xml = PlistViewer.shared.rawXML(url: url) {
                textPreview = String(xml.prefix(previewLimit))
            } else {
                textPreview = readText(url: url, limit: previewLimit)
            }
        case .unknown:
            notes.append("Chưa khớp magic bytes nào; hiển thị hexdump để phân tích.")
        default:
            break
        }

        return Inspection(sourceURL: url,
                          workingURL: workingURL,
                          kind: kind,
                          magic: magic,
                          fileSize: fileSize,
                          zipOffset: zipOffset,
                          entries: entries,
                          textPreview: textPreview,
                          notes: notes)
    }

    // MARK: - Extract

    /// Giải nén `inspection` vào `Documents/Unzipped/<tên>-<timestamp>/`.
    @discardableResult
    static func extract(_ inspection: Inspection) throws -> URL {
        guard inspection.canExtract else {
            throw ZipArchive.ZipError.invalidArchive("không có entry ZIP để giải nén")
        }
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = FileSystem.safeFileName(
            inspection.sourceURL.deletingPathExtension().lastPathComponent
        )
        let destination = documents
            .appendingPathComponent("Unzipped", isDirectory: true)
            .appendingPathComponent("\(base)-\(timestamp())", isDirectory: true)

        try ZipArchive.extract(inspection.workingURL, to: destination)
        AuditLogger.shared.log(event: .fileWrite(path: destination.path))
        return destination
    }

    // MARK: - Detection

    private static func detectKind(head: Data, url: URL) -> Kind {
        let bytes = [UInt8](head)

        if isZip(bytes) { return .zip }
        if bytes.count >= 15, Array(bytes[0..<15]) == Array("SQLite format 3".utf8) {
            return .sqlite
        }
        if bytes.count >= 6, String(bytes: bytes[0..<6], encoding: .utf8)?.hasPrefix("bplist") == true {
            return .plist
        }
        if bytes.count >= 8,
           Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .image
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return .image
        }
        if bytes.count >= 6, String(bytes: bytes[0..<6], encoding: .ascii)?.hasPrefix("GIF8") == true {
            return .image
        }
        if bytes.count >= 4, String(bytes: bytes[0..<4], encoding: .ascii) == "%PDF" {
            return .pdf
        }
        if bytes.count >= 5, String(bytes: bytes[0..<5], encoding: .utf8)?.hasPrefix("<?xml") == true {
            return isPlist(url: url) ? .plist : .text
        }
        if isLikelyText(head) { return .text }
        return .unknown
    }

    private static func isZip(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B else { return false }
        return (bytes[2] == 0x03 && bytes[3] == 0x04)
            || (bytes[2] == 0x05 && bytes[3] == 0x06)
            || (bytes[2] == 0x07 && bytes[3] == 0x08)
    }

    private static func findZipStart(in head: Data) -> Int? {
        let bytes = [UInt8](head)
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 0x50
            && bytes[index + 1] == 0x4B
            && bytes[index + 2] == 0x03
            && bytes[index + 3] == 0x04 {
            return index
        }
        return nil
    }

    private static func isPlist(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil) else {
            return false
        }
        return object is [String: Any] || object is [Any]
    }

    private static func isLikelyText(_ head: Data) -> Bool {
        guard !head.isEmpty else { return false }
        var printable = 0
        for byte in head {
            if byte == 0x09 || byte == 0x0A || byte == 0x0D || (0x20...0x7E).contains(byte) {
                printable += 1
            } else if byte >= 0x80 {
                // Cho phép UTF-8 đa byte; kiểm tra tổng thể bằng decode bên dưới.
                printable += 1
            }
        }
        let ratio = Double(printable) / Double(head.count)
        guard ratio > 0.90 else { return false }
        return String(data: head, encoding: .utf8) != nil
    }

    // MARK: - IO

    private static func readHead(url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    private static func readText(url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// Copy phần dữ liệu từ `offset` tới hết file ra tmp, trả về URL mới.
    private static func makeTrimmedCopy(url: URL, offset: Int) -> URL? {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("asset3105-\(UUID().uuidString).zip")

        guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? input.close() }
        do {
            try input.seek(toOffset: UInt64(offset))
        } catch {
            return nil
        }

        guard fileManager.createFile(atPath: destination.path, contents: nil) else { return nil }
        guard let output = try? FileHandle(forWritingTo: destination) else { return nil }
        defer { try? output.close() }

        while true {
            guard let chunk = try? input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                try? fileManager.removeItem(at: destination)
                return nil
            }
        }
        return destination
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
