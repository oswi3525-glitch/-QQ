import SwiftUI
import UIKit

/// Màn hình MobileGestalt (tính năng mới).
///
/// Toàn bộ thao tác ghi đi qua `GestaltManager.write(key:value:)` nên luôn có
/// snapshot write-ahead + atomic rename, và bị chặn cứng từ iOS 27.3 Beta 2.
struct GestaltView: View {
    @StateObject private var compatibility = IOSCompatibility.shared
    @StateObject private var safeMode = SafeMode.shared

    @State private var cachePath: String?
    @State private var accessReport: GestaltManager.AccessReport?
    @State private var presetStates: [GestaltManager.Preset: Bool] = [:]
    @State private var parameters: [GestaltParameter] = []
    @State private var filter = ""
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    @State private var editingKey = ""
    @State private var editingValue = ""
    @State private var showingWrite = false
    @State private var pendingRestore = false
    @State private var pendingPreset: (preset: GestaltManager.Preset, enabled: Bool)?

    private var isWriteAllowed: Bool {
        compatibility.canWriteGestalt && !safeMode.isEnabled
            && cachePath != nil && accessReport?.writable == true
    }

    private var filtered: [GestaltParameter] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return parameters }
        return parameters.filter {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }
    }

    var body: some View {
        Form {
            statusSection
            if cachePath != nil {
                presetsSection
                parametersSection
                actionsSection
            }
        }
        .navigationTitle("MobileGestalt")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Lọc theo key hoặc giá trị")
        .task { reload() }
        .refreshable { reload() }
        .sheet(isPresented: $showingWrite) { writeSheet }
        .alert("Không thể đọc Gestalt", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Thông báo", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
        .twoStepConfirm(
            title: "Khôi phục Gestalt?",
            message: "File sẽ được ghi đè bằng bản snapshot gần nhất.",
            isPresented: $pendingRestore
        ) {
            restore()
        }
        .confirmationDialog("Áp dụng preset?",
                            isPresented: Binding(
                                get: { pendingPreset != nil },
                                set: { if !$0 { pendingPreset = nil } }
                            ),
                            titleVisibility: .visible,
                            presenting: pendingPreset) { pending in
            Button(pending.enabled ? "Bật \(pending.preset.title)" : "Tắt \(pending.preset.title)",
                   role: .destructive) {
                apply(preset: pending.preset, enabled: pending.enabled)
            }
            Button("Huỷ", role: .cancel) { pendingPreset = nil }
        } message: { pending in
            Text("\(pending.preset.detail) Snapshot sẽ được tạo trước khi ghi.")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            LabeledContent("iOS", value: compatibility.version.description)
            LabeledContent("Build", value: compatibility.buildVersion.isEmpty ? "—" : compatibility.buildVersion)
            LabeledContent("Trạng thái", value: compatibility.gestalt.displayName)

            if let reason = compatibility.gestaltBlockReason {
                Label(reason, systemImage: "nosign")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if safeMode.isEnabled {
                Label("SafeMode đang bật — mọi lệnh ghi bị chặn.", systemImage: "lock.doc")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabeledContent("File cache") {
                Text(cachePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Không tìm thấy")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let report = accessReport {
                HStack(spacing: 8) {
                    Image(systemName: report.writable ? "checkmark.circle.fill"
                          : report.readOK ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    Text("Quyền truy cập: \(report.summary)")
                }
                .font(.caption)
                .foregroundStyle(report.writable ? .green : report.readOK ? .orange : .red)
            }

            if let path = cachePath {
                Button {
                    UIPasteboard.general.string = path
                } label: {
                    Label("Sao chép đường dẫn cache", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Trạng thái")
        } footer: {
            Text("Đọc được file KHÔNG có nghĩa là ghi được. Ứng dụng probe quyền ghi thực tế "
                 + "trước mỗi lần ghi; nếu kernel từ chối, dữ liệu gốc được giữ nguyên.")
                .font(.caption2)
        }
    }

    private var presetsSection: some View {
        Section {
            ForEach(GestaltManager.Preset.allCases) { preset in
                Toggle(isOn: Binding(
                    get: { presetStates[preset] ?? false },
                    set: { pendingPreset = (preset, $0) }
                )) {
                    HStack(spacing: 10) {
                        Image(systemName: preset.systemImage)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .font(.subheadline.weight(.medium))
                            Text(preset.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!isWriteAllowed)
            }
        } header: {
            Text("Preset nhanh")
        } footer: {
            Text(isWriteAllowed
                 ? "Mỗi toggle tạo snapshot write-ahead trước khi ghi. Nếu backup lỗi, lệnh ghi bị huỷ."
                 : "Chỉ đọc — không đủ điều kiện ghi trên thiết bị này.")
                .font(.caption2)
        }
    }

    private var parametersSection: some View {
        Section {
            if filtered.isEmpty {
                Text(parameters.isEmpty ? "Cache rỗng hoặc không đọc được." : "Không có key nào khớp bộ lọc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { parameter in
                    Button {
                        editingKey = parameter.key
                        editingValue = parameter.value
                        showingWrite = true
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(parameter.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                            Text(parameter.value)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isWriteAllowed)
                }
            }
        } header: {
            Text("Tham số (\(parameters.count))")
        } footer: {
            Text(isWriteAllowed
                 ? "Chạm một tham số để sửa. Mỗi lần ghi đều tạo snapshot write-ahead trước."
                 : "Chỉ đọc — không đủ điều kiện để ghi trên thiết bị này.")
                .font(.caption2)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                editingKey = ""
                editingValue = ""
                showingWrite = true
            } label: {
                Label("Thêm / sửa tham số", systemImage: "square.and.pencil")
            }
            .disabled(!isWriteAllowed)

            Button {
                pendingRestore = true
            } label: {
                Label("Khôi phục snapshot gần nhất", systemImage: "arrow.uturn.backward")
            }
            .disabled(GestaltManager.shared.lastSnapshot == nil)

            Button {
                reload()
            } label: {
                Label("Đọc lại cache", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Thao tác")
        }
    }

    // MARK: - Write sheet

    private var writeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("UserAssignedDeviceName", text: $editingKey)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Giá trị mới", text: $editingValue)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Tham số")
                } footer: {
                    Text("Ví dụ: UserAssignedDeviceName để đổi tên thiết bị, "
                         + "ProductType để fake model (iPhone17,1…).")
                        .font(.caption2)
                }

                Section {
                    Menu("Chọn nhanh key") {
                        ForEach(GestaltManager.commonKeys, id: \.self) { key in
                            Button(key) {
                                editingKey = key
                                editingValue = ""
                            }
                        }
                    }
                }

                Section {
                    Button {
                        commitWrite()
                    } label: {
                        Label("Snapshot + Ghi", systemImage: "checkmark.shield")
                    }
                    .disabled(editingKey.trimmingCharacters(in: .whitespaces).isEmpty || !isWriteAllowed)
                } footer: {
                    Text("Hệ thống sẽ tạo snapshot trước; nếu backup thất bại, lệnh ghi bị huỷ "
                         + "và file gốc không bị chạm tới.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Ghi Gestalt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { showingWrite = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Actions

    private func reload() {
        let manager = GestaltManager.shared
        guard let url = manager.locateCacheFile() else {
            cachePath = nil
            parameters = []
            return
        }
        cachePath = url.path
        accessReport = manager.accessReport()
        presetStates = manager.presetStates()
        do {
            parameters = try manager.readableParameters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Chỉ báo thành công sau khi `verified == true` (đã đọc lại so sánh).
    private func apply(preset: GestaltManager.Preset, enabled: Bool) {
        do {
            let outcome = try GestaltManager.shared.apply(preset: preset, enabled: enabled)
            guard outcome.verified else {
                errorMessage = "Ghi xong nhưng không xác minh được — không báo thành công."
                return
            }
            statusMessage = "Đã \(enabled ? "bật" : "tắt") \(preset.title) và xác minh bằng đọc lại.\n"
                + "Khoá: \(outcome.changedKeys.prefix(3).joined(separator: ", "))"
            reload()
        } catch let error as GestaltError {
            errorMessage = "[\(error.category)] \(error.localizedDescription)"
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitWrite() {
        do {
            let outcome = try GestaltManager.shared.write(key: editingKey, value: editingValue)
            guard outcome.verified else {
                errorMessage = "Ghi xong nhưng không xác minh được — không báo thành công."
                return
            }
            showingWrite = false
            statusMessage = "Đã ghi \(editingKey) và xác minh bằng đọc lại."
            reload()
        } catch let error as GestaltError {
            errorMessage = "[\(error.category)] \(error.localizedDescription)"
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() {
        do {
            try GestaltManager.shared.restoreLastSnapshot()
            statusMessage = "Đã khôi phục từ snapshot gần nhất."
            reload()
        } catch let error as GestaltError {
            errorMessage = "[\(error.category)] \(error.localizedDescription)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
