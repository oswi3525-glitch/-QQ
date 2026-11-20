import SwiftUI
import UIKit

/// `UIActivityViewController` cho SwiftUI — dùng chung cho mọi màn hình cần
/// chia sẻ file (IPA, pairing, audit log, backup).
///
/// Chỉ có **một** định nghĩa `ShareSheet` trong toàn app; trước đây mỗi màn hình
/// tự khai báo khiến `ShareSheet(items:)` bị ambiguous khi biên dịch.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Bọc `URL` để dùng với `.sheet(item:)`.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
