import SwiftUI
import UIKit

/// Root của toàn bộ ứng dụng.
///
/// Cấu trúc: `TabView` với **5 tab chính**:
/// 1. Terminal  (M1 — Terminal Core, a-Shell + BuiltinShell fallback)
/// 2. Sandbox   (M1/M2 — Auto worse_query, quét app, mount container, Dump IPA)
/// 3. Files     (M3 — cây Documents + _sandbox, QuickLook, renderer)
/// 4. AI        (M4 — LiteRouter chat + API key trong Keychain)
/// 5. Settings  (M5–M10 — bàn phím phụ, Preview, Security, Pairing, JIT, Gestalt)
///
/// Banner cảnh báo **không** phủ lên `TabView` (bản cũ dùng `ZStack` khiến tab bar
/// và navigation bar bị che). Nó được đặt *bên trong* từng màn hình.
///
/// Mọi tác vụ nặng (quét app, mount, dump, gọi API) chạy trên background queue —
/// view chỉ đọc `@Published`, nên chuyển tab không bị treo (Module 6).
struct MainTabView: View {
    @StateObject private var compatibility = IOSCompatibility.shared
    @StateObject private var security = SecurityManager.shared
    @StateObject private var sandbox = SandboxManager.shared
    @StateObject private var tabSelection = TabSelection()

    // selection giờ do TabSelection giữ để màn hình con đổi tab được.

    /// 5 tab chính của app.
    enum Tab: String, CaseIterable, Identifiable {
        case terminal
        case sandbox
        case files
        case ai
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .terminal: return "Terminal"
            case .sandbox: return "Sandbox"
            case .files: return "Files"
            case .ai: return "AI"
            case .settings: return "Cài đặt"
            }
        }

        var systemImage: String {
            switch self {
            case .terminal: return "terminal"
            case .sandbox: return "externaldrive.connected.to.line.below"
            case .files: return "folder"
            case .ai: return "sparkles"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        Group {
            if security.isLocked {
                LockPlaceholderView()
            } else if !OnboardingStorage.hasAgreed {
                OnboardingView { OnboardingStorage.markAgreed() }
            } else {
                tabView
            }
        }
        .onAppear {
            compatibility.recheckOnForeground()
            // Module 1: tự động quét + mount container ngay khi MainView xuất hiện.
            sandbox.bootstrap()
            EnvironmentSetup.shared.prepareInBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            compatibility.recheckOnForeground()
            security.refreshLockState()
        }
    }

    // MARK: - Tabs

    private var tabView: some View {
        TabView(selection: Binding(
            get: { tabSelection.current },
            set: { tabSelection.current = $0 }
        )) {
            TerminalView()
                .tabItem { Label(Tab.terminal.title, systemImage: Tab.terminal.systemImage) }
                .tag(Tab.terminal)

            SandboxView()
                .tabItem { Label(Tab.sandbox.title, systemImage: Tab.sandbox.systemImage) }
                .tag(Tab.sandbox)

            FilesView()
                .tabItem { Label(Tab.files.title, systemImage: Tab.files.systemImage) }
                .tag(Tab.files)

            AIView()
                .tabItem { Label(Tab.ai.title, systemImage: Tab.ai.systemImage) }
                .tag(Tab.ai)

            SettingsView()
                .tabItem { Label(Tab.settings.title, systemImage: Tab.settings.systemImage) }
                .tag(Tab.settings)
        }
        .tint(.accentColor)
        .environmentObject(tabSelection)
    }
}

// MARK: - Onboarding storage (UserDefaults)

enum OnboardingStorage {
    private static let key = "WQTerm.Onboarding.Agreed"
    static var hasAgreed: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
    static func markAgreed() {
        UserDefaults.standard.set(true, forKey: key)
    }
}

// MARK: - Lock / Onboarding screens

/// Màn hình khi app bị khoá bằng Face ID.
struct LockPlaceholderView: View {
    @StateObject private var security = SecurityManager.shared
    @State private var message: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("WQTerm đang bị khóa")
                .font(.headline)
            Text("Vui lòng xác thực Face ID để mở khóa ứng dụng.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                security.unlock { success in
                    if !success { message = "Xác thực thất bại. Thử lại." }
                }
            } label: {
                Label("Mở khoá bằng Face ID", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
    }
}

/// Cảnh báo pháp lý hiển thị lần đầu mở app.
struct OnboardingView: View {
    let onAgree: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)

                Text("WQTerm — Cảnh báo bảo mật")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("WQTerm đọc/ghi được dữ liệu của các ứng dụng khác trên thiết bị. "
                     + "Chỉ dùng trên thiết bị cá nhân hoặc có sự cho phép bằng văn bản. "
                     + "Truy cập dữ liệu người khác có thể vi phạm pháp luật "
                     + "(Điều 289 Bộ luật Hình sự 2015).")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.red)

                Text("Apple có thể vá worse_query bất kỳ lúc nào — đóng băng iOS ở phiên bản hỗ trợ.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Tôi đồng ý và tiếp tục") { onAgree() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
    }
}
