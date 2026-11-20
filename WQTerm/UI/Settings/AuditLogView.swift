import SwiftUI

/// Trình xem audit log (M6) — mọi thao tác ghi đều được ghi lại.
struct AuditLogView: View {
    @State private var lines: [String] = []
    @State private var sharePayload: SharePayload?
    @State private var pendingClear = false

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView("Chưa có bản ghi",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Nhật ký sẽ xuất hiện sau thao tác ghi đầu tiên."))
            } else {
                List {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Nhật ký thao tác")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    export()
                } label: {
                    Label("Chia sẻ", systemImage: "square.and.arrow.up")
                }
                .disabled(lines.isEmpty)

                Button(role: .destructive) {
                    pendingClear = true
                } label: {
                    Label("Xoá nhật ký", systemImage: "trash")
                }
                .disabled(lines.isEmpty)
            }
        }
        .task { reload() }
        .refreshable { reload() }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
        .twoStepConfirm(
            title: "Xoá toàn bộ nhật ký?",
            message: "Nhật ký thao tác sẽ bị xoá vĩnh viễn.",
            isPresented: $pendingClear
        ) {
            AuditLogger.shared.clearLog()
            reload()
        }
    }

    // MARK: - Actions

    private func reload() {
        guard let url = AuditLogger.shared.exportLog(),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            lines = []
            return
        }
        lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func export() {
        guard let url = AuditLogger.shared.exportLog() else { return }
        sharePayload = SharePayload(url: url)
    }
}
