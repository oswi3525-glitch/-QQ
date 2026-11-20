import Foundation

/// Cấu hình thanh phím phụ của terminal (PRD Module 5).
///
/// Người dùng bật/tắt từng nhóm phím trong Settings › Bàn phím phụ; lựa chọn
/// được lưu trong App Group để dùng lại ở mọi lần mở app.
final class AccessoryPreferences: ObservableObject {
    static let shared = AccessoryPreferences()

    /// Nhóm phím trên thanh phụ.
    enum Group: String, CaseIterable, Identifiable {
        case control      // ESC / TAB / Ctrl-C / Ctrl-D / Ctrl-L / Ctrl-Z
        case navigation   // ← ↑ ↓ → / HOME / END / PGUP / PGDN
        case clipboard    // COPY / PASTE / SELECT ALL / CLEAR

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .control: return "Điều khiển (ESC, TAB, Ctrl)"
            case .navigation: return "Điều hướng (mũi tên, Home/End)"
            case .clipboard: return "Clipboard (Copy, Paste)"
            }
        }

        /// Chỉ số hàng tương ứng trong `TerminalKey.rows`.
        var rowIndex: Int {
            switch self {
            case .control: return 0
            case .navigation: return 1
            case .clipboard: return 2
            }
        }
    }

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let prefix = "WQTerm.Accessory."

    /// Nhóm phím đang bật — thay đổi sẽ publish để TerminalView cập nhật ngay.
    @Published private(set) var enabledGroups: Set<Group>

    private init() {
        var enabled = Set<Group>()
        for group in Group.allCases where defaults.object(forKey: prefix + group.rawValue) == nil {
            enabled.insert(group)   // mặc định: bật đủ 3 nhóm
        }
        for group in Group.allCases where defaults.bool(forKey: prefix + group.rawValue) {
            enabled.insert(group)
        }
        enabledGroups = enabled
    }

    /// `true` nếu nhóm phím đang hiển thị.
    func isEnabled(_ group: Group) -> Bool {
        enabledGroups.contains(group)
    }

    /// Bật/tắt một nhóm phím.
    func setEnabled(_ enabled: Bool, for group: Group) {
        if enabled {
            enabledGroups.insert(group)
        } else {
            enabledGroups.remove(group)
        }
        defaults.set(enabled, forKey: prefix + group.rawValue)
    }

    /// Các hàng phím thực sự được hiển thị, theo thứ tự khai báo trong `TerminalKey`.
    var visibleRows: [[TerminalKey.Item]] {
        Group.allCases
            .filter { isEnabled($0) }
            .sorted { $0.rowIndex < $1.rowIndex }
            .compactMap { group in
                TerminalKey.rows.indices.contains(group.rowIndex) ? TerminalKey.rows[group.rowIndex] : nil
            }
    }
}
