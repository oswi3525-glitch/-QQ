import Foundation
import Combine

/// Thiết lập môi trường dòng lệnh (Module 5 — Toolchain beyond a-Shell).
///
/// Vấn đề: iOS không có `/bin/sh`, và binary trong bundle nằm ở đường dẫn thay đổi
/// theo thiết bị. Người dùng gõ `curl …` phải chạy được ngay mà không cần export
/// PATH thủ công.
///
/// Giải pháp:
/// 1. Mỗi lần khởi động, sinh `Documents/.terminal/setup_env.sh` chứa PATH đầy đủ
///    và các alias trỏ tới binary trong bundle.
/// 2. Các binary trong bundle được copy sang `Documents/.terminal/bin/` và **cấp
///    quyền thực thi** (`0755`) — iOS không cho chmod file trong bundle.
/// 3. `TerminalView` gọi `source setup_env.sh` (hoặc `EnvironmentSetup.shared.load()`)
///    trước lệnh đầu tiên để mọi lệnh có sẵn.
final class EnvironmentSetup: ObservableObject {
    static let shared = EnvironmentSetup()

    /// Thư mục chứa binary có thể thực thi do người dùng chạy.
    let binDirectory: URL
    /// Thư mục cấu hình của terminal (`~/.terminal`).
    let configDirectory: URL
    /// Đường dẫn file môi trường.
    let scriptURL: URL

    /// Các công cụ người dùng thấy trong `help` và `which`.
    @Published private(set) var availableTools: [ToolInfo] = []
    /// `true` khi script đã được sinh cho phiên hiện tại.
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?

    /// Mô tả một công cụ trong toolchain.
    struct ToolInfo: Identifiable, Hashable {
        let name: String
        let kind: Kind
        let detail: String

        var id: String { name }

        enum Kind: String {
            case builtin     // do BuiltinShell xử lý
            case bundled     // binary trong app bundle (đã cấp quyền thực thi)
            case runtime     // node/python trong Documents/.terminal/RuntimeManager
            case missing

            var isAvailable: Bool { self != .missing }
        }

        var systemImage: String {
            switch kind {
            case .builtin: return "terminal"
            case .bundled: return "shippingbox"
            case .runtime: return "cpu"
            case .missing: return "xmark.circle"
            }
        }
    }

    private let fileManager = FileManager.default
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private init() {
        configDirectory = documents.appendingPathComponent(".terminal", isDirectory: true)
        binDirectory = configDirectory.appendingPathComponent("bin", isDirectory: true)
        scriptURL = configDirectory.appendingPathComponent("setup_env.sh")
    }

    // MARK: - Public API

