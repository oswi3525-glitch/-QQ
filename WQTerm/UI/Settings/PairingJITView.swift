import SwiftUI
import UIKit

/// Pairing & JIT (M8) — SideStore/StikDebug/LiveContainer.
struct PairingJITView: View {
    @StateObject private var pairing = PairingManager.shared
    @StateObject private var jit = JITManager.shared

    @State private var message: String?
    @State private var sharePayload: SharePayload?

    var body: some View {
        Form {
            pairingSection
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
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
    }

    // MARK: - Sections

    private var pairingSection: some View {
        Section {
            HStack {
                Label(pairing.isPaired ? "Đã pairing" : "Chưa pairing",
                      systemImage: pairing.isPaired ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(pairing.isPaired ? .green : .orange)
                Spacer()
            }

            HStack {
                Text("Mã pairing")
                Spacer()
                Text(pairing.pairingCode)
                    .font(.title3.monospaced().bold())
                    .textSelection(.enabled)
            }

            Button {
                pairing.refreshCode()
            } label: {
                Label("Tạo mã mới", systemImage: "arrow.clockwise")
            }

            Button {
                exportPairing()
            } label: {
                Label("Xuất composite pairing file", systemImage: "square.and.arrow.up")
            }

            Button {
                pairing.markPaired()
                message = "Đã đánh dấu pairing hoàn tất."
            } label: {
                Label("Đánh dấu đã pairing", systemImage: "checkmark.circle")
            }
        } header: {
            Text("Pairing (RPPairing + lockdown)")
        } footer: {
            Text("File pairing dùng cho SideStore / LiveContainer. Cần App Group "
                 + "group.com.wqterm.app và ký qua SideStore (không dùng Sideloadly).")
                .font(.caption2)
        }
    }

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

/// Wrapper `UIActivityViewController` để chia sẻ file (pairing, log, backup).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Bọc một `URL` để dùng với `.sheet(item:)` mà không cần mở rộng `URL`.
struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
