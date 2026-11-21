import SwiftUI

/// Dọn cache của các app đã mount (Module 2).
///
/// Luôn backup `Library/Caches` vào `Documents/.terminal/backups/cache-cleaner/`
/// trước khi xoá. Người dùng có thể chọn từng app và xem tổng dung lượng rác.
struct CacheCleanerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cleaner = CacheCleaner.shared
    @StateObject private var manager = SandboxManager.shared

    @State private var selected: Set<String> = []
    @State private var showConfirm = false
    @State private var message: String?

    private var selectedReports: [CacheReport] {
        cleaner.reports.filter { selected.contains($0.id) }
    }

    private var selectedBytes: UInt64 {
        selectedReports.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Dọn cache")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Xong") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            cleaner.scan(apps: manager.apps)
                        } label: {
                            Label("Quét lại", systemImage: "arrow.clockwise")
                        }
                        .disabled(cleaner.isScanning || cleaner.isCleaning)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .task {
                    if manager.apps.isEmpty { manager.bootstrap() }
                    cleaner.scan(apps: manager.apps)
                }
                .onChange(of: cleaner.reports) { _, reports in
                    selected = Set(reports.map(\.id))
                }
                .confirmationDialog("Dọn cache đã chọn?",
                                    isPresented: $showConfirm,
                                    titleVisibility: .visible) {
                    Button("Dọn \(BuiltinShell.sizeLabel(selectedBytes))", role: .destructive) {
                        clean()
                    }
                    Button("Huỷ", role: .cancel) {}
                } message: {
                    Text("Cache của \(selected.count) app sẽ được copy vào "
                         + "Documents/.terminal/backups/cache-cleaner/ trước khi xoá.")
                }
                .alert("Thông báo", isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )) {
                    Button("OK", role: .cancel) { message = nil }
                } message: {
                    Text(message ?? "")
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if cleaner.isScanning, cleaner.reports.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Đang quét Library/Caches của các app…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cleaner.reports.isEmpty {
            ContentUnavailableView {
                Label("Không có cache", systemImage: "sparkles")
            } description: {
                Text(cleaner.lastError
                     ?? "Không tìm thấy thư mục Library/Caches nào trong các app đã mount.")
            } actions: {
                Button("Quét lại") { cleaner.scan(apps: manager.apps) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    ForEach(cleaner.reports) { report in
                        row(for: report)
                    }
                } header: {
                    Text("Cache tìm thấy (\(cleaner.reports.count) app)")
                } footer: {
                    Text("Chỉ xoá nội dung Library/Caches. Backup được giữ trong "
                         + "Documents/.terminal/backups/cache-cleaner/.")
                        .font(.caption2)
                }

                if let result = cleaner.lastResult {
                    Section("Kết quả lần trước") {
                        LabeledContent("Đã dọn", value: "\(result.freedLabel) / \(result.cleanedApps) app")
                        if let backup = result.backupURL {
                            Text(backup.path)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        ForEach(result.failures, id: \.self) { failure in
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(for report: CacheReport) -> some View {
        Button {
            if selected.contains(report.id) {
                selected.remove(report.id)
            } else {
                selected.insert(report.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(report.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(report.id) ? Color.accentColor : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.appName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(report.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(report.cacheURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(report.sizeLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                    Text("\(report.fileCount) file")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let progress = cleaner.progressText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Đã chọn \(selected.count) app")
                        .font(.caption)
                    Text(BuiltinShell.sizeLabel(selectedBytes))
                        .font(.headline.monospacedDigit())
                }
                Spacer()
                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    if cleaner.isCleaning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Đang dọn…")
                        }
                    } else {
                        Label("Dọn dẹp", systemImage: "trash")
                    }
                }
                .liquidGlassButton()
                .disabled(selected.isEmpty || cleaner.isCleaning || cleaner.isScanning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func clean() {
        let ids = selected
        cleaner.clean(apps: manager.apps, bundleIDs: ids) { result in
            if result.cleanedApps == 0 {
                message = "Không dọn được app nào. " + (result.failures.first ?? "")
            } else {
                message = "Đã dọn \(result.freedLabel) từ \(result.cleanedApps) app. "
                    + "Backup: \(result.backupURL?.path ?? "—")"
            }
        }
    }
}