    /// Sinh lại `setup_env.sh` + thư mục `bin`, cấp quyền thực thi cho binary.
    ///
    /// Gọi từ `AppDelegate` lúc khởi động và từ nút "Thiết lập lại" trong Settings.
    /// Chạy nền vì phải quét bundle; UI nhận cập nhật qua `@Published`.
    func prepareInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let script = try self.prepare()
                DispatchQueue.main.async {
                    self.isReady = true
                    self.lastError = nil
                    self.scriptPreview = script
                }
                // Cài runtime nhúng (Python/Node) nếu bundle có — cần trước khi
                // PATH được dùng thật trong Terminal.
                RuntimeManager.shared.installBundledRuntimesIfNeeded()
            } catch {
                DispatchQueue.main.async {
                    self.isReady = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Phiên bản đồng bộ (dùng cho unit check và lần chạy đầu trong Terminal).
    @discardableResult
    func prepare() throws -> String {
        try fileManager.createDirectory(at: configDirectory,
                                        withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: binDirectory,
                                        withIntermediateDirectories: true, attributes: nil)

        let tools = scanTools()
        let script = renderScript(tools: tools)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                       ofItemAtPath: scriptURL.path)

        let resolved = tools
        DispatchQueue.main.async {
            self.availableTools = resolved
            self.scriptPreview = script
            self.isReady = true
            self.lastError = nil
        }
        return script
    }

    /// Nội dung `setup_env.sh` đang dùng (cho màn hình Settings xem trước).
    @Published private(set) var scriptPreview: String = ""

    /// PATH đầy đủ của phiên hiện tại.
    var pathValue: String {
        renderPath(prefixes: [binDirectory.path,
                              RuntimeManager.shared.binDirectory(for: .node).path,
                              RuntimeManager.shared.binDirectory(for: .python).path])
    }

    /// Biến môi trường để truyền cho tiến trình con khi chạy binary.
    var environment: [String: String] {
        [
            "PATH": pathValue,
            "HOME": documents.path,
            "TMPDIR": NSTemporaryDirectory(),
            "WQTERM_HOME": configDirectory.path,
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color"
        ]
    }

    // MARK: - Tool discovery

    /// Các lệnh Unix mà Terminal phải có (Module 5).
    static let requiredTools = ["curl", "wget", "tar", "unzip", "zip", "git", "ffmpeg", "python3", "node"]

    /// Quét toolchain: builtin → bundle → runtime.
    func scanTools() -> [ToolInfo] {
        var result: [ToolInfo] = []

        // 1. Lệnh do BuiltinShell xử lý.
        for name in BuiltinShell.commandNames.sorted() {
            result.append(ToolInfo(name: name, kind: .builtin,
                                   detail: "BuiltinShell (chạy trong tiến trình)"))
        }

        // 2. Lệnh AI do app cung cấp.
        result.append(ToolInfo(name: "ai", kind: .builtin, detail: "Gọi LiteRouter qua AI service"))

        // 3. Binary nhúng trong app bundle → copy ra bin/ + chmod 0755.
        for name in Self.requiredTools where !result.contains(where: { $0.name == name }) {
            result.append(installBundledTool(named: name)
                          ?? ToolInfo(name: name, kind: .missing,
                                      detail: "Chưa nhúng binary vào app bundle"))
        }

        return result.sorted { $0.name < $1.name }
    }

    /// Tìm binary trong bundle và cài vào `bin/` với quyền thực thi.
    ///
    /// iOS giữ quyền file trong bundle, nhưng bản build unsigned qua CI có thể mất
    /// bit `x`; copy ra Documents rồi chmod là cách chắc chắn nhất.
    func installBundledTool(named name: String) -> ToolInfo? {
        let searchDirectories = ["Resources/bin", "Resources/toolchain/bin",
                                 "Resources/ios_system", "bin"]

        for directory in searchDirectories {
            guard let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: directory) else {
                continue
            }
            let destination = binDirectory.appendingPathComponent(name)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(atPath: path, toPath: destination.path)
                try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: destination.path)
                return ToolInfo(name: name, kind: .bundled,
                                detail: "Bundle: \(directory)/\(name) → .terminal/bin/")
            } catch {
                return ToolInfo(name: name, kind: .bundled,
                                detail: "Có trong bundle nhưng chưa copy được: \(error.localizedDescription)")
            }
        }

        // Runtime nhúng (node/python) nằm trong Documents.
        for runtime in Runtime.allCases where runtime.rawValue == name {
            if let url = RuntimeManager.shared.binaryURL(for: runtime) {
                return ToolInfo(name: name, kind: .runtime, detail: url.path)
            }
        }
        return nil
    }

    // MARK: - Script rendering

    /// Sinh nội dung `setup_env.sh` từ danh sách tool.
    func renderScript(tools: [ToolInfo]) -> String {
        let runtimeNode = RuntimeManager.shared.binDirectory(for: .node).path
        let runtimePython = RuntimeManager.shared.binDirectory(for: .python).path
        let path = renderPath(prefixes: [binDirectory.path, runtimeNode, runtimePython])

        var lines: [String] = [
            "#!/bin/sh",
            "# WQTerm environment — sinh tự động \(ISO8601DateFormatter().string(from: Date()))",
            "# Source file này để có PATH + alias: . \(scriptURL.path)",
            "",
            "export HOME=\(shellQuote(documents.path))",
            "export WQTERM_HOME=\(shellQuote(configDirectory.path))",
            "export PATH=\(shellQuote(path))",
            "export LANG=en_US.UTF-8",
            "export TERM=xterm-256color",
            "",
            "# Runtime nhúng",
            "export NODE_PATH=\(shellQuote(runtimeNode + "/../lib/node_modules"))",
            "export PYTHONHOME=\(shellQuote(runtimePython + "/.."))",
            ""
        ]

        let missing = tools.filter { $0.kind == .missing }.map(\.name)
        if !missing.isEmpty {
            lines.append("# Chưa có binary: \(missing.joined(separator: ", "))")
        }

        lines.append("# Alias tiện dụng")
        lines.append("alias ll='ls -l'")
        lines.append("alias la='ls -la'")
        lines.append("alias ask='python3 \"$WQTERM_HOME/ai.py\"'")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// Ghép PATH với các tiền tố ưu tiên, giữ đường dẫn hệ thống chuẩn.
    func renderPath(prefixes: [String]) -> String {
        var parts = prefixes.filter { !$0.isEmpty }
        for standard in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"]
        where !parts.contains(standard) {
            parts.append(standard)
        }
        return parts.joined(separator: ":")
    }

    /// Đường dẫn thư mục bin của runtime nhúng.
    func runtimeBinPath(_ relative: String) -> String {
        documents.appendingPathComponent(".terminal/RuntimeManager/\(relative)").path
    }

    /// Bọc chuỗi trong nháy đơn cho shell.
    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Cài `ai.py` từ bundle vào `~/.terminal/` để Terminal gọi được.
    ///
    /// Script dùng `requests` (pure-Python) thay vì `openai` để tránh lỗi
    /// C-extension trên Python nhúng của a-Shell (Module 4).
    @discardableResult
    func installAIScript() -> Bool {
        let destination = configDirectory.appendingPathComponent("ai.py")
        if fileManager.fileExists(atPath: destination.path) { return true }

        let source = Bundle.main.path(forResource: "ai", ofType: "py", inDirectory: "Resources/Scripts")
            ?? Bundle.main.path(forResource: "ai", ofType: "py")
        guard let source else { return false }

        do {
            try fileManager.createDirectory(at: configDirectory,
                                            withIntermediateDirectories: true, attributes: nil)
            try fileManager.copyItem(atPath: source, toPath: destination.path)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                          ofItemAtPath: destination.path)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}


