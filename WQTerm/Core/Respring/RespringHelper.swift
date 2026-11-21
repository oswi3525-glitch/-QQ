import Foundation
import UIKit
import WebKit

/// Cách thực hiện respring (không reboot).
enum RespringMethod: String, CaseIterable {
    /// Quá tải GPU process của WebKit bằng hàng trăm lớp `backdrop-filter`.
    case neoSpring
    /// Gửi lệnh qua tunnel LocalDevVPN (Diagnostics Relay) — phương án dự phòng.
    case diagnosticsRelay

    var displayName: String {
        switch self {
        case .neoSpring: return "NeoSpring (WebKit GPU)"
        case .diagnosticsRelay: return "Diagnostics Relay (LocalDevVPN)"
        }
    }
}

/// Thực hiện respring SpringBoard mà không reboot thiết bị.
///
/// Luồng mặc định:
/// 1. Mở một `UIWindow` đen toàn màn hình chứa `WKWebView`.
/// 2. WebView tải HTML với ~360 lớp `backdrop-filter: blur(100px)` → GPU process
///    của WebKit quá tải → hệ thống kill và khởi động lại SpringBoard.
/// 3. Nếu sau `timeout` vẫn chưa respring (không khả thi), tự động thử lại qua
///    Diagnostics Relay trên tunnel `10.7.0.1`.
final class RespringHelper {
    static let shared = RespringHelper()

    /// Cổng Diagnostics Relay mặc định trên loopback của LocalDevVPN.
    static let relayURL = "http://10.7.0.1:8080/diagnostics/respring"
    /// Số giây chờ NeoSpring trước khi chuyển sang phương án dự phòng.
    static let neoSpringTimeout: TimeInterval = 8

    private var overlayWindow: UIWindow?
    private var fallbackTimer: Timer?
    private var completion: ((Bool, String) -> Void)?

    var isRunning: Bool { overlayWindow != nil }

    // MARK: - Public

    /// Bắt đầu respring. `completion` nhận `(thành công, thông báo)`.
    func respring(preferred: RespringMethod = .neoSpring,
                  completion: ((Bool, String) -> Void)? = nil) {
        DispatchQueue.main.async {
            guard !self.isRunning else {
                completion?(false, "Một phiên respring đang chạy.")
                return
            }
            self.completion = completion
            switch preferred {
            case .neoSpring:
                if self.startNeoSpring() {
                    self.scheduleFallback()
                } else {
                    self.finishWithRelay(reason: "Không tạo được WKWebView.")
                }
            case .diagnosticsRelay:
                self.finishWithRelay(reason: "Đã chọn Diagnostics Relay.")
            }
        }
    }

    /// Đóng overlay (dùng khi cần huỷ thủ công trước khi SpringBoard kịp restart).
    func dismissOverlay() {
        DispatchQueue.main.async {
            self.fallbackTimer?.invalidate()
            self.fallbackTimer = nil
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
        }
    }

    // MARK: - NeoSpring

    private func startNeoSpring() -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.windowLevel = .alert + 1

        let controller = UIViewController()
        controller.view.backgroundColor = .black

        let webView = WKWebView(frame: .zero)
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = controller.view.bounds
        controller.view.addSubview(webView)
        webView.loadHTMLString(Self.stressHTML, baseURL: nil)

        window.rootViewController = controller
        window.makeKeyAndVisible()
        overlayWindow = window
        return true
    }

    private func scheduleFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: Self.neoSpringTimeout,
                                             repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.isRunning else { return }
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
            self.finishWithRelay(reason: "NeoSpring không tạo được quá tải GPU trong "
                                 + "\(Int(Self.neoSpringTimeout)) giây.")
        }
    }

    /// HTML tạo hàng trăm lớp mờ — chỉ dùng trong overlay respring.
    private static let stressHTML: String = {
        var tiles = ""
        for index in 0..<360 {
            let size = 90 + (index % 9) * 28
            let x = (index % 40) * 17
            let y = (index % 26) * 19
            let rotation = index % 360
            tiles += "<div class='glass' style='width:\(size)px;height:\(size)px;"
                + "transform:translate(\(x)px,\(y)px) rotate(\(rotation)deg)'></div>"
        }
        return """
        <html><head><meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>
          html,body{margin:0;padding:0;background:#000;overflow:hidden;}
          .glass{position:absolute;border-radius:36px;
            background:rgba(255,255,255,0.04);
            -webkit-backdrop-filter:blur(100px) saturate(180%);
            backdrop-filter:blur(100px) saturate(180%);
            will-change:transform;}
        </style></head><body>\(tiles)</body></html>
        """
    }()

    // MARK: - Diagnostics Relay fallback

    private func finishWithRelay(reason: String) {
        guard NetworkUtils.isLocalDevVPNActive else {
            finish(false, "Không thể dự phòng: LocalDevVPN chưa bật. \(reason)")
            return
        }

        guard let url = URL(string: Self.relayURL) else {
            finish(false, "URL Diagnostics Relay không hợp lệ.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "respring",
            "source": "WQTerm"
        ])
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let succeeded = error == nil && (200..<300).contains(status)
            DispatchQueue.main.async {
                if succeeded {
                    self.finish(true, "Respring đã được gửi qua Diagnostics Relay. \(reason)")
                } else {
                    self.finish(false, "Diagnostics Relay lỗi: "
                                + (error?.localizedDescription ?? "HTTP \(status)") + " \(reason)")
                }
            }
        }.resume()
    }

    private func finish(_ success: Bool, _ message: String) {
        dismissOverlay()
        let handler = completion
        completion = nil
        handler?(success, message)
    }
}
