import SwiftUI

/// Một dòng cấu hình API key cho từng provider.
struct ProviderKeyRow: View {
    let provider: AIProvider
    let maskedKey: String?
    let cliAvailable: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isConfigured: Bool { maskedKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(provider.displayName, systemImage: provider.systemImage)
                Spacer()
                if isConfigured {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Đã cấu hình")
                }
            }

            Text(maskedKey ?? "Chưa có API key")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: cliAvailable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(cliAvailable ? .green : .orange)
                Text(cliAvailable ? "CLI đã có trong bundle" : "CLI Node không còn nhúng (dùng chat AI native)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(isConfigured ? "Đổi key" : "Lưu API Key", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if isConfigured {
                    Button("Xoá", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

/// Sheet nhập API key.
struct APIKeyInputSheet: View {
    let provider: AIProvider
    @Binding var draft: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Dán API key", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text(provider.displayName)
                } footer: {
                    Text("Biến môi trường: \(provider.environmentKey)")
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu", action: onSave)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
