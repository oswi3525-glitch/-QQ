import Foundation
import Combine

/// Quản lý runtime nhúng (Node.js, Python) — Module 5.
///
/// Runtime nằm trong app bundle (`Resources/python-runtime/`,
/// `Resources/node-ios-arm64/`). iOS không cho thực thi binary trong bundle (bit
/// `x` bị strip khi build unsigned), nên lần đầu khởi động ta copy sang
/// `Documents/.terminal/RuntimeManager/` rồi `chmod 0755`; `setup_env.sh` trỏ PATH
/// vào bản copy đó.
final class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    @Published private(set) var availableRuntimes: [Runtime: Bool] = [:]
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: String?
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let queue = DispatchQueue(label: "com.wqterm.runtimes", qos: .utility)

    /// Gốc chứa runtime đã cài: `Documents/.terminal/RuntimeManager/`.
    var runtimeRoot: URL {
        documents.appendingPathComponent(".terminal/RuntimeManager", isDirectory: true)
    }

    private init() {
        refreshAvailability()
    }

    /// Đường dẫn binary của runtime (nil nếu chưa cài).
    func binaryURL(for runtime: Runtime) -> URL? {
        let url = runtimeRoot.appendingPathComponent(runtime.binaryRelativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Thư mục bin cần thêm vào PATH.
    func binDirectory(for runtime: Runtime) -> URL {
        binaryURL(for: runtime)?.deletingLastPathComponent()
            ?? runtimeRoot.appendingPathComponent(runtime.installedRelativePath)
    }

    /// Đọc lại trạng thái sẵn sàng của từng runtime.
    func refreshAvailability() {
        var result: [Runtime: Bool] = [:]
        for runtime in Runtime.allCases {
            result[runtime] = fileManager.fileExists(
                atPath: runtimeRoot.appendingPathComponent(runtime.binaryRelativePath).path)
        }
        let resolved = result
        DispatchQueue.main.async { self.availableRuntimes = resolved }
    }

    // MARK: - Cài runtime từ bundle

    /// Cài runtime từ bundle lần đầu chạy (idempotent, chạy nền).
    ///
    /// Gọi từ `EnvironmentSetup.prepareInBackground()` để runtime sẵn sàng trước
    /// khi người dùng mở Terminal.
    func installBundledRuntimesIfNeeded() {
        guard !isInstalling else { return }
        isInstalling = true
        installProgress = "Kiểm tra runtime nhúng…"

        queue.async { [weak self] in
            guard let self else { return }
            var installed: [String] = []

            for runtime in Runtime.allCases {
                let source = Bundle.main.bundleURL.appendingPathComponent(runtime.bundledRelativePath)
                guard self.fileManager.fileExists(atPath: source.path) else { continue }

                let destination = self.runtimeRoot.appendingPathComponent(
                    runtime.installedRelativePath, isDirectory: true)
                let binaryPath = destination.appendingPathComponent(
                    runtime.binaryRelativePath
                        .components(separatedBy: "/").dropFirst().joined(separator: "/")).path
                if self.fileManager.fileExists(atPath: binaryPath) { continue }

                DispatchQueue.main.async { self.installProgress = "Đang cài \(runtime.displayName)…" }
                do {
                    try? self.fileManager.createDirectory(at: self.runtimeRoot,
                                                          withIntermediateDirectories: true,
                                                          attributes: nil)
                    try? self.fileManager.removeItem(at: destination)
                    try FileSystem.copyTree(from: source, to: destination)
                    self.grantExecutePermissions(under: destination)
                    installed.append(runtime.displayName)
                } catch {
                    DispatchQueue.main.async {
                        self.lastError = "Không cài được \(runtime.displayName): "
                            + error.localizedDescription
                    }
                }
            }

            DispatchQueue.main.async {
                self.isInstalling = false
                self.installProgress = installed.isEmpty
                    ? nil
                    : "Đã cài runtime: \(installed.joined(separator: ", "))"
                self.refreshAvailability()
                if !installed.isEmpty { CommandRunner.prepareEnvironmentIfNeeded() }
            }
        }
    }

    /// Cấp quyền thực thi cho binary/launcher/framework trong cây runtime.
    ///
    /// Bắt buộc: build unsigned qua CI strip bit `x`, và dyld cần `x` để map dylib.
    private func grantExecutePermissions(under root: URL) {
        let executables = ["bin/node", "Library/bin/python3", "bin/python3"]
        for candidate in executables {
            let url = root.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: url.path)
            }
        }

        for directory in ["", "modules"] {
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
            let entries = (try? fileManager.contentsOfDirectory(at: folder,
                                                               includingPropertiesForKeys: nil,
                                                               options: [])) ?? []
            for entry in entries where entry.pathExtension == "framework" {
                let binary = entry.appendingPathComponent(entry.deletingPathExtension().lastPathComponent)
                if fileManager.fileExists(atPath: binary.path) {
                    try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: binary.path)
                }
            }
        }

        // Python launcher nhúng có thể là symlink tới `python3.9`.
        let python = root.appendingPathComponent("Library/bin/python3.9")
        if fileManager.fileExists(atPath: python.path) {
            try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                          ofItemAtPath: python.path)
        }
    }
}

