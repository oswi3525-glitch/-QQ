import Foundation

/// Nguồn cấu hình DUY NHẤT cho LocalDevVPN + Pairing Host.
///
/// Mọi nơi (NetworkUtils, RespringHelper, PairingManager, UI) đều đọc từ đây.
/// Không còn địa chỉ IP / port bị hardcode rải rác. Giá trị có thể đổi trong
/// Cài đặt mà không cần sửa code, và luôn được kiểm tra hợp lệ trước khi dùng.
final class TunnelConfiguration {
    static let shared = TunnelConfiguration()

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let addressKey = "WQTerm.Tunnel.Address"
    private let listenerPortKey = "WQTerm.Tunnel.ListenerPort"
    private let relayPortKey = "WQTerm.Tunnel.RelayPort"

    /// Địa chỉ loopback mà pairing iOS 27 yêu cầu (giá trị mặc định, có thể đổi).
    static let defaultAddress = "10.7.0.1"
    static let defaultRelayPort: UInt16 = 8080
    /// 0 = để hệ thống cấp port động; Bonjour sẽ quảng bá port thực tế.
    static let defaultListenerPort: UInt16 = 0

    private init() {}

    var tunnelAddress: String {
        let stored = defaults.string(forKey: addressKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isValidIPv4(stored ?? "") ? stored! : Self.defaultAddress
    }

    /// Port TCP của Pairing Host. 0 nghĩa là port động (ephemeral).
    var listenerPort: UInt16 {
        let raw = defaults.integer(forKey: listenerPortKey)
        return raw >= 0 && raw <= 65535 ? UInt16(raw) : Self.defaultListenerPort
    }

    /// Port của Diagnostics Relay trên tunnel.
    var relayPort: UInt16 {
        let raw = defaults.integer(forKey: relayPortKey)
        return raw > 0 && raw <= 65535 ? UInt16(raw) : Self.defaultRelayPort
    }

    var relayBaseURL: URL? {
        URL(string: "http://\(tunnelAddress):\(relayPort)")
    }

    var listenerPortLabel: String {
        listenerPort == 0 ? "tự động" : String(listenerPort)
    }

    var summary: String { "\(tunnelAddress) · listener \(listenerPortLabel) · relay \(relayPort)" }

    /// Cập nhật cấu hình. Trả về thông báo lỗi nếu giá trị không hợp lệ;
    /// `nil` nghĩa là đã lưu thành công.
    @discardableResult
    func update(address: String?, listenerPort: UInt16?, relayPort: UInt16?) -> String? {
        if let address {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidIPv4(trimmed) else {
                return "Địa chỉ tunnel không hợp lệ (cần IPv4, ví dụ 10.7.0.1)."
            }
            defaults.set(trimmed, forKey: addressKey)
        }
        if let listenerPort {
            guard listenerPort <= 65535 else { return "Port listener không hợp lệ." }
            defaults.set(Int(listenerPort), forKey: listenerPortKey)
        }
        if let relayPort {
            guard relayPort > 0, relayPort <= 65535 else { return "Port relay không hợp lệ." }
            defaults.set(Int(relayPort), forKey: relayPortKey)
        }
        return nil
    }

    func resetToDefaults() {
        defaults.removeObject(forKey: addressKey)
        defaults.removeObject(forKey: listenerPortKey)
        defaults.removeObject(forKey: relayPortKey)
    }

    static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let number = Int(part) else { return false }
            return number >= 0 && number <= 255
        }
    }
}
