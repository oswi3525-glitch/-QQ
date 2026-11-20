import SwiftUI

/// Trình duyệt nội dung ZIP không cần giải nén (M7.2).
struct ZipPreviewView: View {
    let url: URL

    @State private var entries: [ZipBrowser.ZipEntry] = []
    @State private var errorMessage: String?

    private var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.size } }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("Không đọc được ZIP",
                                       systemImage: "doc.zipper",
                                       description: Text(errorMessage))
            } else if entries.isEmpty {
                ContentUnavailableView("Kho lưu trữ rỗng",
                                       systemImage: "doc.zipper",
                                       description: Text("Không tìm thấy entry nào trong file ZIP."))
            } else {
                List {
                    Section {
                        ForEach(entries, id: \.name) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                                Text(entry.name)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if !entry.isDirectory {
                                    Text(BuiltinShell.sizeLabel(entry.size))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("\(entries.count) mục • \(BuiltinShell.sizeLabel(totalBytes))")
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: url) { load() }
    }

    private func load() {
        entries = ZipBrowser.shared.listEntries(url: url)
        errorMessage = entries.isEmpty ? "File không phải ZIP hợp lệ hoặc bị hỏng." : nil
    }
}
