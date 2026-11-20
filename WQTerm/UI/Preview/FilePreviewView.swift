import SwiftUI

/// Màn hình preview đa định dạng (M7).
/// Định tuyến qua `PreviewRouter`, mỗi định dạng có renderer riêng.
struct FilePreviewView: View {
    let file: FileItem
    @ObservedObject var browser: FileBrowser

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var kind: PreviewKind = .hex

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Xong") { dismiss() }
                    }
                }
                .task(id: file.url) {
                    kind = PreviewRouter.kind(for: file.url)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .plist:
            PlistPreviewView(url: file.url, browser: browser)
        case .sqlite:
            SQLitePreviewView(url: file.url)
        case .zip:
            ZipPreviewView(url: file.url)
        case .image:
            ImagePreviewView(url: file.url)
        case .text:
            TextPreviewView(url: file.url, browser: browser)
        case .hex:
            HexPreviewView(url: file.url)
        }
    }
}
