import SwiftUI

/// Cấu hình thanh phím phụ (M5).
struct AccessorySettingsView: View {
    @StateObject private var preferences = AccessoryPreferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(AccessoryPreferences.Group.allCases) { group in
                    Toggle(isOn: Binding(
                        get: { preferences.isEnabled(group) },
                        set: { preferences.setEnabled($0, for: group) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName)
                            Text(groupPreview(group))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Nhóm phím hiển thị")
            } footer: {
                Text("Thanh phím phụ được gắn vào inputAccessoryView của ô nhập lệnh. "
                     + "ESC gửi 0x1B, TAB gửi 0x09, CTRL + phím chuyển thành mã điều khiển tương ứng.")
                    .font(.caption2)
            }

            Section {
                HStack {
                    Text("Phím đang bật")
                    Spacer()
                    Text("\(preferences.visibleRows.count) hàng")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Thay đổi có hiệu lực ngay khi quay lại tab Terminal.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Bàn phím phụ")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Nhãn các phím trong một nhóm, ví dụ "ESC · TAB · CTRL · ALT".
    private func groupPreview(_ group: AccessoryPreferences.Group) -> String {
        guard TerminalKey.rows.indices.contains(group.rowIndex) else { return "" }
        return TerminalKey.rows[group.rowIndex].map(\.label).joined(separator: " · ")
    }
}
