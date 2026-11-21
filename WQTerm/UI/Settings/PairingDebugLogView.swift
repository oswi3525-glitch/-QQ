import SwiftUI
import UIKit

/// Xem log riêng của từng giai đoạn pairing (không lẫn audit log ghi file).
struct PairingDebugLogView: View {
    @ObservedObject private var logger = PairingLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if logger.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Chưa có log", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Log được tạo khi bạn bật Pairing Host hoặc chạy kiểm tra kết nối.")
                    }
                } else {
                    List(logger.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(color(for: entry.level))
                                    .frame(width: 6, height: 6)
                                Text(entry.stage)
                                    .font(.caption2.bold().monospaced())
                                Spacer()
                                Text(Self.timeFormatter.string(from: entry.date))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .font(.caption)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Pairing debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Xong") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareURL = logger.exportURL()
                    } label: {
                        Label("Chia sẻ", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: Binding(
                get: { shareURL.map(ShareItem.init) },
                set: { if $0 == nil { shareURL = nil } }
            )) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func color(for level: PairingLogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
