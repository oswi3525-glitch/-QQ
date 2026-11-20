import SwiftUI

/// Màn hình Toolchain & PATH (Module 5): trạng thái framework a-Shell, danh sách
/// lệnh khả dụng và nội dung `setup_env.sh` đang dùng.
struct ToolchainView: View {
    @StateObject private var setup = EnvironmentSetup.shared
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Backend", value: CommandRunner.backendLabel)
                LabeledContent("Framework đã nạp",
                               value: CommandRunner.loadedFrameworks.isEmpty
                                   ? "—"
                                   : CommandRunner.loadedFrameworks.joined(separator: ", "))
                LabeledContent("Có trong bundle",
                               value: CommandRunner.locateAShellBinary()?.isEmpty == false ? "có" : "không")
            } header: {
                Text("Shell native")
            } footer: {
                Text("CommandRunner dlopen ios_system.framework + shell/text/files/tar/awk. "
                     + "Nếu nạp thất bại, Terminal tự động dùng BuiltinShell (Swift thuần).")
                    .font(.caption2)
            }

            Section {
                ForEach(setup.availableTools) { tool in
                    HStack(spacing: 8) {
                        Image(systemName: tool.systemImage)
                            .foregroundStyle(tool.kind.isAvailable ? Color.green : Color.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name)
                                .font(.callout.monospaced())
                            Text(tool.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(tool.kind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Lệnh khả dụng (\(setup.availableTools.filter(\.kind.isAvailable).count))")
            }

            Section {
                Button {
                    regenerate()
                } label: {
                    Label("Tái tạo setup_env.sh", systemImage: "arrow.clockwise")
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Môi trường")
            } footer: {
                Text("Biến môi trường được nạp tự động trước lệnh đầu tiên của mỗi phiên.")
                    .font(.caption2)
            }

            if !setup.scriptPreview.isEmpty {
                Section("setup_env.sh") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(setup.scriptPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                LabeledContent("PATH", value: setup.pathValue)
                    .font(.caption2.monospaced())
            }
        }
        .navigationTitle("Toolchain")
        .navigationBarTitleDisplayMode(.inline)
        .task { setup.prepareInBackground() }
    }

    private func regenerate() {
        do {
            _ = try setup.prepare()
            let installed = setup.installAIScript() ? "ai.py đã cài" : "ai.py chưa có trong bundle"
            message = "Đã tạo lại setup_env.sh. \(installed)."
        } catch {
            message = "Lỗi: \(error.localizedDescription)"
        }
    }
}
