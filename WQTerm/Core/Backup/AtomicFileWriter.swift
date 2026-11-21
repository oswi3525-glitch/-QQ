import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Ghi file an toàn, có kiểm tra quyền và xác minh sau khi ghi.
///
/// Nguyên tắc:
/// 1. Không bao giờ tạo file tạm ở thư mục hệ thống khi chưa chứng minh được
///    có quyền ghi thực tế (đây là nguyên nhân lỗi errno 1 / EPERM trước đây).
/// 2. File tạm luôn nằm CÙNG thư mục với đích (tránh rename khác filesystem),
///    nhưng chỉ sau khi probe `O_CREAT` thành công.
/// 3. `fsync` + `close` được kiểm tra giá trị trả về, sau đó đọc lại để so sánh.
/// 4. Mọi file tạm đều được dọn trong `defer`, kể cả khi ném lỗi.
enum AtomicFileWriter {
    enum WriteError: LocalizedError {
        /// Thư mục đích không cho phép tạo file (EPERM/EACCES…).
        case permissionDenied(directory: String, code: Int32)
        case createFailed(path: String, code: Int32)
        case writeFailed(path: String, code: Int32)
        case syncFailed(path: String, code: Int32)
        case renameFailed(path: String, code: Int32)
        /// Ghi xong nhưng đọc lại không khớp — không được báo thành công.
        case verificationFailed(path: String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied(let directory, let code):
                return "Không có quyền ghi tại thư mục đích (errno \(code)). "
                    + "Ứng dụng chỉ có quyền đọc — dữ liệu gốc được giữ nguyên. "
                    + "Thư mục: \(directory)"
            case .createFailed(let path, let code):
                return "Không tạo được file tạm tại \(path) (errno \(code))"
            case .writeFailed(let path, let code):
                return "Không ghi được dữ liệu vào \(path) (errno \(code))"
            case .syncFailed(let path, let code):
                return "Không đồng bộ được dữ liệu xuống đĩa cho \(path) (errno \(code))"
            case .renameFailed(let path, let code):
                return "Không thay thế được \(path) (errno \(code))"
            case .verificationFailed(let path):
                return "Đã ghi nhưng dữ liệu đọc lại không khớp tại \(path). "
                    + "Không báo thành công."
            }
        }

        /// Phân loại để UI/backup hiển thị đúng nhóm lỗi.
        var category: WriteErrorCategory {
            switch self {
            case .permissionDenied: return .permission
            case .createFailed(let path, let code), .writeFailed(let path, let code),
                 .syncFailed(let path, let code):
                return code == EACCES || code == EPERM ? .permission : .io
            case .renameFailed: return .io
            case .verificationFailed: return .verification
            }
        }
    }

    enum WriteErrorCategory: String {
        case permission
        case io
        case verification
    }

    /// Probe quyền ghi thực tế bằng cách tạo rồi xoá một file tạm trong thư mục.
    /// Trả về `nil` nếu có thể ghi, ngược lại trả mã errno.
    static func writabilityError(in directory: URL) -> Int32? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return ENOENT }

        let probe = directory.appendingPathComponent(".wqterm-probe-\(UUID().uuidString)")
        let descriptor = open(probe.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        try? FileManager.default.removeItem(at: probe)
        return nil
    }

    /// Ghi `data` vào `url` một cách nguyên tử và xác minh nội dung sau khi ghi.
    static func write(_ data: Data, to url: URL) throws {
        // Đích có thể là symlink (worse_query mount). Ghi vào mục tiêu thật,
        // không rename đè lên chính symlink — điều đó sẽ phá mount.
        let resolved = url.resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()

        // 1. Preflight: chỉ tạo temp khi chắc chắn thư mục cho phép ghi.
        if let code = writabilityError(in: directory) {
            throw WriteError.permissionDenied(directory: directory.path, code: code)
        }

        let temporaryURL = directory.appendingPathComponent(".wqterm-tmp-\(UUID().uuidString)")
        var descriptor: Int32 = -1

        defer {
            if descriptor >= 0 { close(descriptor) }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw WriteError.createFailed(path: temporaryURL.path, code: errno)
        }

        // 2. Ghi toàn bộ buffer (xử lý partial write).
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    throw WriteError.writeFailed(path: temporaryURL.path, code: errno)
                }
                if written == 0 { break }
                offset += written
            }
        }
        guard offset == data.count else {
            throw WriteError.writeFailed(path: temporaryURL.path, code: EIO)
        }

        // 3. fsync / close đều phải thành công trước khi rename.
        if fsync(descriptor) != 0 {
            throw WriteError.syncFailed(path: temporaryURL.path, code: errno)
        }
        if close(descriptor) != 0 {
            let code = errno
            descriptor = -1
            throw WriteError.syncFailed(path: temporaryURL.path, code: code)
        }
        descriptor = -1

        if rename(temporaryURL.path, resolved.path) != 0 {
            throw WriteError.renameFailed(path: resolved.path, code: errno)
        }

        // 4. Xác minh nội dung sau khi ghi. Không trả success nếu không khớp.
        guard let written = try? Data(contentsOf: resolved), written == data else {
            throw WriteError.verificationFailed(path: resolved.path)
        }
    }
}
