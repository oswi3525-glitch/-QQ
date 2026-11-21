import Foundation

/// Nguồn cấu hình DUY NHẤT cho LocalDevVPN + Pairing Host.
///
/// Mọi nơi (NetworkUtils, TunnelListenerManager, RespringHelper, PairingManager,
/// UI) đều đọc từ đây. Không còn địa chỉ IP / port bị hardcode rải rác.
///
/// QUAN TRỌNG — hai khái niệm địa chỉ tách biệt:
/// * `preferredAddress` (mặc định `10.7.0.1`): giá trị **mong đợi** do người dùng
///   cấu hình. Đây KHÔNG phải bằng chứng tunnel tồn tại.
/// * `confirmedAddress`: địa chỉ **thực tế** đọc được từ interface tunnel và đã
///   được người dùng xác nhận (qua bước discovery trong chẩn đoán).
///
/// Hệ thống không bao giờ tự đổi `preferredAddress` sang địa chỉ khác. Khi topology
/// thực tế không khớp (ví dụ máy chỉ có `utun4 = 10.7.1.1`), ứng dụng báo
/// `candidateAvailable` và yêu cầu xác nhận — xem `TunnelResolver`.
final class TunnelConfiguration {
    static let shared = TunnelConfiguration()

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let addressKey = "WQTerm.Tunnel.Address"
    private let confirmedAddressKey = "WQTerm.Tunnel.ConfirmedAddress"
    private let listenerPortKey = "WQTerm.Tunnel.ListenerPort"
    private let relayPortKey = "WQTerm.Tunnel.RelayPort"

    /// Địa chỉ tunnel **mong đợi** (giá trị mặc định, có thể đổi trong Cài đặt).
    /// Giá trị này một mình KHÔNG chứng minh tunnel hoạt động.
    static let defaultAddress = "10.7.0.1"
    static let defaultRelayPort: UInt16 = 8080
    /// 0 = để hệ thống cấp port động; Bonjour sẽ quảng bá port thực tế.
    static let defaultListenerPort: UInt16 = 0

    private init() {}

    /// Địa chỉ mong đợi do người dùng cấu hình (không phải bằng chứng tunnel).
    var preferredAddress: String {
        let stored = defaults.string(forKey: addressKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return IPv4.parse(stored ?? "") != nil ? stored! : Self.defaultAddress
    }

    /// Alias tương thích call site cũ: địa chỉ *mong đợi*.
    var tunnelAddress: String { preferredAddress }

    /// Địa chỉ thực tế đã được người dùng xác nhận sau discovery (nếu có).
    var confirmedAddress: String? {
        guard let value = defaults.string(forKey: confirmedAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              IPv4.parse(value) != nil else { return nil }
        return value
    }

    /// Địa chỉ dùng để bind listener/relay: ưu tiên giá trị đã xác nhận.
    /// `nil` khi chưa có xác nhận VÀ giá trị mong đợi chưa được kiểm chứng — nơi
    /// gọi phải dùng `TunnelResolver` để quyết định, không được bind mù.
    var effectiveAddress: String { confirmedAddress ?? preferredAddress }

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
        URL(string: "http://\(effectiveAddress):\(relayPort)")
    }

    var listenerPortLabel: String {
        listenerPort == 0 ? "tự động" : String(listenerPort)
    }

    var summary: String {
        var text = "\(preferredAddress)"
        if let confirmed = confirmedAddress, confirmed != preferredAddress {
            text += " (xác nhận: \(confirmed))"
        }
        return text + " · listener \(listenerPortLabel) · relay \(relayPort)"
    }

    /// Cập nhật cấu hình. Trả về thông báo lỗi nếu giá trị không hợp lệ;
    /// `nil` nghĩa là đã lưu thành công.
    ///
    /// Đổi `preferredAddress` sẽ **xoá** `confirmedAddress` cũ: xác nhận trước đó
    /// thuộc về một topology khác nên không còn giá trị.
    @discardableResult
    func update(address: String?, listenerPort: UInt16?, relayPort: UInt16?) -> String? {
        if let address {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard IPv4.parse(trimmed) != nil, !IPv4.isLoopback(IPv4.parse(trimmed)!) else {
                return "Địa chỉ tunnel không hợp lệ (cần IPv4 riêng, ví dụ 10.7.0.1)."
            }
            if defaults.string(forKey: addressKey) != trimmed {
                defaults.removeObject(forKey: confirmedAddressKey)
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

    /// Xác nhận địa chỉ tunnel thực tế (sau khi người dùng đồng ý với ứng viên).
    /// Chỉ lưu địa chỉ hợp lệ và riêng — không nhận loopback hay địa chỉ công khai.
    @discardableResult
    func confirm(address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let octets = IPv4.parse(trimmed), IPv4.isPrivate(octets) else { return false }
        defaults.set(trimmed, forKey: confirmedAddressKey)
        return true
    }

    func clearConfirmedAddress() {
        defaults.removeObject(forKey: confirmedAddressKey)
    }

    func resetToDefaults() {
        defaults.removeObject(forKey: addressKey)
        defaults.removeObject(forKey: confirmedAddressKey)
        defaults.removeObject(forKey: listenerPortKey)
        defaults.removeObject(forKey: relayPortKey)
    }

    /// Kiểm tra IPv4 hợp lệ (giữ tên cũ cho call site đang dùng).
    static func isValidIPv4(_ value: String) -> Bool {
        IPv4.parse(value) != nil
    }
}
