import SwiftUI

/// Tab Sandbox (M2): trình duyệt file trong Documents của ứng dụng.
///
/// Mọi truy cập bị giới hạn trong container của chính WQTerm — xem
/// `FileBrowser.contained(_:)`. Không đọc dữ liệu của app khác.
struct LegacyBrowserView: View {
    @StateObject private var browser = FileBrowser.shared
    @State private var previewItem: FileItem?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: FileItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if browser.items.isEmpty {
                    emptyState
                } else {
                    fileList
                }
            }
            .navigationTitle("Sandbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top) { breadcrumb }
            .sheet(item: $previewItem) { item in
                FilePreviewView(file: item, browser: browser)
            }
            .alert("Thư mục mới", isPresented: $showingNewFolder) {
                TextField("Tên thư mục", text: $newFolderName)
                Button("Huỷ", role: .cancel) { newFolderName = "" }
                Button("Tạo") { createFolder() }
            }
            .alert("Xoá mục này?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { item in
                Button("Xoá", role: .destructive) { delete(item) }
                Button("Huỷ", role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text(item.isDirectory
                     ? "Toàn bộ nội dung trong \"\(item.name)\" sẽ bị xoá."
                     : "\"\(item.name)\" sẽ được snapshot trước khi xoá để có thể khôi phục.")
            }
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

    // MARK: - Sections

    private var fileList: some View {
        List {
            ForEach(browser.items) { item in
                Button {
                    if item.isDirectory {
                        browser.enter(item)
                    } else {
                        previewItem = item
                    }
                } label: {
                    FileRow(item: item)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("Xoá", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { browser.reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Thư mục trống", systemImage: "folder")
        } description: {
            Text("Dùng tab Terminal để tạo file, hoặc nút + để tạo thư mục mới.")
        } actions: {
            Button("Tạo thư mục") { showingNewFolder = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                browser.goToRoot()
            } label: {
                Label("Documents", systemImage: "externaldrive")
                    .font(.caption)
            }
            .disabled(!browser.canGoUp)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(browser.relativePath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                browser.goUp()
            } label: {
                Label("Lên", systemImage: "arrow.up")
            }
            .disabled(!browser.canGoUp)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingNewFolder = true
                } label: {
                    Label("Thư mục mới", systemImage: "folder.badge.plus")
                }
                NavigationLink {
                    ContainerBrowserView()
                } label: {
                    Label("Container app khác (M2)", systemImage: "link.badge.plus")
                }
                Button {
                    browser.reload()
                } label: {
                    Label("Tải lại", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("Thêm", systemImage: "plus")
            }
        }
    }

    // MARK: - Actions

    private func createFolder() {
        let name = newFolderName
        newFolderName = ""
        do {
            try browser.createDirectory(named: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: FileItem) {
        pendingDelete = nil
        do {
            try browser.delete(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
