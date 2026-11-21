import SwiftUI

/// Tab AI & Runtimes (M4/M9): cấu hình API key, endpoint và trạng thái runtime.
struct AICLISettingsView: View {
    @StateObject private var store = AIProviderStore.shared
    @StateObject private var ai = AIService.shared
    @StateObject private var runtimes = RuntimeManager.shared

    @State private var editingProvider: AIProvider?
    @State private var keyDraft = ""
    @State private var baseURLDraft = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                providersSection
                endpointSection
                runtimesSection
                privacySection
            }
            .navigationTitle("AI & Runtimes")
            .navigationBarTitleDisplayMode(.inline)
            .task { store.refresh() }
            .sheet(item: $editingProvider) { provider in
                APIKeyInputSheet(
                    provider: provider,
                    draft: $keyDraft,
                    onSave: { saveKey(for: provider) },
                    onCancel: {
                        editingProvider = nil
                        keyDraft = ""
                    }
                )
            }
            .alert("Thông báo", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - Sections

    private var providersSection: some View {
        Section {
            ForEach(AIProvider.allCases) { provider in
                ProviderKeyRow(
                    provider: provider,
                    maskedKey: store.maskedKey(provider),
                    cliAvailable: store.cliExists(provider),
                    onEdit: {
                        keyDraft = ""
                        editingProvider = provider
                    },
                    onDelete: { deleteKey(provider) }
                )
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Key được lưu trong Keychain của thiết bị và chỉ gửi tới nhà cung cấp "
                 + "khi bạn chủ động chạy lệnh AI.")
        }
    }

    private var endpointSection: some View {
        Section {
            TextField("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                      text: $baseURLDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { saveBaseURL() }

            Button("Lưu endpoint") { saveBaseURL() }
                .disabled(baseURLDraft == ai.endpoint)
        } header: {
            Text("Endpoint tuỳ chỉnh")
        } footer: {
            Text("Mặc định: Gemini OpenAI-compatible. "
                 + "Đổi sang LiteRouter hoặc gateway tương thích OpenAI nếu cần.")
        }
        .onAppear { baseURLDraft = ai.endpoint }
    }

    private var runtimesSection: some View {
        Section {
            // Node.js đã được lược bỏ khỏi bundle để giảm dung lượng.
            runtimeRow(.python, available: runtimes.availableRuntimes[.python] ?? false)

            if let progress = runtimes.installProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = runtimes.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                runtimes.installBundledRuntimesIfNeeded()
            } label: {
                Label("Cài lại runtime từ bundle", systemImage: "arrow.down.circle")
            }
            .disabled(runtimes.isInstalling)
        } header: {
            Text("Runtime nhúng")
        } footer: {
            Text("Runtime được copy từ app bundle sang Documents/.terminal/RuntimeManager/ "
                 + "và cấp quyền thực thi. Node.js không còn nhúng; chat AI native dùng endpoint HTTP.")
        }
    }

    private func runtimeRow(_ runtime: Runtime, available: Bool) -> some View {
        HStack {
            Text(runtime.displayName)
                .font(.body.monospaced())
            Spacer()
            Label(available ? "Sẵn sàng" : "Chưa cài",
                  systemImage: available ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(available ? .green : .secondary)
        }
    }

    private var privacySection: some View {
        Section {
            Label("Không gửi dữ liệu khi bạn không yêu cầu", systemImage: "lock.shield")
                .font(.caption)
        } footer: {
            Text("WQTerm không có server trung gian. Prompt và kết quả chỉ đi trực tiếp "
                 + "giữa thiết bị và nhà cung cấp AI mà bạn cấu hình.")
        }
    }

    // MARK: - Actions

    /// Lưu API key vào Keychain (PRD Module 4: nút "Lưu API Key").
    private func saveKey(for provider: AIProvider) {
        do {
            try store.saveKey(keyDraft, for: provider)
            editingProvider = nil
            keyDraft = ""
            message = "Đã lưu API key cho \(provider.displayName) vào Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Xoá API key khỏi Keychain, có xác nhận vì thao tác không hoàn tác được.
    private func deleteKey(_ provider: AIProvider) {
        do {
            try store.deleteKey(for: provider)
            message = "Đã xoá API key của \(provider.displayName)."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Lưu endpoint tuỳ chỉnh (mặc định Gemini OpenAI-compatible).
    private func saveBaseURL() {
        ai.saveEndpoint(baseURLDraft)
        baseURLDraft = ai.endpoint
        message = "Đã lưu endpoint: \(ai.endpoint)"
    }
}
