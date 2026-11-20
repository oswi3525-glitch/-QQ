import Foundation

/// Các tiện ích file dùng chung (kích thước, copy cây thư mục, tên an toàn).
enum FileSystem {
    /// Tổng kích thước (byte) của cây thư mục. Trả 0 nếu không đọc được.
    static func directorySize(_ url: URL) -> UInt64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return UInt64(size)
        }

        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += UInt64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Copy cây thư mục, giữ nguyên symlink (không đi theo) và quyền thực thi.
    ///
    /// `FileManager.copyItem` ném lỗi khi gặp symlink hỏng — với bundle app đã dump
    /// từ container, trường hợp này khá phổ biến nên ta tự dựng cây.
    static func copyTree(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let attributes = (try? fileManager.attributesOfItem(atPath: source.path)) ?? [:]
        let type = attributes[.type] as? FileAttributeType

        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true, attributes: nil)

        if type == .typeSymbolicLink {
            let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try? fileManager.removeItem(at: destination)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            return
        }

        if type == .typeDirectory {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
            let children = try fileManager.contentsOfDirectory(at: source,
                                                              includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [])
            for child in children {
                try copyTree(from: child,
                             to: destination.appendingPathComponent(child.lastPathComponent))
            }
            if let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value {
                try? fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)],
                                               ofItemAtPath: destination.path)
            }
            return
        }

        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Tên file an toàn: bỏ `/`, `:` và ký tự điều khiển.
    static func safeFileName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : String(trimmed.prefix(120))
    }

    /// Xoá một thư mục tạm, bỏ qua lỗi.
    static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
