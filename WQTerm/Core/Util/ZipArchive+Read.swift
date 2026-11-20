import Foundation

/// Phần đọc/giải nén của `ZipArchive`.
///
/// Đọc central directory ở cuối file (hỗ trợ archive có comment), sau đó giải nén
/// từng entry. Chặn path traversal (`../`) và symlink trỏ ra ngoài thư mục đích —
/// bắt buộc vì `unzip` chạy được trên file do người khác tạo.
extension ZipArchive {

    /// Danh sách entry đọc từ central directory (không giải nén).
    static func listEntries(_ archive: URL) throws -> [Entry] {
        guard let handle = FileHandle(forReadingFrom: archive) else {
            throw ZipError.cannotOpen(archive.path)
        }
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.invalidArchive("file quá nhỏ") }

        let searchSize = min(UInt64(65_557), fileSize)
        try handle.seek(toOffset: fileSize - searchSize)
        guard let tail = try handle.read(upToCount: Int(searchSize)), !tail.isEmpty else {
            throw ZipError.invalidArchive("không đọc được phần cuối")
        }

        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.le32(at: index) == 0x0605_4B50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocdPosition = eocd else { throw ZipError.invalidArchive("thiếu EOCD record") }

        let totalEntries = Int(tail.le16(at: eocdPosition + 10))
        let centralSize = Int(tail.le32(at: eocdPosition + 12))
        let centralOffset = Int(tail.le32(at: eocdPosition + 16))
        guard centralSize > 0 else { return [] }

        try handle.seek(toOffset: UInt64(centralOffset))
        guard let central = try handle.read(upToCount: centralSize),
              central.count == centralSize else {
            throw ZipError.invalidArchive("central directory bị cắt")
        }

        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<totalEntries {
            guard cursor + 46 <= central.count, central.le32(at: cursor) == 0x0201_4B50 else { break }

            let method = central.le16(at: cursor + 10)
            let time = central.le16(at: cursor + 12)
            let date = central.le16(at: cursor + 14)
            let crc = central.le32(at: cursor + 16)
            let compressedSize = UInt64(central.le32(at: cursor + 20))
            let uncompressedSize = UInt64(central.le32(at: cursor + 24))
            let nameLength = Int(central.le16(at: cursor + 28))
            let extraLength = Int(central.le16(at: cursor + 30))
            let commentLength = Int(central.le16(at: cursor + 32))
            let externalAttributes = central.le32(at: cursor + 38)
            let localOffset = UInt64(central.le32(at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= central.count else { break }
            let name = String(data: central.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""

            entries.append(Entry(name: name,
                                 method: method,
                                 crc32: crc,
                                 compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localOffset,
                                 externalAttributes: externalAttributes,
                                 modified: ZipTime.date(dosTime: time, dosDate: date)))

            cursor = nameEnd + extraLength + commentLength
        }
        return entries
    }

    /// Giải nén toàn bộ archive vào `destination`.
    ///
    /// - An toàn: từ chối entry có `..`, đường dẫn tuyệt đối, hoặc symlink trỏ ra
    ///   ngoài `destination` (zip-slip).
    /// - Giữ quyền thực thi (bit `x`) để các binary trong toolchain chạy được.
    static func extract(_ archive: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let entries = try listEntries(archive)
        guard let handle = FileHandle(forReadingFrom: archive) else {
            throw ZipError.cannotOpen(archive.path)
        }
        defer { try? handle.close() }

        let root = destination.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)

        for entry in entries {
            let relative = try sanitized(entry.name)
            let target = root.appendingPathComponent(relative).standardizedFileURL

            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
                continue
            }

            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true, attributes: nil)

            // Đọc local header để tính đúng offset của dữ liệu.
            try handle.seek(toOffset: entry.localHeaderOffset)
            guard let fixed = try handle.read(upToCount: 30), fixed.count == 30 else {
                throw ZipError.invalidArchive("local header hỏng: \(entry.name)")
            }
            let nameLength = Int(fixed.le16(at: 26))
            let extraLength = Int(fixed.le16(at: 28))
            let dataOffset = entry.localHeaderOffset + 30
                + UInt64(nameLength) + UInt64(extraLength)

            try handle.seek(toOffset: dataOffset)
            let size = Int(entry.compressedSize)
            let raw = size == 0 ? Data() : (try handle.read(upToCount: size) ?? Data())

            let payload: Data
            switch entry.method {
            case 0:
                payload = raw
            case 8:
                guard let inflated = Deflate.decompress(raw, expectedSize: Int(entry.uncompressedSize)) else {
                    throw ZipError.invalidArchive("giải nén hỏng: \(entry.name)")
                }
                payload = inflated
            default:
                throw ZipError.unsupportedMethod(entry.method)
            }

            if entry.isSymlink {
                guard let linkTarget = String(data: payload, encoding: .utf8) else {
                    throw ZipError.invalidArchive("symlink hỏng: \(entry.name)")
                }
                // Chỉ chấp nhận symlink tương đối nằm trong thư mục đích.
                guard !linkTarget.hasPrefix("/"), !linkTarget.contains("..") else {
                    throw ZipError.badEntry(entry.name)
                }
                try? fileManager.removeItem(at: target)
                try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                continue
            }

            try? fileManager.removeItem(at: target)
            guard fileManager.createFile(atPath: target.path, contents: payload) else {
                throw ZipError.cannotCreate(target.path)
            }

            let mode = (entry.externalAttributes >> 16) & 0o777
            if mode != 0 {
                try? fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                               ofItemAtPath: target.path)
            }
            if entry.modified.timeIntervalSince1970 > 0 {
                try? fileManager.setAttributes([.modificationDate: entry.modified],
                                               ofItemAtPath: target.path)
            }
        }
    }

    /// Danh sách tên entry (dạng `ls` của `unzip -l`).
    static func listNames(_ archive: URL) throws -> [String] {
        try listEntries(archive).map { entry in
            entry.isDirectory ? entry.name : "\(entry.name)  (\(BuiltinShell.sizeLabel(entry.uncompressedSize)))"
        }
    }

    /// Chặn path traversal khi giải nén.
    private static func sanitized(_ name: String) throws -> String {
        let trimmed = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let components = trimmed.split(separator: "/").map(String.init)
        guard !trimmed.isEmpty, !components.contains("..") else {
            throw ZipError.badEntry(name)
        }
        return trimmed
    }
}
