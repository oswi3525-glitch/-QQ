import Foundation
import Darwin

/// Thực thi lệnh shell cho terminal WQTerm.
///
/// Ưu tiên nạp **toolchain a-Shell thật** (`ios_system.framework` + các framework
/// lệnh Unix) nằm trong `Resources/toolchain/`. Chúng được `dlopen` lúc chạy nên
/// bản build unsigned vẫn chạy được, app không phụ thuộc link tĩnh.
///
/// Khi dlopen/dlsym thất bại (framework chưa nhúng, sai kiến trúc, iOS chặn),
/// tự động fallback sang `BuiltinShell` — Swift thuần, luôn hoạt động.
enum CommandRunner {

    /// Kết quả nạp toolchain. Cache để không dlopen lại mỗi lệnh.
    private struct NativeShell {
        let isAvailable: Bool
        let execute: (@convention(c) (UnsafePointer<CChar>) -> Int32)?
        let handle: UnsafeMutableRawPointer?
        let loadedFrameworks: [String]
    }

    private static let native: NativeShell = loadNativeShell()

    /// `true` khi dispatcher `ios_system` thật đã nạp được.
    static var isNativeShellAvailable: Bool { native.isAvailable }

    /// Danh sách framework đã nạp thành công (hiển thị trong Settings).
    static var loadedFrameworks: [String] { native.loadedFrameworks }

    /// Các thư mục có thể chứa binary/CLI trong bundle.
    static let shellSearchDirectories = [
        "Resources/toolchain",
        "Resources/ios_system",
        "Frameworks"
    ]

    /// Tên binary a-Shell đã gặp ở các bản đóng gói khác nhau.
    static let shellBinaryNames = ["ios_system", "a-shell", "ash", "bash"]

    /// Tìm binary a-Shell trong bundle bằng `Bundle.main.path(forResource:ofType:)`.
    static func locateAShellBinary() -> String? {
        for directory in shellSearchDirectories {
            for name in shellBinaryNames {
                if let path = Bundle.main.path(forResource: name,
                                               ofType: nil,
                                               inDirectory: directory) {
                    return path
                }
                let relative = "\(directory)/\(name)"
                let direct = Bundle.main.bundleURL.appendingPathComponent(relative).path
                if FileManager.default.fileExists(atPath: direct) { return direct }
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
        isNativeShellAvailable
            ? "ios_system (\(native.loadedFrameworks.count) framework)"
            : "builtin"
    }

    // MARK: - Nạp framework

    /// `dlopen` toolchain a-Shell và lấy con trỏ hàm `ios_system`.
    ///
    /// Thứ tự nạp quan trọng: các framework lệnh (`shell`, `text`, `files`, `tar`,
    /// `awk`) tự đăng ký command qua constructor nên phải nạp **trước** dispatcher.
    private static func loadNativeShell() -> NativeShell {
        let frameworkNames = ["shell", "text", "files", "tar", "awk", "ios_system"]
        var loaded: [String] = []
        var dispatcherHandle: UnsafeMutableRawPointer?

        for name in frameworkNames {
            guard let path = frameworkBinaryPath(named: name) else { continue }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else { continue }
            loaded.append(name)
            if name == "ios_system" { dispatcherHandle = handle }
        }

        guard let handle = dispatcherHandle,
              let symbol = dlsym(handle, "ios_system") else {
            return NativeShell(isAvailable: false, execute: nil,
                               handle: nil, loadedFrameworks: loaded)
        }

        typealias Execute = @convention(c) (UnsafePointer<CChar>) -> Int32
        let execute = unsafeBitCast(symbol, to: Execute.self)

        // a-Shell cần cờ này để mở khoá toàn bộ command dictionary.
        if let flag = dlsym(handle, "sideLoading") {
            flag.assumingMemoryBound(to: Bool.self).pointee = true
        }

        // Đẩy PATH/HOME/TMPDIR vào môi trường của ios_system.
        if let setEnvSymbol = dlsym(handle, "ios_setenv") {
            typealias SetEnv = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> Int32
            let setEnvironment = unsafeBitCast(setEnvSymbol, to: SetEnv.self)
            for (key, value) in EnvironmentSetup.shared.environment {
                key.withCString { keyPointer in
                    value.withCString { valuePointer in
                        _ = setEnvironment(keyPointer, valuePointer, 1)
                    }
                }
            }
        }

        // Kiểm tra thật: chạy `true`, mã thoát 0 là dispatcher hoạt động.
        let probe = "true".withCString { execute($0) }
        guard probe == 0 else {
            return NativeShell(isAvailable: false, execute: nil,
                               handle: handle, loadedFrameworks: loaded)
        }

        return NativeShell(isAvailable: true, execute: execute,
                           handle: handle, loadedFrameworks: loaded)
    }

    /// Đường dẫn tuyệt đối tới binary bên trong `X.framework` nằm trong bundle.
    private static func frameworkBinaryPath(named name: String) -> String? {
        let candidates = [
            "Resources/toolchain/\(name).framework/\(name)",
            "Resources/toolchain/\(name).xcframework/ios-arm64/\(name).framework/\(name)",
            "Frameworks/\(name).framework/\(name)"
        ]
        for relative in candidates {
            let path = Bundle.main.bundleURL.appendingPathComponent(relative).path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Execution

    /// Chạy một lệnh, trả về mã thoát, output và thư mục làm việc mới.
    ///
    /// Trước lần chạy đầu tiên, `EnvironmentSetup` được chuẩn bị đồng bộ để
    /// `setup_env.sh` và `bin/` tồn tại — nhờ vậy người dùng gõ lệnh là chạy được
    /// ngay (Module 5), không cần export PATH thủ công.
    static func run(_ command: String, cwd: URL) -> (status: Int32, output: String, cwd: URL) {
        prepareEnvironmentIfNeeded()

        if native.isAvailable, let execute = native.execute {
            // ios_system ghi trực tiếp ra stdout của tiến trình; bọc `cd` để giữ
            // đúng thư mục làm việc.
            let wrapped = "cd \(shellQuote(cwd.path)) && \(command)"
            let status = wrapped.withCString { execute($0) }
            return (status, "", cwd)
        }

        let result = BuiltinShell.shared.execute(command, cwd: cwd)
        return (result.status, result.text, result.cwd)
    }

    /// Chuẩn bị môi trường đúng một lần cho mỗi phiên chạy app.
    private static let environmentLock = NSLock()
    private static var hasPreparedEnvironment = false

    static func prepareEnvironmentIfNeeded() {
        environmentLock.lock()
        defer { environmentLock.unlock() }
        guard !hasPreparedEnvironment else { return }
        hasPreparedEnvironment = true

        let setup = EnvironmentSetup.shared
        _ = try? setup.prepare()
        setup.installAIScript()
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
