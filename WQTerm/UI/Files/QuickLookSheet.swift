import SwiftUI
import QuickLook

/// QuickLook dạng sheet cho ảnh / video / PDF (Module 3).
///
/// `QLPreviewController` bắt buộc có `dataSource`; `QuickLookPreview.shared` đã
/// cấu hình sẵn nên không còn màn hình trắng như bản cũ.
struct QuickLookSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIViewController {
        if let controller = QuickLookPreview.shared.makePreviewController(for: url) {
            return controller
        }
        let fallback = UIViewController()
        fallback.view.backgroundColor = .systemBackground
        return fallback
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
