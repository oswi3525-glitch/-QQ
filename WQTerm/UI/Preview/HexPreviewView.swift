import SwiftUI
import UIKit

/// Renderer hex + ASCII (M7.2), có nhận dạng định dạng qua magic bytes.
struct HexPreviewView: View {
    let url: URL

    @State private var dump = ""
    @State private var format = ""
    @State private var message: String?
    @State private var limit = 4096

    private let limits = [1024, 4096, 16384, 65536, 262144]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(format, systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Giới hạn", selection: $limit) {
                    ForEach(limits, id: \.self) { value in
                        Text(BuiltinShell.sizeLabel(UInt64(value))).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if let message {
                ContentUnavailableView("Không đọc được",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(dump)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .task(id: limit) { load() }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "File không tồn tại."
            return
        }
        format = HexViewer.shared.detectFormat(url: url)
        dump = HexViewer.shared.hexDump(url: url, limit: limit)
        message = nil
    }
}

/// Renderer cho hình ảnh, dùng `UIImage` để giải mã.
struct ImagePreviewView: View {
    let url: URL

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
                .overlay(alignment: .bottom) {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                }
            } else if failed {
                ContentUnavailableView("Không hiển thị được ảnh",
                                       systemImage: "photo.badge.exclamationmark",
                                       description: Text("Định dạng có thể không được hỗ trợ."))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = UIImage(contentsOfFile: url.path)
            failed = image == nil
        }
    }
}
