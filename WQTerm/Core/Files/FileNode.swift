import Foundation

/// Một mục trong trình duyệt Files (Module 3).
///
/// Khác `FileItem` ở chỗ hỗ trợ **symlink** — cần thiết vì `_sandbox/<bundle-id>`
/// là symlink tới container của app khác. Nhờ vậy tab Files duyệt được vào
/// trong container đó thay vì chỉ thấy một "file" lạ.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modified: Date

    var id: String { url.path }
    var fileExtension: String { url.pathExtension.lowercased() }
    var sizeLabel: String { isDirectory ? "—" : BuiltinShell.sizeLabel(size) }

    /// Icon theo loại file — dùng lại định tuyến của `PreviewRouter`.
    var systemImage: String {
        if isDirectory { return isSymlink ? "folder.badge.gearshape" : "folder.fill" }
        return PreviewRouter.kind(for: url).systemImage
    }

    init(url: URL,
         isDirectory: Bool,
         isSymlink: Bool,
         size: UInt64,
         modified: Date) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
    }

    /// Đọc metadata của `url`; trả `nil` nếu không truy cập được.
    static func load(_ url: URL) -> FileNode? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Symlink hỏng vẫn hiện được (để người dùng xoá) nhưng không có metadata.
            return FileNode(url: url, isDirectory: false, isSymlink: true, size: 0,
                            modified: .distantPast)
        }

        let isSymlink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false

        if isSymlink, !isDirectory {
            // Symlink tới thư mục: `resourceValues` không follow với isDirectoryKey
            // trên mọi phiên bản iOS, nên kiểm tra lại bằng `fileExists`.
            var flag = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) {
                isDirectory = flag.boolValue
            }
        }

        return FileNode(url: url,
                        isDirectory: isDirectory,
                        isSymlink: isSymlink,
                        size: UInt64(values.fileSize ?? 0),
                        modified: values.contentModificationDate ?? .distantPast)
    }
}
