import Foundation

/// Ghi/đọc file ZIP thuần Swift, không phụ thuộc thư viện ngoài.
///
/// WQTerm cần ZIP cho hai việc:
/// 1. Đóng gói `.app` đã copy thành `.ipa` (Module 2 — IPA Dumper).
/// 2. Cung cấp lệnh `unzip` trong Terminal (Module 5 — Toolchain).
///
/// Hỗ trợ method 0 (store) và method 8 (deflate). File lớn hơn
/// `inlineDeflateLimit` được lưu dạng store để tránh jetsam; ZIP64 chưa hỗ trợ
/// và sẽ báo lỗi rõ ràng thay vì tạo archive hỏng.
enum ZipArchive {
    /// File nhỏ hơn ngưỡng này được nén trong bộ nhớ; lớn hơn thì store.
    static let inlineDeflateLimit = 16 * 1024 * 1024

    /// Kích thước chunk khi stream file lớn.
    private static let streamChunk = 1_048_576

    enum ZipError: LocalizedError {
        case cannotCreate(String)
        case cannotOpen(String)
        case invalidArchive(String)
        case unsupportedMethod(UInt16)
        case tooLarge(String)
        case badEntry(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreate(let path): return "Không tạo được ZIP tại \(path)."
            case .cannotOpen(let path): return "Không mở được ZIP: \(path)."
            case .invalidArchive(let reason): return "File ZIP không hợp lệ: \(reason)"
            case .unsupportedMethod(let method): return "Phương thức nén \(method) chưa được hỗ trợ."
            case .tooLarge(let reason): return "Dữ liệu quá lớn cho ZIP cổ điển: \(reason)"
            case .badEntry(let name): return "Entry không an toàn (path traversal): \(name)"
            }
        }
    }

    /// Một entry đọc từ central directory.
    struct Entry {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let externalAttributes: UInt32
        let modified: Date

        var isDirectory: Bool { name.hasSuffix("/") }
        var isSymlink: Bool { (externalAttributes >> 16) & 0xF000 == 0xA000 }
    }

    // MARK: - Create

    /// Nén toàn bộ nội dung `root` thành ZIP tại `destination`.
    ///
    /// Tên entry luôn giữ tiền tố `root.lastPathComponent`, nhờ vậy
    /// `create(directory: tmp/Payload, at: x.ipa)` tạo archive có cấu trúc chuẩn
    /// `Payload/MyApp.app/...` mà iOS yêu cầu khi sideload.
    @discardableResult
    static func create(directory root: URL, at destination: URL) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true, attributes: nil)
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let handle = FileHandle(forWritingTo: destination) else {
            throw ZipError.cannotCreate(destination.path)
        }
        defer { try? handle.close() }

        var centralRecords: [Data] = []
        var offset: UInt64 = 0

        for item in try orderedEntries(under: root) {
            let name = relativePath(for: item, root: root)
            if let record = try writeEntry(item, name: name, handle: handle, offset: &offset) {
                centralRecords.append(record)
            }
        }

        let centralStart = offset
        for record in centralRecords {
            handle.write(record)
            offset += UInt64(record.count)
        }
        let centralSize = offset - centralStart

        guard offset <= UInt64(UInt32.max) else { throw ZipError.tooLarge("archive > 4GB") }

        var end = Data()
        end.appendLE32(0x0605_4B50)
        end.appendLE16(0)                                        // disk number
        end.appendLE16(0)                                        // disk with central dir
        end.appendLE16(UInt16(min(centralRecords.count, 0xFFFF)))
        end.appendLE16(UInt16(min(centralRecords.count, 0xFFFF)))
        end.appendLE32(UInt32(centralSize))
        end.appendLE32(UInt32(centralStart))
        end.appendLE16(0)                                        // comment length
        handle.write(end)

        return destination
    }

    /// Ghi một mục (header + data) và trả về bản ghi central directory.
    private static func writeEntry(_ url: URL,
                                   name: String,
                                   handle: FileHandle,
                                   offset: inout UInt64) throws -> Data? {
        let fileManager = FileManager.default
        let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        let type = attributes[.type] as? FileAttributeType
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let modified = (attributes[.modificationDate] as? Date) ?? Date()

        var entryName = name
        var mode: UInt16 = permissions
        var isDirectory = false
        var inlinePayload: Data?

        if type == .typeSymbolicLink {
            // Symlink: nội dung là đường dẫn đích, mode S_IFLNK | 0777.
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
            inlinePayload = Data(target.utf8)
            mode = 0o120777
        } else if type == .typeDirectory {
            isDirectory = true
            if !entryName.hasSuffix("/") { entryName += "/" }
            inlinePayload = Data()
            mode = 0o040755
        }

        let fileSize: UInt64 = inlinePayload.map { UInt64($0.count) }
            ?? UInt64((attributes[.size] as? NSNumber)?.uint64Value ?? 0)

        var method: UInt16 = 0
        var compressed = Data()
        var crc: UInt32 = 0

        if let payload = inlinePayload {
            let deflated = (payload.isEmpty || payload.count > inlineDeflateLimit)
                ? nil
                : Deflate.compress(payload)
            if let deflated, deflated.count < payload.count {
                method = 8
                compressed = deflated
            } else {
                compressed = payload
            }
            crc = CRC32.checksum(payload)
        } else {
            // File lớn: CRC tính trước (pass 1), dữ liệu ghi ở pass 2.
            crc = try CRC32.checksum(of: url)
        }

        let compressedSize: UInt64 = inlinePayload == nil ? fileSize : UInt64(compressed.count)
        guard compressedSize <= UInt64(UInt32.max), fileSize <= UInt64(UInt32.max) else {
            throw ZipError.tooLarge(entryName)
        }

        let dos = ZipTime.dosDateTime(modified)
        let localOffset = offset
        guard localOffset <= UInt64(UInt32.max) else { throw ZipError.tooLarge(entryName) }

        var header = Data()
        header.appendLE32(0x0403_4B50)
        header.appendLE16(20)                                     // version needed
        header.appendLE16(0x0800)                                 // UTF-8 filename flag
        header.appendLE16(method)
        header.appendLE16(dos.time)
        header.appendLE16(dos.date)
        header.appendLE32(crc)
        header.appendLE32(UInt32(compressedSize))
        header.appendLE32(UInt32(fileSize))
        header.appendLE16(UInt16(entryName.utf8.count))
        header.appendLE16(0)                                      // extra length
        header.append(Data(entryName.utf8))

        handle.write(header)
        offset += UInt64(header.count)

        if inlinePayload != nil {
            if !compressed.isEmpty {
                handle.write(compressed)
                offset += UInt64(compressed.count)
            }
        } else {
            try copyFile(at: url, to: handle, offset: &offset)
        }
        return centralRecord(name: entryName,
                             method: method,
                             crc: crc,
                             compressedSize: compressedSize,
                             fileSize: fileSize,
                             mode: mode,
                             isDirectory: isDirectory,
                             modified: modified,
                             localOffset: UInt32(localOffset))
    }

    /// Bản ghi central directory cho một entry.
    private static func centralRecord(name: String,
                                      method: UInt16,
                                      crc: UInt32,
                                      compressedSize: UInt64,
                                      fileSize: UInt64,
                                      mode: UInt16,
                                      isDirectory: Bool,
                                      modified: Date,
                                      localOffset: UInt32) -> Data {
        let dos = ZipTime.dosDateTime(modified)
        var record = Data()
        record.appendLE32(0x0201_4B50)
        record.appendLE16(0x031E)                                 // made by: UNIX, v3.0
        record.appendLE16(20)
        record.appendLE16(0x0800)                                 // UTF-8 flag
        record.appendLE16(method)
        record.appendLE16(dos.time)
        record.appendLE16(dos.date)
        record.appendLE32(crc)
        record.appendLE32(UInt32(compressedSize))
        record.appendLE32(UInt32(fileSize))
        record.appendLE16(UInt16(name.utf8.count))
        record.appendLE16(0)                                      // extra length
        record.appendLE16(0)                                      // comment length
        record.appendLE16(0)                                      // disk number start
        record.appendLE16(isDirectory ? 0x10 : 0)                 // internal attributes
        record.appendLE32(UInt32(mode) << 16)                     // external attributes
        record.appendLE32(localOffset)
        record.append(Data(name.utf8))
        return record
    }

    /// Stream nguyên file vào archive, cập nhật số byte đã ghi.
    private static func copyFile(at url: URL, to output: FileHandle, offset: inout UInt64) throws {
        guard let input = FileHandle(forReadingFrom: url) else {
            throw ZipError.cannotOpen(url.path)
        }
        defer { try? input.close() }

        while true {
            let chunk = try input.read(upToCount: streamChunk) ?? Data()
            if chunk.isEmpty { break }
            output.write(chunk)
            offset += UInt64(chunk.count)
        }
    }

    /// Duyệt cây thư mục theo thứ tự ổn định, cha trước con.
    private static func orderedEntries(under root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var result: [URL] = []

        func walk(_ url: URL) {
            result.append(url)
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return }
            let children = (try? fileManager.contentsOfDirectory(at: url,
                                                                 includingPropertiesForKeys: keys,
                                                                 options: [])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                walk(child)
            }
        }

        walk(root)
        return result
    }

    /// Đường dẫn tương đối, luôn bắt đầu bằng tên thư mục gốc.
    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return root.lastPathComponent + "/" }
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return root.lastPathComponent + "/" + String(path.dropFirst(rootPath.count + 1))
    }
}
