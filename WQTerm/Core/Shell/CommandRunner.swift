import Foundation

/// Thực thi lệnh shell qua ios_system (a-Shell fork) — đầu vào chính cho terminal WQTerm.
/// Trên iOS, Process("/bin/sh") bị giới hạn sandbox, do đó gọi trực tiếp hàm C `ios_system`
/// từ thư viện lõi nhúng trong Bundle (Resources/ios_system) để chạy các lệnh Unix native.
@_silgen_name("ios_system")
private func ios_system(_ command: UnsafePointer<Int8>) -> Int32

enum CommandRunner {
    /// Chạy một lệnh shell. Trả về (exit status, output).
    /// Lưu ý: ios_system ghi output ra stdout/stderr của tiến trình chủ; tại đây chúng ta
    /// lấy exit status. Output chi tiết được bắt bằng CommandExecutor sau khi redirect.
    static func runCommand(_ cmd: String) -> (status: Int32, output: String) {
        let status = cmd.withCString { ios_system($0) }
        return (status, "")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
