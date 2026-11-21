import SwiftUI

/// Màn hình terminal chính (M1).
/// Transcript ở trên, ô nhập lệnh ở dưới — bàn phím hệ thống + thanh phím phụ
/// được gắn chuẩn qua `inputAccessoryView` của ô nhập.
struct TerminalView: View {
    @StateObject private var session = ShellSession.shared
    @StateObject private var preferences = AccessoryPreferences.shared
    @State private var isFocused = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                TerminalTranscriptView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .onTapGesture { isFocused = true }
                inputBar
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFocused = false
                    } label: {
                        Label("Ẩn bàn phím", systemImage: "keyboard.chevron.compact.down")
                    }
                    .disabled(!isFocused)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        session.clearHistory()
                    } label: {
                        Label("Xoá màn hình", systemImage: "trash")
                    }
                    .disabled(session.entries.isEmpty)
                }
            }
        }
        // Người dùng đổi cấu hình bàn phím phụ trong Settings → cập nhật ngay.
        .onChange(of: preferences.enabledGroups) { _, _ in
            isFocused = true
        }
    }

    // MARK: - Sections

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.relativeDirectoryLabel)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            shellBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var shellBadge: some View {
        let native = CommandRunner.isNativeShellAvailable
        return HStack(spacing: 4) {
            Circle()
                .fill(native ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(CommandRunner.backendLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(native
                            ? "Đang dùng shell ios_system (a-Shell)"
                            : "Đang dùng shell tích hợp BuiltinShell")
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text(session.promptText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
                    .lineLimit(1)
                TerminalInputRepresentable(session: session, isFocused: $isFocused)
                    .frame(height: 34)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

