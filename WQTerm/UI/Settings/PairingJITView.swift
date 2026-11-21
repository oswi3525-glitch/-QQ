import SwiftUI
import UIKit

/// Pairing & JIT (M8) — iOS 27 device-initiated remote pairing.
struct PairingJITView: View {
    @StateObject private var pairing = PairingManager.shared
    @StateObject private var jit = JITManager.shared

    @State private var message: String?
    @State private var sharePayload: SharePayload?
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            statusSection
            instructionsSection
            pinSection
            pairingFileSection
            jitSection
        }
        .navigationTitle("Pairing & JIT")
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear { pairing.recheck() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack {
                Label(pairing.isPaired ? "Đã ghép nối" : "Chưa ghép nối",
                      systemImage: pairing.isPaired ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(pairing.isPaired ? .green : .orange)
                Spacer()
                if pairing.isDeviceConnected {
                    Label("thiết bị đã kết nối", systemImage: "wifi")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            if let device = pairing.deviceName {
                LabeledContent("Thiết bị", value: device)
            }

            if pairing.isAdvertising {
                LabeledContent("Đang quảng bá", value: PairingManager.serviceType)
                if let port = pairing.advertisedPort {
                    LabeledContent("Cổng", value: String(port))
                }
            }

            if let status = pairing.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = pairing.lastError {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !PairingManager.supportsDeviceInitiatedPairing {
                Label("Tính năng ghép nối trực tiếp cần iOS 27 trở lên. "
                      + "Trên iOS cũ hơn, hãy dùng file pairing có sẵn.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Trạng thái")
        } footer: {
            Text("WQTerm quảng bá dịch vụ Bonjour \(PairingManager.serviceType) để iPhone "
                 + "tự tìm thấy trong Cài đặt › Chế độ nhà phát triển › Ghép nối.")
                .font(.caption2)
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        Section {
            ForEach(Array(PairingManager.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(index == 0 ? Color.accentColor : Color.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.subheadline.weight(.medium))
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            Text("Hướng dẫn từng bước")
        } footer: {
            Text("Developer Mode bắt buộc bật và khởi động lại thiết bị. "
                 + "Quyền Mạng nội bộ chỉ hiện sau lần đầu WQTerm quảng bá dịch vụ.")
                .font(.caption2)
        }
    }

    // MARK: - PIN

    private var pinSection: some View {
        Section {
            VStack(spacing: 8) {
                Text(pairing.pairingCode)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .textSelection(.enabled)
                    .accessibilityLabel("Mã PIN ghép nối \(pairing.pairingCode)")

                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = pairing.pairingCode
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        message = "Đã sao chép mã PIN."
                    } label: {
                        Label("Sao chép", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        pairing.refreshCode()
                    } label: {
                        Label("Mã mới", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            if pairing.isAdvertising {
                Button(role: .destructive) {
                    pairing.stopHost()
                } label: {
                    Label("Dừng quảng bá", systemImage: "stop.circle")
                }
            } else {
                Button {
                    pairing.startHost()
                } label: {
                    Label("Bắt đầu ghép nối", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                pairing.requestLocalNetworkPermission()
                message = "Đã yêu cầu quyền Mạng nội bộ. Nếu chưa thấy prompt, "
                    + "vào Cài đặt › WQTerm › Mạng nội bộ để bật."
            } label: {
                Label("Cấp quyền Mạng nội bộ", systemImage: "wifi")
            }

            Button {
                pairing.markPaired()
                message = pairing.statusMessage
            } label: {
                Label("Tôi đã nhập mã — hoàn tất", systemImage: "checkmark.circle")
            }
            .disabled(pairing.isPaired)
        } header: {
            Text("Mã PIN 6 chữ số")
        } footer: {
            Text("Mã được sinh ngẫu nhiên mỗi phiên. Nhập mã này trên iPhone khi hộp thoại "
                 + "ghép nối xuất hiện. Không chia sẻ mã cho người khác.")
                .font(.caption2)
        }
    }

    // MARK: - Pairing file

    private var pairingFileSection: some View {
        Section {
            if let url = pairing.pairingFileURL {
                Text(url.path)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("Chưa có file pairing. Hoàn tất ghép nối để WQTerm tự lưu vào Documents/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                exportPairing()
            } label: {
                Label("Xuất file mobiledevicepairing", systemImage: "square.and.arrow.up")
            }

            if pairing.isPaired {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Đặt lại trạng thái ghép nối", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Pairing file")
        } footer: {
            Text("File được lưu tại Documents/mobiledevicepairing và bản sao "
                 + "Documents/WQTerm.mobiledevicepairing (quyền 0600). Dùng cho JIT / SideStore.")
                .font(.caption2)
        }
    }

    // MARK: - JIT

    private var jitSection: some View {
        Section {
            LabeledContent("Trạng thái JIT", value: jit.status.rawValue)

            Button {
                jit.refreshStatus()
                message = "Đã làm mới trạng thái JIT: \(jit.status.rawValue)"
            } label: {
                Label("Kiểm tra lại JIT", systemImage: "arrow.clockwise")
            }

            Button {
                openStikDebug()
            } label: {
                Label("Bật JIT bằng StikDebug", systemImage: "bolt.fill")
            }
            .disabled(jit.enableJITURL() == nil)
        } header: {
            Text("JIT (StikDebug)")
        } footer: {
            Text("JIT không bắt buộc — mọi tính năng cơ bản chạy được khi không có JIT. "
                 + "Cần get-task-allow = true trong entitlements.")
                .font(.caption2)
        }
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
            if !success { message = "Không mở được StikDebug. Kiểm tra đã cài app chưa." }
        }
    }
}

/// Bọc một `URL` để dùng với `.sheet(item:)` mà không cần mở rộng `URL`.
struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
