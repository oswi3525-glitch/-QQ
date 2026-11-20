import SwiftUI
import UIKit
import QuickLook

/// Tab Files (Module 3): cây `Documents/` + `Documents/_sandbox/`, nhận diện định
/// dạng, QuickLook cho ảnh/video/PDF, renderer riêng cho plist/SQLite/hex.
struct FilesView: View {
    @StateObject private var browser = FilesBrowser.shared

    @State private var previewNode: FileNode?
    @State private var quickLookURL: URL?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: FileNode?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) { breadcrumb }
                .sheet(item: $previewNode) { node in
                    FileViewerSheet(node: node)
                }
                .sheet(item: Binding(
                    get: { quickLookURL.map(ShareItem.init) },
                    set: { if $0 == nil { quickLookURL = nil } }
                )) { item in
                    QuickLookSheet(url: item.url)
                }
                .alert("Thư mục mới", isPresented: $showingNewFolder) {
                    TextField("Tên thư mục", text: $newFolderName)
                    Button("Huỷ", role: .cancel) { newFolderName = "" }
                    Button("Tạo") { createFolder() }
                }
                .alert("Xoá mục này?", isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ), presenting: pendingDelete) { node in
                    Button("Xoá", role: .destructive) { delete(node) }
                    Button("Huỷ", role: .cancel) { pendingDelete = nil }
                } message: { node in
                    Text(node.isDirectory
                         ? "Toàn bộ nội dung trong \"\(node.name)\" sẽ bị xoá."
                         : "\"\(node.name)\" được snapshot trước khi xoá để có thể khôi phục.")
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if browser.isLoading, browser.items.isEmpty {
            ProgressView("Đang đọc thư mục…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browser.errorMessage {
            ContentUnavailableView {
                Label("Không mở được thư mục", systemImage: "folder.badge.questionmark")
            } description: {
                Text(error)
            } actions: {
                Button("Về gốc") { browser.goToRoot() }
                    .buttonStyle(.borderedProminent)
            }
        } else if browser.items.isEmpty {
            ContentUnavailableView {
                Label("Thư mục trống", systemImage: "folder")
            } description: {
                Text("Dùng Terminal để tạo file, hoặc nút + để tạo thư mục mới.")
            } actions: {
                Button("Tạo thư mục") { showingNewFolder = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            fileList
        }
    }

    private var fileList: some View {
        List {
            Section {
                Picker("Gốc", selection: Binding(
                    get: { browser.root },
                    set: { browser.selectRoot($0) }
                )) {
                    ForEach(FilesBrowser.Root.allCases) { root in
                        Label(root.title, systemImage: root.systemImage).tag(root)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(browser.items) { node in
                    Button {
                        open(node)
                    } label: {
                        FileNodeRow(node: node)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = node
                        } label: {
                            Label("Xoá", systemImage: "trash")
                        }
                        if !node.isDirectory {
                            Button {
                                quickLookURL = node.url
                            } label: {
                                Label("Quick Look", systemImage: "eye")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text("\(browser.items.count) mục")
            } footer: {
                Text("Chạm để mở. Vuốt để xoá hoặc xem nhanh bằng QuickLook.")
                    .font(.caption2)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { browser.reload() }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    browser.goToRoot()
                } label: {
                    Label(browser.root.title, systemImage: browser.root.systemImage)
                        .font(.caption2)
                }
                .disabled(!browser.canGoUp)

                ForEach(Array(browser.pathComponents.dropFirst().enumerated()), id: \.offset) { _, part in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(part)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                }

                if browser.isInsideContainer {
                    Label("container", systemImage: "lock.open")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
                Button { showingNewFolder = true } label: {
                    Label("Thư mục mới", systemImage: "folder.badge.plus")
                }
                Button { browser.reload() } label: {
                    Label("Tải lại", systemImage: "arrow.clockwise")
                }
                Button { browser.selectRoot(.sandbox) } label: {
                    Label("Mở _sandbox", systemImage: "link")
                }
            } label: {
                Label("Thêm", systemImage: "plus")
            }
        }
    }

    // MARK: - Actions

    /// Mở folder hoặc file; ảnh/video/PDF dùng QuickLook, còn lại dùng renderer.
    private func open(_ node: FileNode) {
        if node.isDirectory {
            browser.enter(node)
            return
        }
        if QuickLookPreview.shared.canPreview(url: node.url) {
            quickLookURL = node.url
        } else {
            previewNode = node
        }
    }

    private func createFolder() {
        let name = newFolderName
        newFolderName = ""
        do {
            try browser.createDirectory(named: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ node: FileNode) {
        pendingDelete = nil
        do {
            try browser.delete(node)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

