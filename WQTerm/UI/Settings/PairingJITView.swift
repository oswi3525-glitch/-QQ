import SwiftUI
import UIKit

/// Pairing & JIT — hiển thị riêng VPN / Tunnel / Listener / Bonjour / Pairing.
struct PairingJITView: View {
    @StateObject private var pairing = PairingManager.shared
    @StateObject private var jit = JITManager.shared
    @ObservedObject private var tunnel = TunnelMonitor.shared
    @ObservedObject private var logger = PairingLogger.shared

    @State private var message: String?
    @State private var sharePayload: SharePayload?
    @State private var showResetConfirm = false
    @State private var showDebugLog = false
    @State private var showConfig = false
    @State private var configAddress = ""
    @State private var configListenerPort = ""
    @State private var configRelayPort = ""
    @State private var configMessage: String?

    var body: some View {
        Form {
            stateSection
            diagnosticsSection
            vpnSection
            instructionsSection
            pinSection
            pairingFileSection
            jitSection
            supportSection
        }
        .navigationTitle("Pairing & JIT")
        .navigationBarTitleDisplayMode(.inline)
        .padding(.bottom, 12)
        .alert("Thông báo", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Đặt lại trạng thái ghép nối?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Đặt lại", role: .destructive) {
                pairing.resetPairingState()
                message = pairing.statusMessage
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Chỉ xoá trạng thái trong app. File pairing đã lưu trong Documents/ vẫn được giữ.")
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
        .sheet(isPresented: $showDebugLog) {
            PairingDebugLogView()
        }
        .sheet(isPresented: $showConfig) {
            tunnelConfigSheet
        }
        .task { pairing.recheck() }
    }

    // MARK: - Trạng thái theo giai đoạn

    private var stateSection: some View {
        Section {
            statusRow(title: "VPN",
                      ok: pairing.tunnelReady,
                      text: pairing.tunnelReady ? "LocalDevVPN sẵn sàng" : "Chưa có LocalDevVPN",
                      detail: pairing.tunnelSummary)
            statusRow(title: "Tunnel",
                      ok: pairing.tunnelReady,
                      text: pairing.tunnelAddressLabel,
                      detail: "listener \(pairing.listenerPortLabel)")

            statusRow(title: "Listener",
                      ok: pairing.advertisedPort != nil,
                      text: pairing.advertisedPort.map { "port \($0)" } ?? "chưa mở",
                      detail: "listener \(pairing.listenerState.rawValue) · host \(pairing.state.rawValue)")

            statusRow(title: "Bonjour",
                      ok: pairing.isAdvertising,
                      text: pairing.isAdvertising ? "Đang quảng bá" : "Chưa quảng bá",
                      detail: "\(PairingManager.serviceType) · discovery \(pairing.bonjourDiscovered ? "thấy" : "chưa thấy")")

            statusRow(title: "Pairing",
                      ok: pairing.handshakeVerified,
                      text: pairing.handshakeVerified ? "Handshake hợp lệ" : "Chưa xác thực",
                      detail: "handshake \(pairing.handshakeState.rawValue) · PIN đã nhập: \(pairing.pinConfirmed ? "có" : "chưa")")

            if let status = pairing.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = pairing.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error).font(.caption).foregroundStyle(.red)
                        if let code = pairing.lastErrorCode {
                            Text("Mã: \(code)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !PairingManager.supportsDeviceInitiatedPairing {
                Label("Pairing trực tiếp cần iOS 27+.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Trạng thái hệ thống")
        } footer: {
            Text("Trạng thái thành công = xanh, đang xử lý = vàng, lỗi = đỏ. "
                 + "Chưa có handshake thì không báo đã ghép nối.")
                .font(.caption2)
        }
    }

    private func statusRow(title: String, ok: Bool, text: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.caption.bold())
                    Text(text).font(.subheadline)
                }
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Button {
                Task { await pairing.runDiagnostics() }
            } label: {
                HStack {
                    Label("Kiểm tra kết nối (7 bước)", systemImage: "stethoscope")
                    Spacer()
                    if pairing.isRunningDiagnostics {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .liquidGlassButton()
            .disabled(pairing.isRunningDiagnostics)

            ForEach(pairing.diagnostics) { step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: step.status))
                            .foregroundStyle(color(for: step.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(step.title).font(.caption.bold())
                                Text(step.status.rawValue.uppercased())
                                    .font(.caption2.bold().monospaced())
                                    .foregroundStyle(color(for: step.status))
                                if let duration = step.duration {
                                    Spacer()
                                    Text(String(format: "%.2fs", duration))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(step.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let code = step.errorCode {
                                Text("Mã: \(code)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let error = step.errorText {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let recovery = step.recovery {
                                Label(recovery, systemImage: "wrench.and.screwdriver")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            // Địa chỉ tunnel thực tế khác cấu hình: chỉ bind sau khi người dùng xác nhận.
            if !pairing.tunnelCandidates.isEmpty {
                ForEach(pairing.tunnelCandidates, id: \.summary) { candidate in
                    Button {
                        pairing.adoptCandidate(candidate)
                        message = "Đã xác nhận \(candidate.summary)."
                    } label: {
                        Label("Dùng địa chỉ này: \(candidate.summary)",
                              systemImage: "checkmark.seal")
                    }
                }
            }
        } header: {
            Text("Chẩn đoán")
        } footer: {
            Text("PASS / FAIL / SKIPPED cho từng bước: VPN · địa chỉ tunnel · route · "
                 + "TCP listener · Bonjour · discovery · handshake. Mỗi bước có mã lỗi và "
                 + "hướng khắc phục. Ứng viên địa chỉ chỉ được dùng sau khi bạn xác nhận.")
                .font(.caption2)
        }
    }

    private func icon(for status: PairingManager.DiagnosticStatus) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for status: PairingManager.DiagnosticStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .pass: return .green
        case .fail: return .red
        case .warning, .skipped: return .orange
        }
    }

    // MARK: - VPN / cấu hình

    private var vpnSection: some View {
        Section {
            LabeledContent("Địa chỉ mong đợi", value: TunnelConfiguration.shared.preferredAddress)
            LabeledContent("Địa chỉ đang dùng", value: pairing.tunnelAddressLabel)
            if let confirmed = TunnelConfiguration.shared.confirmedAddress {
                LabeledContent("Đã xác nhận", value: confirmed)
                Button(role: .destructive) {
                    TunnelConfiguration.shared.clearConfirmedAddress()
                    pairing.stopHost(reason: "Bo xac nhan dia chi tunnel")
                    message = "Đã bỏ xác nhận địa chỉ tunnel."
                } label: {
                    Label("Bỏ xác nhận địa chỉ", systemImage: "arrow.uturn.backward")
                }
            }
            LabeledContent("Port listener", value: pairing.listenerPortLabel)
            LabeledContent("Interface", value: tunnel.info.matchedInterfaces.isEmpty
                           ? "—" : tunnel.info.matchedInterfaces.joined(separator: ", "))
            LabeledContent("Tunnel thấy được", value: tunnel.topology.tunnelDetail)
            Button {
                configAddress = TunnelConfiguration.shared.preferredAddress
                configListenerPort = String(TunnelConfiguration.shared.listenerPort)
                configRelayPort = String(TunnelConfiguration.shared.relayPort)
                configMessage = nil
                showConfig = true
            } label: {
                Label("Cấu hình tunnel", systemImage: "network")
            }
        } header: {
            Text("LocalDevVPN")
        } footer: {
            Text("Chỉ địa chỉ nằm trên interface tunnel point-to-point mới được tính. "
                 + "127.0.0.1 / lo0 và ipsec*/utun* mang địa chỉ công khai không phải LocalDevVPN. "
                 + "Địa chỉ thực tế khác cấu hình sẽ chỉ được dùng sau khi bạn xác nhận.")
                .font(.caption2)
        }
    }

    // MARK: - Hướng dẫn

    private var instructionsSection: some View {
        Section {
            ForEach(Array(PairingManager.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.subheadline.weight(.medium))
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                openSystemSettings()
            } label: {
                Label("Mở Cài đặt iPhone", systemImage: "gear")
            }
        } header: {
            Text("Hướng dẫn")
        }
    }

    // MARK: - PIN

    private var pinSection: some View {
        Section {
            VStack(spacing: 8) {
                Text(pairing.pairingCode)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = pairing.pairingCode
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        message = "Đã sao chép mã PIN."
                    } label: {
                        Label("Sao chép", systemImage: "doc.on.doc")
                    }
                    Button { pairing.refreshCode() } label: {
                        Label("Mã mới", systemImage: "arrow.clockwise")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            if pairing.isAdvertising {
                Button(role: .destructive) { pairing.stopHost(reason: "Người dùng dừng") } label: {
                    Label("Dừng quảng bá", systemImage: "stop.circle")
                }
                .liquidGlassButton()
            } else {
                Button {
                    if pairing.beginPairing() {
                        message = "Đã bắt đầu. Chờ listener sẵn sàng rồi mới quảng bá Bonjour."
                    } else {
                        message = pairing.lastError ?? PairingManager.vpnWarning
                    }
                } label: {
                    Label("Bắt đầu ghép nối", systemImage: "antenna.radiowaves.left.and.right")
                }
                .liquidGlassButton()
            }

            Button {
                pairing.requestLocalNetworkPermissionOnce()
                message = "Đã yêu cầu quyền Mạng nội bộ (chỉ một lần)."
            } label: {
                Label("Cấp quyền Mạng nội bộ", systemImage: "wifi")
            }

            Button {
                pairing.markPaired()
                message = pairing.statusMessage
            } label: {
                Label("Đã nhập mã PIN", systemImage: "checkmark.circle")
            }
            .disabled(pairing.pinConfirmed)

            Button {
                pairing.forceReset()
                message = pairing.statusMessage
            } label: {
                Label("Đặt lại luồng ghép nối", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Mã PIN 6 chữ số")
        } footer: {
            Text("Nút \"Đã nhập mã PIN\" chỉ ghi nhận thao tác của bạn. App chỉ báo ghép nối "
                 + "sau khi nhận được handshake hợp lệ từ thiết bị.")
                .font(.caption2)
        }
    }

    // MARK: - Pairing file / JIT

    private var pairingFileSection: some View {
        Section {
            if let url = pairing.pairingFileURL {
                LabeledContent("File", value: url.lastPathComponent)
                Button {
                    UIPasteboard.general.string = url.path
                    message = "Đã sao chép đường dẫn file pairing."
                } label: {
                    Label("Sao chép đường dẫn", systemImage: "doc.on.doc")
                }
            } else {
                Text("Chưa có file pairing.").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                exportPairing()
            } label: {
                Label("Xuất file mobiledevicepairing", systemImage: "square.and.arrow.up")
            }
            if pairing.isPaired {
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label("Đặt lại trạng thái ghép nối", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Pairing file")
        } footer: {
            Text("File tạo cục bộ (chưa có handshake) chỉ dùng để kiểm tra — không coi là đã ghép nối.")
                .font(.caption2)
        }
    }

    private var jitSection: some View {
        Section {
            LabeledContent("Trạng thái JIT", value: jit.status.rawValue)
            Button { jit.refreshStatus() } label: {
                Label("Kiểm tra lại JIT", systemImage: "arrow.clockwise")
            }
            Button { openStikDebug() } label: {
                Label("Bật JIT bằng StikDebug", systemImage: "bolt.fill")
            }
            .disabled(jit.enableJITURL() == nil)
        } header: {
            Text("JIT (StikDebug)")
        }
    }

    private var supportSection: some View {
        Section {
            Button {
                showDebugLog = true
            } label: {
                Label("Xem debug log pairing (\(logger.entries.count))", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Hỗ trợ")
        } footer: {
            Text("Log giai đoạn được lưu riêng tại Documents/.terminal/pairing-debug.log.")
                .font(.caption2)
        }
    }

    // MARK: - Tunnel config sheet

    private var tunnelConfigSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(TunnelConfiguration.defaultAddress, text: $configAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("0 (tự động)", text: $configListenerPort)
                        .keyboardType(.numberPad)
                    TextField("8080", text: $configRelayPort)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Thông số tunnel")
                } footer: {
                    Text("Địa chỉ này là giá trị MONG ĐỢI, không phải bằng chứng tunnel tồn tại. "
                         + "Nếu tunnel thực tế có địa chỉ khác, app sẽ đề xuất trong Kiểm tra "
                         + "kết nối và chỉ dùng sau khi bạn xác nhận.")
                        .font(.caption2)
                }
                if let configMessage {
                    Text(configMessage).font(.caption).foregroundStyle(.orange)
                }
                Section {
                    Button {
                        saveConfig()
                    } label: {
                        Label("Lưu cấu hình", systemImage: "checkmark.circle")
                    }
                    .liquidGlassButton()
                    Button("Đặt lại mặc định") {
                        TunnelConfiguration.shared.resetToDefaults()
                        configAddress = TunnelConfiguration.shared.tunnelAddress
                        configListenerPort = String(TunnelConfiguration.shared.listenerPort)
                        configRelayPort = String(TunnelConfiguration.shared.relayPort)
                        configMessage = "Đã đặt lại về giá trị mặc định."
                    }
                }
            }
            .navigationTitle("Cấu hình tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Xong") { showConfig = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveConfig() {
        let listener = UInt16(configListenerPort.trimmingCharacters(in: .whitespaces)) ?? 0
        let relay = UInt16(configRelayPort.trimmingCharacters(in: .whitespaces))
            ?? TunnelConfiguration.defaultRelayPort
        // Đổi địa chỉ mong đợi ⇒ xác nhận cũ bị xoá (xem TunnelConfiguration.update).
        if let error = TunnelConfiguration.shared.update(address: configAddress,
                                                         listenerPort: listener,
                                                         relayPort: relay) {
            configMessage = error
            return
        }
        configMessage = "Đã lưu. \(TunnelConfiguration.shared.summary)"
        pairing.stopHost(reason: "Đổi cấu hình tunnel")
        pairing.requestLocalNetworkPermissionOnce()
    }

    // MARK: - Actions

    private func exportPairing() {
        guard let url = pairing.exportCompositePairingFile() else {
            message = "Không tạo được file pairing."
            return
        }
        sharePayload = SharePayload(url: url)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openStikDebug() {
        guard let url = jit.enableJITURL() else {
            message = "Không mở được StikDebug (chưa cài app?)."
            return
        }
        UIApplication.shared.open(url) { success in
            if !success { message = "Không mở được StikDebug." }
        }
    }
}

/// Bọc một `URL` để dùng với `.sheet(item:)` mà không cần mở rộng `URL`.
struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
