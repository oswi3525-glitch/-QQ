import Foundation
import QuickLook
import UIKit

/// QuickLook preview đa định dạng (PRD Module 7.1).
/// Giới hạn 50MB, blur sensitive, clear cache sau khi xem.
///
/// `QLPreviewController` **bắt buộc** có `dataSource`, nếu không sẽ hiện màn hình trắng.
/// Lớp này vừa là factory vừa là data source giữ danh sách URL.
final class QuickLookPreview: NSObject, QLPreviewControllerDataSource {
    static let shared = QuickLookPreview()
    private let maxSize: UInt64 = 50 * 1024 * 1024

    /// Các file đang được preview (QuickLook hỗ trợ nhiều item + vuốt chuyển).
    private var previewURLs: [URL] = []

    private override init() { super.init() }

    /// Định dạng QuickLook xử lý tốt trên iOS.
    static let supportedExtensions: Set<String> = [
        "pdf", "txt", "md", "html", "rtf", "doc", "docx", "xls", "xlsx",
        "png", "jpg", "jpeg", "heic", "gif", "mp4", "mov", "mp3", "wav", "csv"
    ]

    func canPreview(url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              UInt64(size) <= maxSize else { return false }
        return Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Tạo controller **đã gắn dataSource** (đây là lỗi của bản cũ: controller trắng).
    func makePreviewController(for url: URL) -> QLPreviewController? {
        guard canPreview(url: url) else { return nil }
        previewURLs = [url]
        let controller = QLPreviewController()
        controller.dataSource = self
        return controller
    }

    func preview(url: URL) -> QLPreviewController? {
        makePreviewController(for: url)
    }

    func clearCache() {
        previewURLs.removeAll()
    }

    // MARK: - QLPreviewControllerDataSource

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURLs.count
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        guard previewURLs.indices.contains(index) else {
            return NSURL(fileURLWithPath: "/dev/null")
        }
        return previewURLs[index] as NSURL
    }
}
