import SwiftUI

/// Tab Settings (M5–M10): hub điều hướng tới toàn bộ tính năng cấu hình.
///
/// Dùng `List` + `NavigationStack` chuẩn SwiftUI (hỗ trợ Dark Mode tự động vì
/// mọi màu đều là semantic: `.primary`, `.secondary`, `.accentColor`, `.bar`).
struct SettingsView: View {
    @StateObject private var compatibility = IOSCompatibility.shared
    @StateObject private var safeMode = SafeMode.shared
    @StateObject private var faceID = FaceIDLock.shared

    var body: some View {
        NavigationStack {
            List {
                compatibilitySection
                securitySection
                modulesSection
                aboutSection
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Banner trạng thái worse_query — nằm trong layout, KHÔNG phủ lên UI.
                WarningBanner(message: compatibility.bannerMessage,
                              type: bannerType)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
    }

    private var bannerType: WarningBanner.BannerType {
        switch compatibility.status {
        case .fullSupport: return .info
        case .partialSupport: return .warning
        case .patched: return .restricted
        case .unknown: return .warning
        }
    }

    // MARK: - Compatibility (M0/PRD §3)

    private var compatibilitySection: some View {
        Section {
            LabeledContent("iOS", value: compatibility.version.description)
            LabeledContent("Build", value: compatibility.buildVersion.isEmpty ? "—" : compatibility.buildVersion)
            LabeledContent("worse_query", value: compatibility.status.displayName)
            LabeledContent("MobileGestalt", value: compatibility.gestalt.displayName)

            if let reason = compatibility.gestaltBlockReason {
                Label(reason, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Tương thích thiết bị")
        } footer: {
            Text("Gestalt bị vô hiệu hoá hoàn toàn từ iOS 27.3 Beta 2 trở đi. "
                 + "Trạng thái được kiểm tra lại mỗi lần app vào foreground.")
                .font(.caption2)
        }
    }

    // MARK: - Security (M6)

    private var securitySection: some View {
        Section("Bảo mật") {
            Toggle(isOn: Binding(
                get: { faceID.isEnabled },
                set: { SecurityManager.shared.setFaceIDEnabled($0) }
            )) {
                Label("Khoá bằng Face ID", systemImage: "faceid")
            }

            Toggle(isOn: Binding(
                get: { safeMode.isEnabled },
                set: { safeMode.setEnabled($0) }
            )) {
                Label("Chỉ đọc (SafeMode)", systemImage: "lock.doc")
            }

            NavigationLink {
                SecuritySettingsView()
            } label: {
                Label("Chi tiết bảo mật", systemImage: "shield.lefthalf.filled")
            }
        }
    }

    // MARK: - Modules (M5–M10)

    private var modulesSection: some View {
        Section("Tính năng") {
            NavigationLink {
                AccessorySettingsView()
            } label: {
                Label("Bàn phím phụ (M5)", systemImage: "keyboard")
            }

            NavigationLink {
                PreviewSettingsView()
            } label: {
                Label("Preview & renderer (M7)", systemImage: "doc.text.magnifyingglass")
            }

            NavigationLink {
                GestaltView()
            } label: {
                Label("MobileGestalt", systemImage: "cpu")
            }

            NavigationLink {
                PairingJITView()
            } label: {
                Label("Pairing & JIT (M8)", systemImage: "link.badge.plus")
            }
        }
    }

    // MARK: - About (M10)

    private var aboutSection: some View {
        Section("Về ứng dụng") {
            LabeledContent("Phiên bản", value: Self.appVersion)
            LabeledContent("Backend shell", value: CommandRunner.backendLabel)

            NavigationLink {
                AuditLogView()
            } label: {
                Label("Nhật ký thao tác (M6)", systemImage: "list.bullet.rectangle")
            }

            NavigationLink {
                FeedbackFormView()
            } label: {
                Label("Báo cáo lỗi / Feedback", systemImage: "exclamationmark.bubble")
            }
        }
    }

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
