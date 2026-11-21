import SwiftUI

/// Renderer cho file `.3105` (Module 7).
///
/// Hiển thị magic bytes, loại nội dung phát hiện được, danh sách entry ZIP,
/// preview text/ảnh/SQLite và nút giải nén an toàn vào `Documents/Unzipped/`.
struct Asset3105PreviewView: View {
    let url: URL

    @State private var inspection: Asset3105Probe.Inspection?
    @State private var isExtracting = false
    @State private var extractedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let inspection {
                content(inspection)
            } else {
                ProgressView("Đang phân tích .3105…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            inspection = Asset3105Probe.inspect(url: url)
        }
        .alert("Không giải nén được", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Content

    private func content(_ inspection: Asset3105Probe.Inspection) -> some View {
        List {
            Section {
                LabeledContent("Kích thước", value: BuiltinShell.sizeLabel(inspection.fileSize))
                LabeledContent("Magic bytes", value: inspection.magic)
                LabeledContent("Nhận diện", value: inspection.kind.label)
                if inspection.kind == .zip {
                    LabeledContent("Entry", value: "\(inspection.entryCount)")
                    LabeledContent("Dung lượng sau giải nén",
                                   value: BuiltinShell.sizeLabel(inspection.unpackedSize))
                }
                if inspection.zipOffset > 0 {
                    LabeledContent("Header bỏ qua", value: "\(inspection.zipOffset) byte")
                }
            } header: {
                Text("Thông tin")
            }

            if !inspection.notes.isEmpty {
                Section("Ghi chú") {
                    ForEach(inspection.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                    }
                }
            }

            if inspection.kind == .zip {
                zipSection(inspection)
            }

            if let text = inspection.textPreview, !text.isEmpty {
                Section {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                } header: {
                    Text("Nội dung xem trước")
                }
            }

            switch inspection.kind {
            case .image:
                Section("Ảnh") {
                    ImagePreviewView(url: inspection.workingURL)
                        .frame(maxHeight: 320)
                }
            case .sqlite:
                Section {
                    NavigationLink {
                        SQLitePreviewView(url: inspection.workingURL)
                    } label: {
                        Label("Mở SQLite viewer", systemImage: "cylinder.split.1x2")
                    }
                }
            case .unknown, .pdf:
                Section {
                    NavigationLink {
                        HexPreviewView(url: inspection.workingURL)
                    } label: {
                        Label("Xem hexdump", systemImage: "number")
                    }
                }
            default:
                EmptyView()
            }

            if let extractedURL {
                Section {
                    Text(extractedURL.path)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    ShareLink(item: extractedURL) {
                        Label("Chia sẻ thư mục đã giải nén",
                              systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Đã giải nén")
                } footer: {
                    Text("Thư mục nằm trong Documents/Unzipped và mở được từ tab Files.")
                        .font(.caption2)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func zipSection(_ inspection: Asset3105Probe.Inspection) -> some View {
        Section {
            Button {
                extract(inspection)
            } label: {
                if isExtracting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Đang giải nén…")
                    }
                } else {
                    Label("Giải nén vào Documents", systemImage: "archivebox")
                }
            }
            .disabled(isExtracting || !inspection.canExtract)

            ShareLink(item: url) {
                Label("Xuất bản gốc .3105", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Giải nén")
        } footer: {
            if !inspection.canExtract {
                Text("File không có entry ZIP đọc được; chỉ xem/xuất bản gốc.")
                    .font(.caption2)
            }
        }

        if !inspection.entries.isEmpty {
            Section {
                ForEach(Array(inspection.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            .font(.caption)
                        Text(entry.name)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !entry.isDirectory {
                            Text(BuiltinShell.sizeLabel(entry.uncompressedSize))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Nội dung ZIP (\(inspection.entryCount) mục)")
            }
        }
    }

    // MARK: - Actions

    private func extract(_ inspection: Asset3105Probe.Inspection) {
        guard !isExtracting else { return }
        isExtracting = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            do {
                let destination = try Asset3105Probe.extract(inspection)
                await MainActor.run {
                    extractedURL = destination
                    isExtracting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExtracting = false
                }
            }
        }
    }
}
