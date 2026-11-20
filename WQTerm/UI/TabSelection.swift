import SwiftUI

/// Điều khiển tab đang chọn từ bất kỳ màn hình con nào (Module 6).
///
/// Ví dụ: từ `AppDetailView` (tab Sandbox) bấm "Mở trong tab Files" cần chuyển
/// tab mà không phải truyền binding qua nhiều tầng NavigationStack.
final class TabSelection: ObservableObject {
    @Published var current: MainTabView.Tab = .terminal

    /// Đổi tab đang hiển thị.
    func select(_ tab: MainTabView.Tab) {
        current = tab
    }
}
