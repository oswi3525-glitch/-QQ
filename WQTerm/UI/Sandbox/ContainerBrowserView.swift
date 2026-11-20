import SwiftUI

/// Trình duyệt container của app khác (M2 — WorseQuery mount).
///
/// Tách khỏi `SandboxView` (chỉ duyệt Documents của chính app) để người dùng thấy rõ
/// ranh giới: mục này chỉ liệt kê những container đã mount qua worse_query.
struct ContainerBrowserView: View {
    @State private var mounted: [String] = []
    @State private var bundleIDInput = ""
    @State private var message: String?
    @State private var pendingSensitive: String?

    private let mounter = SandboxMounter.shared

    var body: some View {
        List {
            mountSection
            mountedSection
        }
        .navigationTitle("Container")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .alert("Thông báo", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("Ứng dụng nhạy cảm", isPresented: Binding(
            get: { pendingSensitive != nil },
            set: { if !$0 { pendingSensitive = nil } }
        ), presenting: pendingSensitive) { bundleID in
            Button("Vẫn mount", role: .destructive) { performMount(bundleID) }
            Button("Huỷ", role: .cancel) { pendingSensitive = nil }
        } message: { bundleID in
            Text(SensitiveAppGuard.shared.warningMessage(for: bundleID))
        }
    }

    // MARK: - Sections

    private var mountSection: some View {
        Section {
            TextField("com.example.app", text: $bundleIDInput)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { mount() }

            Button {
                mount()
            } label: {
                Label("Mount container", systemImage: "link")
            }
            .disabled(bundleIDInput.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Mount theo Bundle ID")
        } footer: {
            Text("Đường dẫn đích: Documents/_sandbox/<bundle-id>/. "
                 + "Cần App Group group.com.wqterm.app và iOS còn khai thác được worse_query.")
                .font(.caption2)
        }
    }

    private var mountedSection: some View {
        Section {
            if mounted.isEmpty {
                Text("Chưa có container nào được mount.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mounted, id: \.self) { bundleID in
                    NavigationLink {
                        MountedContainerView(bundleID: bundleID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bundleID)
                                .font(.caption.monospaced())
                            Text("Documents/_sandbox/\(bundleID)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Button {
                refresh()
            } label: {
                Label("Làm mới danh sách", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Đã mount (\(mounted.count))")
        }
    }

    // MARK: - Actions

    private func refresh() {
        mounted = mounter.listMountedContainers().sorted()
    }

    private func mount() {
        let bundleID = bundleIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        // Cảnh báo đỏ với app nhạy cảm (PRD Module 6).
        if SensitiveAppGuard.shared.isSensitive(bundleID) {
            pendingSensitive = bundleID
            return
        }
        performMount(bundleID)
    }

    private func performMount(_ bundleID: String) {
        pendingSensitive = nil
        if let url = mounter.mountContainer(bundleID: bundleID) {
            message = "Đã mount: \(url.path)"
            bundleIDInput = ""
            refresh()
        } else {
            message = "Mount thất bại: \(bundleID). Kiểm tra quyền App Group và phiên bản iOS."
        }
    }
}

/// Duyệt nội dung một container đã mount.
struct MountedContainerView: View {
    let bundleID: String

    @State private var items: [FileItem] = []
    @State private var isMounted = false

    private var root: URL? {
        SandboxMounter.shared.sandboxRoot?.appendingPathComponent(bundleID, isDirectory: true)
    }

    var body: some View {
        Group {
            if !isMounted {
                ContentUnavailableView("Chưa mount", systemImage: "link.badge.plus",
                                       description: Text("Container này chưa được mount trên thiết bị."))
            } else if items.isEmpty {
                ContentUnavailableView("Container trống", systemImage: "folder",
                                       description: Text("Không đọc được nội dung hoặc container rỗng."))
            } else {
                List(items) { item in
                    FileRow(item: item)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(bundleID)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        guard let root, FileManager.default.fileExists(atPath: root.path) else {
            isMounted = false
            return
        }
        isMounted = true
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                 includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url -> FileItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(url: url,
                            name: url.lastPathComponent,
                            isDirectory: values?.isDirectory ?? false,
                            size: UInt64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
