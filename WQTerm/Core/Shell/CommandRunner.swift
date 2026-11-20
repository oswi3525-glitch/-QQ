import Foundation

/// Thực thi lệnh shell cho terminal WQTerm.
///
/// Ưu tiên gọi thẳng hàm C `ios_system` (a-Shell) khi framework thật đã được nhúng.
/// Khi chỉ có stub (`Core/Shell/ios_system_stub.c` — luôn trả về -1), tự động
/// fallback sang `BuiltinShell` để terminal vẫn chạy được các lệnh cơ bản.
///
/// Đường dẫn binary a-Shell được dò qua `Bundle.main.path(forResource:ofType:)` để
/// hoạt động cả khi `Resources/` được copy dạng folder reference (không phải bundle).
@_silgen_name("ios_system")
private func ios_system(_ command: UnsafePointer<Int8>) -> Int32

enum CommandRunner {
    /// `true` khi `ios_system` thật đã được nhúng (stub trả về -1).
    static let isNativeShellAvailable: Bool = ios_system("true") >= 0

    /// Các thư mục có thể chứa binary/CLI của a-Shell trong bundle.
    static let shellSearchDirectories = [
        "Resources/ios_system",
        "Resources/node_modules/.bin",
        "Frameworks",
        ""
    ]

    /// Tên binary a-Shell đã gặp ở các bản đóng gói khác nhau.
    static let shellBinaryNames = ["ios_system", "a-shell", "ash", "bash"]

    /// Tìm binary a-Shell trong bundle bằng `Bundle.main.path(forResource:ofType:)`.
    ///
    /// - Returns: Đường dẫn tuyệt đối tới binary, hoặc `nil` khi chỉ có `BuiltinShell`.
    static func locateAShellBinary() -> String? {
        for directory in shellSearchDirectories {
            for name in shellBinaryNames {
                if let path = Bundle.main.path(forResource: name,
                                               ofType: nil,
                                               inDirectory: directory.isEmpty ? nil : directory) {
                    return path
                }
                // Fallback cho trường hợp Resources được copy dạng folder reference.
                let relative = directory.isEmpty ? name : "\(directory)/\(name)"
                let direct = Bundle.main.bundleURL.appendingPathComponent(relative).path
                if FileManager.default.fileExists(atPath: direct) {
                    return direct
                }
            }
        }
        return nil
    }

    /// Thư mục chứa các recipe `.sh` của a-Shell (nếu có).
    static var recipesDirectory: String? {
        Bundle.main.path(forResource: "Recipes", ofType: nil)
    }

    /// Mô tả backend đang dùng, hiển thị trên thanh trạng thái Terminal.
    static var backendLabel: String {
        isNativeShellAvailable ? "ios_system" : "builtin"
    }

    /// Chạy một lệnh, trả về mã thoát, output và thư mục làm việc mới.
    static func run(_ command: String, cwd: URL) -> (status: Int32, output: String, cwd: URL) {
        if isNativeShellAvailable {
            // ios_system thật ghi trực tiếp ra stdout của tiến trình.
            let status = command.withCString { ios_system($0) }
            return (status, "", cwd)
        }
        let result = BuiltinShell.shared.execute(command, cwd: cwd)
        return (result.status, result.text, result.cwd)
    }

    /// Tương thích API cũ: chạy trong Documents của ứng dụng, chỉ lấy (status, output).
    static func runCommand(_ cmd: String) -> (status: Int32, output: String) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let result = run(cmd, cwd: documents)
        return (result.status, result.output)
    }

    /// Bọc một chuỗi trong dấu nháy đơn an toàn cho shell.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

