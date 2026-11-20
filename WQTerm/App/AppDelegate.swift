import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Module 1: tự động quét app đã cài + mount container vào
        // Documents/_sandbox/ ngay khi app khởi động (chạy nền, không chặn UI).
        SandboxManager.shared.bootstrap()

        // Module 5: sinh setup_env.sh, cấp quyền thực thi cho toolchain, cài ai.py.
        EnvironmentSetup.shared.prepareInBackground()

        // M6: bắt đầu audit log.
        AuditLogger.shared.log(event: .appLaunch)
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        IOSCompatibility.shared.recheckOnForeground()
    }
}
