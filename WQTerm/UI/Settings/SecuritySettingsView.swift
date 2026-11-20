import SwiftUI

/// Chi tiết an toàn dữ liệu (M3 + M6).
struct SecuritySettingsView: View {
    @StateObject private var safeMode = SafeMode.shared
    @StateObject private var faceID = FaceIDLock.shared

    @State private var snapshots: [SnapshotManager.Snapshot] = []
    @State private var pendingWipe = false
    @State private var message: String?

    private var totalBytes: UInt64 { snapshots.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { faceID.isEnabled },
                    set: { SecurityManager.shared.setFaceIDEnabled($0) }
                )) {
                    Label("Khoá bằng Face ID", systemImage: "faceid")
                }

                if faceID.isEnabled {
                    Picker("Tự khoá sau", selection: Binding(
                        get: { faceID.timeoutSeconds },
                        set: { faceID.timeoutSeconds = $0 }
                    )) {
                        Text("Không").tag(0)
                        Text("1 phút").tag(60)
                        Text("5 phút").tag(300)
                        Text("15 phút").tag(900)
                    }
                }
            } header: {
                Text("Khoá ứng dụng")
            } footer: {
                Text("Face ID dùng LocalAuthentication với deviceOwnerAuthentication, "
                     + "không lưu sinh trắc học trong app.")
                    .font(.caption2)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { safeMode.isEnabled },
                    set: { safeMode.setEnabled($0) }
                )) {
                    Label("Chỉ đọc (SafeMode)", systemImage: "lock.doc")
                }

                LabeledContent("Snapshot đang giữ", value: "\(snapshots.count)")
                LabeledContent("Dung lượng", value: BuiltinShell.sizeLabel(totalBytes))
                ProgressView(value: min(1.0, Double(totalBytes) / Double(max(1, SnapshotEngine.maxTotalBytes))))
                    .tint(totalBytes > SnapshotEngine.maxTotalBytes / 2 ? .orange : .accentColor)
            } header: {
                Text("Bảo vệ dữ liệu")
            } footer: {
                Text("SafeMode chặn mọi lệnh ghi. Snapshot write-ahead được tạo trước mỗi lần ghi "
                     + "và giới hạn tổng \(BuiltinShell.sizeLabel(SnapshotEngine.maxTotalBytes)).")
                    .font(.caption2)
            }

            Section {
                NavigationLink {
                    AuditLogView()
                } label: {
                    Label("Nhật ký thao tác", systemImage: "list.bullet.rectangle")
                }

                Button(role: .destructive) {
                    pendingWipe = true
                } label: {
                    Label("Xoá toàn bộ dữ liệu (panic wipe)", systemImage: "trash.slash")
                }
            } header: {
                Text("Dữ liệu & nhật ký")
            }
        }
        .navigationTitle("Bảo mật")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .twoStepConfirm(
            title: "Xoá toàn bộ dữ liệu?",
            message: "Toàn bộ file trong Documents và mọi snapshot sẽ bị xoá vĩnh viễn.",
            isPresented: $pendingWipe
        ) {
            performWipe()
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

    private func reload() {
        snapshots = SnapshotManager.shared.listSnapshots()
    }

    /// Panic wipe: xoá file người dùng + snapshot, ghi audit log.
    private func performWipe() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            let contents = try fm.contentsOfDirectory(at: documents,
                                                      includingPropertiesForKeys: nil,
                                                      options: [])
            for url in contents {
                try? fm.removeItem(at: url)
            }
            AuditLogger.shared.log(event: .panicWipe)
            reload()
            message = "Đã xoá toàn bộ dữ liệu."
        } catch {
            message = error.localizedDescription
        }
    }
}
