import Foundation

/// Ghi file an toàn: ghi ra file tạm cùng thư mục, fsync, rồi `rename()` đè lên file gốc.
///
/// Tránh trường hợp file gốc bị hỏng dở dang nếu tiến trình bị kill giữa lúc ghi.
enum AtomicFileWriter {
    enum WriteError: LocalizedError {
        case createFailed(path: String, code: Int32)
        case writeFailed(path: String, code: Int32)
        case renameFailed(path: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .createFailed(let path, let code):
                return "Không tạo được file tạm tại \(path) (errno \(code))"
            case .writeFailed(let path, let code):
                return "Không ghi được dữ liệu vào \(path) (errno \(code))"
            case .renameFailed(let path, let code):
                return "Không thay thế được \(path) (errno \(code))"
            }
        }
    }

    /// Ghi `data` vào `url` theo cách nguyên tử.
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".wqterm-tmp-\(UUID().uuidString)")

        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw WriteError.createFailed(path: temporaryURL.path, code: errno)
        }

        // Ghi toàn bộ buffer (xử lý partial write).
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    let code = errno
                    close(descriptor)
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw WriteError.writeFailed(path: temporaryURL.path, code: code)
                }
                offset += written
            }
        }

        fsync(descriptor)
        close(descriptor)

        if rename(temporaryURL.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporaryURL)
            throw WriteError.renameFailed(path: url.path, code: code)
        }
    }
}
