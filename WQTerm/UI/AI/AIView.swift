import SwiftUI

/// Tab AI (Module 4): cấu hình API key + Model ID ngay trên tab, kiểm tra kết nối
/// và chat với lịch sử hội thoại.
///
/// API key chỉ lưu trong Keychain (qua `AIProviderStore`), không ghi UserDefaults.
/// Nút "Lưu / Kết nối" gửi một request tối thiểu để xác nhận key + model hợp lệ.
struct AIView: View {
    @StateObject private var ai = AIService.shared
    @StateObject private var store = AIProviderStore.shared

    @State private var showConfig = false
    @State private var showSettings = false
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var showKey = false
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showConfig {
                    configPanel
                    Divider()
                }
                ChatView()
            }
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showConfig.toggle()
                        }
                    } label: {
                        Label(showConfig ? "Ẩn cấu hình" : "Cấu hình AI",
                              systemImage: showConfig ? "chevron.up" : "key.horizontal")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Nâng cao", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    AICLISettingsView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Xong") { showSettings = false }
                            }
                        }
                }
            }
            .task {
                store.refresh()
                if modelDraft.isEmpty { modelDraft = ai.model }
                if !ai.hasAPIKey { showConfig = true }
            }
        }
    }

    // MARK: - Config panel

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Cấu hình AI", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                connectionBadge
            }

            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("Dán API key", text: $keyDraft)
                    } else {
                        SecureField(ai.hasAPIKey ? "Đã lưu key — nhập key mới để thay" : "Dán API key",
                                    text: $keyDraft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(showKey ? "Ẩn API key" : "Hiện API key")
            }

            TextField("Model ID (ví dụ gemini-3-flash-preview)", text: $modelDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    saveAndConnect()
                } label: {
                    if isConnecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Đang kiểm tra…")
                        }
                    } else {
                        Label("Lưu / Kết nối", systemImage: "bolt.horizontal.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)

                if ai.hasAPIKey {
                    Button(role: .destructive) {
                        deleteKey()
                    } label: {
                        Label("Xoá key", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isConnecting)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Endpoint: \(ai.endpoint)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ai.hasAPIKey ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(ai.hasAPIKey ? "Key đã lưu" : "Chưa có key")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    // MARK: - Actions

    private func saveAndConnect() {
        errorMessage = nil
        statusMessage = nil
        isConnecting = true

        Task {
            do {
                let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    try ai.saveAPIKey(trimmed)
                }
                ai.saveModel(modelDraft)
                guard ai.hasAPIKey else { throw AIServiceError.missingAPIKey }

                try await ai.validateConnection()

                await MainActor.run {
                    statusMessage = "Kết nối thành công với \(ai.model)."
                    keyDraft = ""
                    isConnecting = false
                    store.refresh()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }

    private func deleteKey() {
        do {
            try ai.deleteAPIKey()
            statusMessage = "Đã xoá API key khỏi Keychain."
            errorMessage = nil
            store.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
