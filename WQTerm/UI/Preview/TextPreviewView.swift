import SwiftUI

/// Renderer cho file văn bản, có thể chỉnh sửa và lưu an toàn.
struct TextPreviewView: View {
    let url: URL
    @ObservedObject var browser: FileBrowser

    @State private var text = ""
    @State private var original = ""
    @State private var isEditing = false
    @State private var message: String?

    private var hasChanges: Bool { text != original }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if hasChanges {
                    Button("Lưu") { save() }
                        .bold()
                }
                Button(isEditing ? "Xem" : "Sửa") {
                    isEditing.toggle()
                }
            }
        }
        .alert("Thông báo", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task(id: url) { load() }
    }

    private func load() {
        if let content = browser.readText(at: url) {
            text = content
            original = content
        } else {
            message = "File quá lớn hoặc không phải UTF-8. Xem ở chế độ Hex."
        }
    }

    private func save() {
        do {
            try browser.saveText(text, to: url)
            original = text
            isEditing = false
            message = "Đã lưu. Bản cũ được giữ trong Backup."
        } catch {
            message = error.localizedDescription
        }
    }
}
