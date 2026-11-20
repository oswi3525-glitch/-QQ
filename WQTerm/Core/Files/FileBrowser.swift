import Foundation

/// Một mục trong trình duyệt file.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date

    var id: String { url.path }
    var fileExtension: String { url.pathExtension.lowercased() }
    var sizeLabel: String { isDirectory ? "—" : BuiltinShell.sizeLabel(size) }
}

/// Duyệt cây thư mục trong sandbox của chính ứng dụng.
///
/// Mọi đường dẫn được chuẩn hoá và giới hạn trong `root` — không thể thoát ra ngoài
/// bằng `..` hay symlink.
final class FileBrowser: ObservableObject {
    static let shared = FileBrowser()

    /// Thư mục gốc người dùng được phép duyệt: Documents của app.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @Published private(set) var currentDirectory: URL
    @Published private(set) var items: [FileItem] = []
    @Published var errorMessage: String?

    private let fm = FileManager.default
    private let root: URL

    init(root: URL = FileBrowser.defaultRoot) {
        self.root = root.standardizedFileURL
        self.currentDirectory = root.standardizedFileURL
        reload()
    }

    // MARK: - Navigation

    /// Đọc lại nội dung thư mục hiện tại.
    func reload() {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: currentDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Thư mục không tồn tại: \(currentDirectory.path)"
            items = []
            return
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: currentDirectory,
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []

        items = urls.compactMap { url -> FileItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(url: url,
                            name: url.lastPathComponent,
                            isDirectory: values?.isDirectory ?? false,
                            size: UInt64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        errorMessage = nil
    }

    /// Đi vào một thư mục con.
    func enter(_ item: FileItem) {
        guard item.isDirectory, let url = contained(item.url) else { return }
        currentDirectory = url
        reload()
    }

    /// Lên thư mục cha (không vượt quá `root`).
    func goUp() {
        guard currentDirectory.path != root.path else { return }
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(root.path) else { return }
        currentDirectory = parent
        reload()
    }

    /// Về thư mục gốc.
    func goToRoot() {
        currentDirectory = root
        reload()
    }

    var canGoUp: Bool { currentDirectory.path != root.path }

    /// Đường dẫn tương đối so với root, dùng hiển thị breadcrumb.
    var relativePath: String {
        let path = currentDirectory.path
        guard path.hasPrefix(root.path) else { return "/" }
        let suffix = String(path.dropFirst(root.path.count))
        return suffix.isEmpty ? "Documents" : "Documents" + suffix
    }

    // MARK: - Containment

    /// Trả về URL đã chuẩn hoá nếu nằm trong `root`, ngược lại `nil`.
    func contained(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        // Chống path traversal qua symlink: resolve cả đường dẫn thật.
        let resolved = standardized.resolvingSymlinksInPath()
        let rootResolved = root.resolvingSymlinksInPath()
        guard resolved.path == rootResolved.path || resolved.path.hasPrefix(rootResolved.path + "/") else {
            return nil
        }
        return standardized
    }
}

enum FileBrowserError: LocalizedError {
    case outsideRoot
    case invalidName

    var errorDescription: String? {
        switch self {
        case .outsideRoot: return "Đường dẫn nằm ngoài thư mục được phép truy cập."
        case .invalidName: return "Tên không hợp lệ (không được rỗng hoặc chứa '/')."
        }
    }
}

// MARK: - Mutations (đều đi qua snapshot engine)

extension FileBrowser {
    /// Xoá một mục. Với file đơn lẻ, tạo snapshot trước để có thể khôi phục.
    func delete(_ item: FileItem) throws {
        guard let url = contained(item.url) else { throw FileBrowserError.outsideRoot }
        if !item.isDirectory, fm.fileExists(atPath: url.path) {
            try SnapshotManager.shared.createSnapshot(for: url)
        }
        try fm.removeItem(at: url)
        AuditLogger.shared.log(event: .fileDelete(path: url.path))
        reload()
    }

    /// Tạo thư mục mới trong thư mục hiện tại.
    func createDirectory(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw FileBrowserError.invalidName }
        let url = currentDirectory.appendingPathComponent(trimmed, isDirectory: true)
        guard contained(url) != nil else { throw FileBrowserError.outsideRoot }
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
        reload()
    }

    /// Ghi nội dung text vào file, có snapshot write-ahead nếu file đã tồn tại.
    func saveText(_ text: String, to url: URL) throws {
        guard let url = contained(url) else { throw FileBrowserError.outsideRoot }
        try SnapshotManager.shared.writeAtomically(Data(text.utf8), to: url)
        reload()
    }

    /// Đọc nội dung file dạng text (nil nếu là nhị phân hoặc quá lớn).
    func readText(at url: URL) -> String? {
        guard let url = contained(url) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
