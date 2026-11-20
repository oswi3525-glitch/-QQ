import SwiftUI

/// Cấu hình & kiểm tra renderer preview (M7).
///
/// Liệt kê các renderer cùng định dạng phụ trách và cho phép chạy thử trên file mẫu
/// để xác nhận QuickLook / Plist / SQLite / Zip hoạt động trên thiết bị thật.
struct PreviewSettingsView: View {
    @State private var report: String?

    private let renderers: [(String, String, String)] = [
        ("Plist", "list.bullet.rectangle", "plist, entitlements, mobileprovision"),
        ("SQLite", "cylinder.split.1x2", "db, sqlite, sqlite3, db3"),
        ("ZIP", "doc.zipper", "zip, ipa, xcarchive, jar, epub"),
        ("Ảnh", "photo", "png, jpg, jpeg, heic, gif, bmp, tiff, webp"),
        ("Văn bản", "doc.text", "txt, md, json, xml, yaml, swift, py, sh, csv, log"),
        ("Hex", "number", "mọi định dạng không nhận dạng được (magic bytes)")
    ]

    var body: some View {
        Form {
            Section {
                ForEach(renderers, id: \.0) { renderer in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(renderer.0, systemImage: renderer.1)
                        Text(renderer.2)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Renderer")
            } footer: {
                Text("Định tuyến qua PreviewRouter: ưu tiên phần mở rộng, sau đó nhận dạng "
                     + "magic bytes (SQLite format 3, PK\\x03\\x04, PNG, JPEG, bplist…).")
                    .font(.caption2)
            }

            Section {
                LabeledContent("Giới hạn inline", value: BuiltinShell.sizeLabel(PreviewRouter.maxInlineBytes))
                LabeledContent("QuickLook tối đa", value: "50M")
                LabeledContent("Dòng SQLite tối đa", value: "\(SQLiteViewer.shared.rowLimit)")

                Button {
                    runSelfCheck()
                } label: {
                    Label("Chạy self-check renderer", systemImage: "checkmark.seal")
                }

                if let report {
                    Text(report)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Thông số")
            } footer: {
                Text("Self-check tạo file mẫu trong tmp/ và xác nhận router trả về đúng renderer.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Preview & Renderer")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Self check

    /// Tạo file mẫu và kiểm tra `PreviewRouter` phân loại đúng.
    private func runSelfCheck() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        let samples: [(String, Data, PreviewKind)] = [
            ("sample.plist",
             (try? PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .xml, options: 0)) ?? Data(),
             .plist),
            ("sample.db", Data("SQLite format 3\u{0}".utf8), .sqlite),
            ("sample.zip", Data([0x50, 0x4B, 0x03, 0x04]), .zip),
            ("sample.txt", Data("hello".utf8), .text)
        ]

        var lines: [String] = []
        for (name, data, expected) in samples {
            let url = temp.appendingPathComponent(name)
            try? data.write(to: url)
            let actual = PreviewRouter.kind(for: url)
            let mark = actual == expected ? "OK" : "SAI"
            lines.append("\(mark)  \(name) → \(actual.displayName)")
            try? fm.removeItem(at: url)
        }
        report = lines.joined(separator: "\n")
    }
}
