import SwiftUI

/// Màn hình chat với LiteRouter (Module 4).
///
/// Tin nhắn assistant render qua `MarkdownTextView`; tin nhắn đang chờ hiển thị
/// spinner. Prompt được gửi trên Task nên UI không bị chặn.
struct ChatView: View {
    @ObservedObject private var ai = AIService.shared
    @EnvironmentObject private var tabSelection: TabSelection

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @State private var errorMessage: String?
    /// Lệnh Terminal do AI trả về, đang chờ người dùng xác nhận.
    @State private var pendingCommand: AICommand?

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .background(Color(uiColor: .systemBackground))
        .alert("Lỗi", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if ai.messages.isEmpty {
                        emptyState
                    }
                    ForEach(ai.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: ai.messages.count) { _, _ in
                if let last = ai.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .alert(item: $pendingCommand) { command in
            let primary: Alert.Button = command.isDangerous
                ? .destructive(Text("Chạy"), action: { run(command) })
                : .default(Text("Chạy"), action: { run(command) })
            return Alert(
                title: Text("⚠️ AI muốn chạy lệnh này"),
                message: Text(alertMessage(for: command)),
                primaryButton: primary,
                secondaryButton: .cancel(Text("Hủy"))
            )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Trợ lý LiteRouter", systemImage: "sparkles")
                .font(.headline)
            Text("Model: \(ai.model)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Endpoint: \(ai.endpoint)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            if !ai.hasAPIKey {
                Label("Chưa có API key — mở Cấu hình để nhập.", systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Gợi ý: \"giải thích Info.plist của app này\", "
                 + "\"lệnh nào dump IPA?\", \"tóm tắt log trong Documents\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                        .font(.caption2)
                    Text(message.role == .user ? "Bạn" : "AI")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)

                if message.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Đang trả lời…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if message.role == .user {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    MarkdownTextView(markdown: message.content)
                        .font(.body)
                }
            }
            .padding(10)
            .background(
                message.role == .user
                    ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                    : AnyShapeStyle(Color.secondary.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: 12)
            )

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Nhập câu hỏi…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .padding(10)
                .background(Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10))
                .submitLabel(.send)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                if ai.isSending {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
            }
            .disabled(ai.isSending || draft.trimmingCharacters(in: .whitespaces).isEmpty)

            Button(role: .destructive) {
                ai.clearConversation()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18))
            }
            .disabled(ai.messages.isEmpty)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !ai.isSending else { return }
        draft = ""

        Task {
            do {
                let reply = try await ai.send(prompt)
                if let command = AICommandExtractor.firstCommand(in: reply) {
                    await MainActor.run {
                        pendingCommand = command
                    }
                }
            } catch {
                // Tin nhắn lỗi đã được chèn vào hội thoại; alert chỉ báo thêm.
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Nội dung Alert: hiện lệnh + lý do nguy hiểm (nếu có).
    private func alertMessage(for command: AICommand) -> String {
        var parts: [String] = []
        if command.isDangerous {
            parts.append("CẢNH BÁO: lệnh này có thể gây mất dữ liệu.")
            parts.append(command.dangerReasons.map { "• \($0)" }.joined(separator: "\n"))
            parts.append("")
        }
        parts.append(command.summary)
        parts.append("")
        parts.append("Lệnh sẽ được đẩy vào tab Terminal để thực thi.")
        return parts.joined(separator: "\n")
    }

    /// Người dùng đã đồng ý — đẩy lệnh vào Terminal.
    private func run(_ command: AICommand) {
        pendingCommand = nil
        ShellSession.shared.runScriptInBackground(command.command)
        tabSelection.select(.terminal)
    }
}

