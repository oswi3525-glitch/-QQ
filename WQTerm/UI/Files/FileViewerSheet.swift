import SwiftUI

/// Màn hình xem file (Module 3 & 7) có nút "Ask AI".
///
/// Định tuyến qua `PreviewRouter`:
/// - `.plist` → `PlistPreviewView` (cây)
/// - `.sqlite` → `SQLitePreviewView`
/// - `.zip` → `ZipPreviewView`
/// - `.image` / video / PDF → QuickLook (nút riêng)
/// - `.text` → `TextPreviewView`
/// - `.hex` → `HexPreviewView`
///
/// "Ask AI" gửi tối đa 32KB nội dung file (hoặc metadata với file nhị phân) cho
/// `AIService` rồi mở sheet chat với câu trả lời — không rời màn hình xem file.
struct FileViewerSheet: View {
    let node: FileNode

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AIService.shared

    @State private var kind: PreviewKind = .hex
    @State private var showAskAI = false
    @State private var askPrompt = ""
    @State private var askAnswer: String?
    @State private var isAsking = false
    @State private var askError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(node.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Xong") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            prepareAskAI()
                        } label: {
                            Label("Ask AI", systemImage: "sparkles")
                        }
                        .disabled(isAsking)

                        ShareLink(item: node.url) {
                            Label("Chia sẻ", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .task(id: node.url) {
                    kind = PreviewRouter.kind(for: node.url)
                }
                .sheet(isPresented: $showAskAI) {
                    askAISheet
                }
        }
    }

    // MARK: - Renderer

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .plist:
            PlistPreviewView(url: node.url, browser: FileBrowser.shared)
        case .sqlite:
            SQLitePreviewView(url: node.url)
        case .zip:
            ZipPreviewView(url: node.url)
        case .image:
            ImagePreviewView(url: node.url)
        case .text:
            TextPreviewView(url: node.url, browser: FileBrowser.shared)
        case .hex:
            HexPreviewView(url: node.url)
        }
    }

    // MARK: - Ask AI

    private var askAISheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text(node.name)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(BuiltinShell.sizeLabel(node.size))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    TextField("Câu hỏi (mặc định: tóm tắt file này)", text: $askPrompt,
                              axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        submitAsk()
                    } label: {
                        if isAsking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Đang hỏi \(AIService.defaultModel)…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Gửi cho AI", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAsking || !ai.hasAPIKey)

                    if !ai.hasAPIKey {
                        Label("Chưa có API key — nhập trong tab AI.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let askError {
                        Text(askError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let askAnswer {
                        Divider()
                        MarkdownTextView(markdown: askAnswer)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { showAskAI = false }
                }
            }
        }
    }

    /// Gửi nội dung file (tối đa 32KB) kèm câu hỏi tới LiteRouter.
    private func submitAsk() {
        let fileURL = node.url
        let prompt = askPrompt
        isAsking = true
        askError = nil
        askAnswer = nil

        Task {
            do {
                guard let key = ai.apiKey else { throw AIServiceError.missingAPIKey }
                let context = FileContextExtractor.extract(url: fileURL, limit: 32 * 1024)
                let question = prompt.isEmpty ? "Tóm tắt và phân tích file này." : prompt
                let full = "File: \(node.name)\n\n\(context)\n\n---\n\n\(question)"
                let answer = try await ai.requestCompletion(prompt: full, apiKey: key)
                await MainActor.run {
                    askAnswer = answer
                    isAsking = false
                }
            } catch {
                await MainActor.run {
                    askError = error.localizedDescription
                    isAsking = false
                }
            }
        }
    }

    private func prepareAskAI() {
        askAnswer = nil
        askError = nil
        showAskAI = true
    }
}

