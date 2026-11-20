import Foundation
import Combine
import Darwin

/// Trình duyệt Files (Module 3): cây `~/Documents/` + `~/Documents/_sandbox/`.
///
/// Khác `FileBrowser` (chỉ duyệt Documents, chặn mọi symlink): lớp này **cho phép**
/// đi vào symlink trong `_sandbox` vì đó chính là mục đích của worse_query.
/// Mọi thao tác xoá vẫn đi qua snapshot write-ahead (PRD Nguyên tắc 3).
final class FilesBrowser: ObservableObject {
    static let shared = FilesBrowser()

    /// Hai gốc của cây thư mục.
    enum Root: String, CaseIterable, Identifiable {
        case documents
        case sandbox

        var id: String { rawValue }

        var title: String {
            switch self {
            case .documents: return "Documents"
            case .sandbox: return "_sandbox"
            }
        }

        var systemImage: String {
            switch self {
            case .documents: return "externaldrive"
            case .sandbox: return "link"
            }
        }

        var url: URL {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            switch self {
            case .documents:
                return documents.standardizedFileURL
            case .sandbox:
                return documents.appendingPathComponent("_sandbox", isDirectory: true)
                    .standardizedFileURL
            }
        }
    }

    @Published private(set) var root: Root = .documents
    @Published private(set) var currentDirectory: URL = Root.documents.url
    @Published private(set) var items: [FileNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Nhãn breadcrumb, ví dụ `["Documents", "_sandbox", "com.apple.Preferences"]`.
    @Published private(set) var pathComponents: [String] = ["Documents"]
    /// `true` khi thư mục hiện tại nằm ngoài sandbox của chính WQTerm.
    @Published private(set) var isInsideContainer = false

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.wqterm.files", qos: .userInitiated)
    /// Đánh số lần nạp để bỏ qua kết quả cũ về muộn.
    private var loadGeneration = 0

    private init() {
        createSandboxRoot()
        reload()
    }

    // MARK: - Navigation

    /// Chuyển gốc (Documents ⇄ _sandbox).
    func selectRoot(_ newRoot: Root) {
        root = newRoot
        currentDirectory = newRoot.url
        if newRoot == .sandbox { createSandboxRoot() }
        reload()
    }

    /// Đọc lại thư mục hiện tại — chạy trên background queue.
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let directory = currentDirectory

        isLoading = true
        errorMessage = nil

        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.readDirectory(directory)
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.items = result.items
                self.errorMessage = result.error
                self.isLoading = false
                self.updateBreadcrumb()
            }
        }
    }

    /// Đi vào một thư mục.
    func enter(_ node: FileNode) {
        guard node.isDirectory else { return }
        enter(directory: node.url)
    }

    /// Đi vào một URL thư mục bất kỳ (deep link từ tab Sandbox).
    func enter(directory url: URL) {
        let standardized = url.standardizedFileURL
        currentDirectory = standardized
        root = standardized.path.hasPrefix(Root.sandbox.url.path) ? .sandbox : .documents
        reload()
    }

    /// Lên thư mục cha, không vượt quá gốc của root hiện tại.
    func goUp() {
        let boundary = root.url.standardizedFileURL
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL

        if parent.path.count < boundary.path.count || parent.path == currentDirectory.path {
            currentDirectory = boundary
        } else {
            currentDirectory = parent
        }
        reload()
    }

    /// Về gốc của root hiện tại.
    func goToRoot() {
        currentDirectory = root.url
        reload()
    }

    var canGoUp: Bool {
        currentDirectory.standardizedFileURL.path != root.url.standardizedFileURL.path
    }

    // MARK: - Mutations

    /// Tạo thư mục mới trong thư mục hiện tại.
    func createDirectory(named rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw FileBrowserError.invalidName }
        let url = currentDirectory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
        reload()
    }

    /// Xoá một mục. File đơn lẻ được snapshot trước để có thể khôi phục (PRD §3).
    func delete(_ node: FileNode) throws {
        if !node.isDirectory, fileManager.fileExists(atPath: node.url.path) {
            try? SnapshotManager.shared.createSnapshot(for: node.url)
        }
        try fileManager.removeItem(at: node.url)
        AuditLogger.shared.log(event: .fileDelete(path: node.url.path))
        reload()
    }

    /// Đọc nội dung text (nil nếu nhị phân hoặc > 5MB).
    func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private struct DirectoryResult {
        let items: [FileNode]
        let error: String?
    }

    /// Đọc và sắp xếp nội dung thư mục. Chạy trên `queue`.
    private static func readDirectory(_ directory: URL) -> DirectoryResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return DirectoryResult(items: [], error: "Không mở được thư mục: \(directory.path)")
        }

        // Xin quyền đọc cho chính thư mục — cần khi duyệt vào container app khác.
        SandboxAccess.grantRead(to: directory.path)

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [])
        } catch {
            return DirectoryResult(items: [], error: friendlyError(error, path: directory.path))
        }

        let nodes = urls
            .filter { !$0.lastPathComponent.hasPrefix(".com.apple.mobile_container_manager") }
            .compactMap { FileNode.load($0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        return DirectoryResult(items: nodes, error: nil)
    }

    /// Thông báo lỗi dễ hiểu thay vì chuỗi NSError thô.
    private static func friendlyError(_ error: Error, path: String) -> String {
        let nsError = error as NSError
        if nsError.code == NSFileReadNoPermissionError || nsError.code == Int(EPERM)
            || nsError.code == Int(EACCES) {
            return "Không có quyền đọc \(path). iOS đã vá worse_query hoặc app chưa được mount."
        }
        return "Không đọc được \(path): \(nsError.localizedDescription)"
    }

    private func createSandboxRoot() {
        try? fileManager.createDirectory(at: Root.sandbox.url,
                                         withIntermediateDirectories: true, attributes: nil)
    }

    /// Tính nhãn breadcrumb và cờ `isInsideContainer`.
    private func updateBreadcrumb() {
        let path = currentDirectory.standardizedFileURL.path
        let sandboxPath = Root.sandbox.url.path
        let documentsPath = Root.documents.url.path

        if path == sandboxPath || path.hasPrefix(sandboxPath + "/") {
            let suffix = path == sandboxPath ? "" : String(path.dropFirst(sandboxPath.count + 1))
            pathComponents = ["Documents", "_sandbox"]
                + (suffix.isEmpty ? [] : suffix.components(separatedBy: "/"))
            isInsideContainer = true
            return
        }

        if path == documentsPath || path.hasPrefix(documentsPath + "/") {
            let suffix = path == documentsPath ? "" : String(path.dropFirst(documentsPath.count + 1))
            pathComponents = ["Documents"]
                + (suffix.isEmpty ? [] : suffix.components(separatedBy: "/"))
            isInsideContainer = false
            return
        }

        // Đã đi xuyên symlink vào container thật của app khác.
        pathComponents = ["Documents", "_sandbox"] + Array(currentDirectory.pathComponents.suffix(2))
        isInsideContainer = true
    }
}


