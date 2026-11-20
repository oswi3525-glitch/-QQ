import SwiftUI
import UIKit

/// Tab Sandbox (Module 1 & 2): danh sách app đã cài + mount container + Dump IPA.
///
/// Toàn bộ tác vụ nặng (quét, mount, dump) chạy trên `SandboxManager.workQueue`;
/// view chỉ hiển thị trạng thái `@Published`, nên chuyển tab không bị treo (Module 6).
struct SandboxView: View {
    @StateObject private var manager = SandboxManager.shared
    @StateObject private var dumper = IPADumper.shared

    @State private var searchText = ""
    @State private var pendingDump: InstalledApp?
    @State private var shareURL: URL?
    @State private var progressMessage = ""
    @State private var errorMessage: String?

    private var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return manager.apps }
        return manager.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sandbox")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Tìm app hoặc bundle ID")
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
                .task { manager.bootstrap() }
                .refreshable { manager.bootstrap(force: true) }
                .confirmationDialog(
                    "Dump IPA cho \(pendingDump?.name ?? "")?",
                    isPresented: Binding(get: { pendingDump != nil },
                                         set: { if !$0 { pendingDump = nil } }),
                    titleVisibility: .visible,
                    presenting: pendingDump
                ) { app in
                    Button("Dump IPA") { startDump(app) }
                    Button("Huỷ", role: .cancel) { pendingDump = nil }
                } message: { app in
                    Text("Bundle .app (\(BuiltinShell.sizeLabel(app.bundleSizeBytes))) sẽ được copy "
                         + "vào Payload/ rồi nén thành .ipa trong Documents.")
                }
                .sheet(item: Binding(
                    get: { shareURL.map(ShareItem.init) },
                    set: { if $0 == nil { shareURL = nil } }
                )) { item in
                    ShareSheet(items: [item.url])
                }
                .alert("Thông báo", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }
    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if manager.isScanning, manager.apps.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Đang quét /var/containers/Bundle/Application…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.apps.isEmpty {
            ContentUnavailableView {
                Label("Không đọc được danh sách app", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text(manager.lastError
                     ?? "Cần App Group group.com.wqterm.app và iOS còn khai thác được worse_query.")
            } actions: {
                Button("Quét lại") { manager.bootstrap(force: true) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            appList
        }
    }

    private var appList: some View {
        List {
            Section {
                ForEach(filteredApps) { app in
                    NavigationLink {
                        AppDetailView(app: app, onDump: { pendingDump = app })
                    } label: {
                        AppRow(app: app,
                               state: manager.mountStates[app.bundleID] ?? .notMounted,
                               isDumping: dumper.isDumping) {
                            pendingDump = app
                        }
                    }
                    .disabled(dumper.isDumping)
                }
            } header: {
                Text("Ứng dụng đã cài (\(filteredApps.count)/\(manager.apps.count))")
            } footer: {
                Text("Bấm vào app để duyệt container. Nút hộp để dump IPA ra Documents.")
                    .font(.caption2)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Banner trạng thái

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = manager.progressText ?? (dumper.isDumping ? progressMessage : nil) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(manager.isSupportedOS ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(manager.compatibilitySummary)
                        .font(.caption)
                    Spacer()
                    Text("\(manager.mountedBundleIDs.count) mount")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    manager.bootstrap(force: true)
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                }
                Button {
                    manager.mountAllContainers()
                } label: {
                    Label("Mount lại toàn bộ", systemImage: "link")
                }
                NavigationLink {
                    ContainerBrowserView()
                } label: {
                    Label("Mount theo bundle ID", systemImage: "link.badge.plus")
                }
            } label: {
                Label("Tuỳ chọn", systemImage: "ellipsis.circle")
            }
            .disabled(manager.isScanning || manager.isMounting)
        }
    }

    // MARK: - Actions

    private func startDump(_ app: InstalledApp) {
        pendingDump = nil
        progressMessage = "Chuẩn bị dump \(app.name)…"

        dumper.dumpInBackground(app, progress: { message in
            progressMessage = message
        }, completion: { result in
            switch result {
            case .success(let dump):
                progressMessage = ""
                shareURL = dump.ipaURL
            case .failure(let error):
                progressMessage = ""
                errorMessage = error.localizedDescription
            }
        })
    }
}

/// Chi tiết một app: metadata, đường dẫn container, nút mở bằng tab Files.
struct AppDetailView: View {
    let app: InstalledApp
    let onDump: () -> Void

    @StateObject private var manager = SandboxManager.shared
    @EnvironmentObject private var tabSelection: TabSelection
    @State private var errorMessage: String?

    private var state: MountState { manager.mountStates[app.bundleID] ?? .notMounted }

    var body: some View {
        List {
            Section {
                LabeledContent("Tên", value: app.name)
                LabeledContent("Bundle ID", value: app.bundleID)
                LabeledContent("Phiên bản", value: app.versionLabel)
                LabeledContent("Kích thước", value: BuiltinShell.sizeLabel(app.bundleSizeBytes))
            } header: {
                Text("Thông tin")
            }

            Section {
                Text(app.bundleURL.path)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                if let container = app.dataContainerURL {
                    Text(container.path)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Đường dẫn")
            } footer: {
                Text("Icon: \(app.iconURL?.lastPathComponent ?? "không tìm thấy")")
                    .font(.caption2)
            }

            Section {
                switch state {
                case .mounted:
                    Label("Đã mount — duyệt được từ tab Files", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                case .notMounted:
                    Label("Chưa mount", systemImage: "circle.dashed")
                        .font(.caption)
                }

                Button {
                    manager.mountContainer(bundleID: app.bundleID)
                } label: {
                    Label("Mount lại container", systemImage: "link")
                }

                if let mountedURL = manager.mountedURL(for: app.bundleID) {
                    Button {
                        FilesBrowser.shared.enter(directory: mountedURL)
                        tabSelection.select(.files)
                    } label: {
                        Label("Mở trong tab Files", systemImage: "folder")
                    }

                    NavigationLink {
                        MountedContainerView(bundleID: app.bundleID)
                    } label: {
                        Label("Duyệt tại đây", systemImage: "list.bullet")
                    }
                }

                NavigationLink {
                    ContainerBrowserView()
                } label: {
                    Label("Nhập bundle ID khác", systemImage: "link.badge.plus")
                }
            } header: {
                Text("Mount")
            }

            Section {
                Button(action: onDump) {
                    Label("Dump IPA", systemImage: "shippingbox.and.arrow.backward")
                }
            } footer: {
                Text("Copy .app → Payload/ → nén .ipa trong Documents → mở bảng chia sẻ để lưu ra Files.")
                    .font(.caption2)
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Lỗi", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}


