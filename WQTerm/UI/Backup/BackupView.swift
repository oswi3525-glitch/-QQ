import SwiftUI

/// Tab Backup (M3): xem, khôi phục và xoá các snapshot write-ahead.
struct BackupView: View {
    @State private var snapshots: [SnapshotManager.Snapshot] = []
    @State private var pendingRestore: SnapshotManager.Snapshot?
    @State private var pendingDelete: SnapshotManager.Snapshot?
    @State private var message: String?

    private var totalBytes: UInt64 { snapshots.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        NavigationStack {
            Group {
                if snapshots.isEmpty {
                    ContentUnavailableView {
                        Label("Chưa có bản backup", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Snapshot được tạo tự động mỗi khi bạn sửa hoặc xoá file.")
                    }
                } else {
                    snapshotList
                }
            }
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Label("Tải lại", systemImage: "arrow.clockwise")
                    }
                }
            }
            .alert("Khôi phục bản này?", isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ), presenting: pendingRestore) { snapshot in
                Button("Khôi phục") { restore(snapshot) }
                Button("Huỷ", role: .cancel) { pendingRestore = nil }
            } message: { snapshot in
                Text("Ghi đè \(URL(fileURLWithPath: snapshot.originalPath).lastPathComponent) "
                     + "bằng bản sao lúc \(snapshot.createdAt.formatted(date: .abbreviated, time: .standard)).")
            }
            .alert("Xoá bản backup này?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { snapshot in
                Button("Xoá", role: .destructive) { delete(snapshot) }
                Button("Huỷ", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("Thao tác này không thể hoàn tác.")
            }
            .alert("Thông báo", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .task { reload() }
            .refreshable { reload() }
        }
    }

    // MARK: - Sections

    private var snapshotList: some View {
        List {
            Section {
                HStack {
                    Label("\(snapshots.count) bản backup", systemImage: "externaldrive")
                    Spacer()
                    Text(BuiltinShell.sizeLabel(totalBytes))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1.0, Double(totalBytes) / Double(SnapshotManager.shared.maxTotalBytes)))
                    .tint(totalBytes > SnapshotManager.shared.maxTotalBytes / 2 ? .orange : .accentColor)
            } footer: {
                Text("Giới hạn \(BuiltinShell.sizeLabel(SnapshotManager.shared.maxTotalBytes)). "
                     + "Bản cũ nhất tự động bị xoá khi vượt hạn mức.")
            }

            Section("Bản sao lưu") {
                ForEach(snapshots) { snapshot in
                    Button {
                        pendingRestore = snapshot
                    } label: {
                        SnapshotRow(snapshot: snapshot)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = snapshot
                        } label: {
                            Label("Xoá", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        snapshots = SnapshotManager.shared.listSnapshots()
    }

    private func restore(_ snapshot: SnapshotManager.Snapshot) {
        pendingRestore = nil
        do {
            try SnapshotManager.shared.restore(snapshot)
            message = "Đã khôi phục: \(URL(fileURLWithPath: snapshot.originalPath).lastPathComponent)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func delete(_ snapshot: SnapshotManager.Snapshot) {
        pendingDelete = nil
        SnapshotManager.shared.deleteSnapshotFile(at: snapshot.snapshotURL)
        reload()
    }
}

/// Một dòng trong danh sách snapshot.
struct SnapshotRow: View {
    let snapshot: SnapshotManager.Snapshot

    private var fileName: String {
        URL(fileURLWithPath: snapshot.originalPath).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fileName)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(snapshot.createdAt, format: .dateTime.day().month().hour().minute().second())
                Text("•")
                Text(BuiltinShell.sizeLabel(snapshot.byteCount))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(snapshot.originalPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
