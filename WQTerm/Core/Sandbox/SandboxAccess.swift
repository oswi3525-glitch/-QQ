import Foundation
import Darwin

/// Cấp quyền đọc ngoài sandbox bằng `sandbox_extension_issue_file` (private).
///
/// Trên iOS không jailbreak, app bị khoá trong container của mình. Lỗ hổng
/// `worse_query` khiến kernel chấp nhận token sandbox extension do tiến trình
/// tự sinh — nhưng Apple có thể vá bất kỳ lúc nào, nên mọi hàm ở đây đều
/// **best-effort**: thất bại thì trả `false`, không bao giờ crash.
///
/// Token phải được giữ sống suốt vòng đời tiến trình, nếu không extension bị
/// thu hồi và lần đọc tiếp theo sẽ nhận `EPERM`.
enum SandboxAccess {
    /// Token đang giữ. Không được giải phóng — ARC không quản lý token kernel.
    private static var retainedTokens: [Int32] = []
    private static let lock = NSLock()

    /// `true` nếu `sandbox_extension_issue_file` gọi được trên thiết bị này.
    static let isAvailable: Bool = {
        sandboxExtensionIssue(path: "/", extensionClass: "com.apple.app-sandbox.read") != 0
    }()

    /// Số token đã cấp thành công (dùng cho màn hình chẩn đoán).
    static var issuedTokenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return retainedTokens.count
    }

    /// Xin quyền đọc cho một đường dẫn. Trả `true` nếu cấp được token.
    @discardableResult
    static func grantRead(to path: String) -> Bool {
        sandboxExtensionIssue(path: path, extensionClass: "com.apple.app-sandbox.read") != 0
    }

    /// Xin quyền đọc/ghi cho một đường dẫn.
    @discardableResult
    static func grantReadWrite(to path: String) -> Bool {
        sandboxExtensionIssue(path: path, extensionClass: "com.apple.app-sandbox.read-write") != 0
    }

    /// Gọi thẳng `sandbox_extension_issue_file` qua `dlsym`.
    ///
    /// Trả `0` khi: không tải được `libsystem_sandbox.dylib`, không tìm thấy
    /// symbol, hoặc kernel từ chối (iOS đã vá → `EPERM`).
    private static func sandboxExtensionIssue(path: String, extensionClass: String) -> Int32 {
        let libraries = [
            "/usr/lib/system/libsystem_sandbox.dylib",
            "/usr/lib/libsandbox.dylib"
        ]

        for library in libraries {
            guard let handle = dlopen(library, RTLD_LAZY) else { continue }
            defer { dlclose(handle) }
            guard let symbol = dlsym(handle, "sandbox_extension_issue_file") else { continue }

            typealias IssueFile = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> Int64
            let issue = unsafeBitCast(symbol, to: IssueFile.self)

            let token = extensionClass.withCString { klass in
                path.withCString { pathPointer in
                    issue(klass, pathPointer, 0)
                }
            }

            guard token > 0 else { continue }
            let token32 = Int32(truncatingIfNeeded: token)

            // Giữ token sống tới khi tiến trình kết thúc.
            lock.lock()
            retainedTokens.append(token32)
            lock.unlock()

            return token32
        }
        return 0
    }
}
