import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Kiểm tra trạng thái của LocalDevVPN — điều kiện bắt buộc của pairing iOS 27.
///
/// LocalDevVPN tạo một tunnel loopback (`utun*`) với địa chỉ `10.7.0.1`
/// (hoặc `127.0.0.1` trên một số bản). Không có tunnel này thì service
/// Bonjour của WQTerm không thấy thiết bị và màn hình PIN bị treo sau khi
/// người dùng nhập mật khẩu khóa máy.
enum NetworkUtils {
    /// Địa chỉ loopback mà LocalDevVPN gán cho tunnel.
    static let localDevVPNAddress = "10.7.0.1"
    static let fallbackLoopbackAddress = "127.0.0.1"

    struct TunnelInfo {
        let interfaceNames: [String]
        let addresses: [String]

        var isActive: Bool { !interfaceNames.isEmpty || !addresses.isEmpty }

        var summary: String {
            if interfaceNames.isEmpty, addresses.isEmpty {
                return "Không phát hiện tunnel LocalDevVPN"
            }
            let iface = interfaceNames.isEmpty ? "—" : interfaceNames.joined(separator: ", ")
            let addr = addresses.isEmpty ? "—" : addresses.joined(separator: ", ")
            return "Tunnel \(iface) — \(addr)"
        }
    }

    /// `true` khi có interface `utun*` HOẶC địa chỉ `10.7.0.1`/`127.0.0.1` tồn tại.
    static var isLocalDevVPNActive: Bool { currentTunnelInfo().isActive }

    /// Thông tin chi tiết để hiển thị trên UI.
    static func currentTunnelInfo() -> TunnelInfo {
        var names: [String] = []
        var addresses: [String] = []

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return TunnelInfo(interfaceNames: [], addresses: [])
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            if let rawName = current.pointee.ifa_name {
                let name = String(cString: rawName)
                if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") {
                    names.append(name)
                }
            }

            if let rawAddress = current.pointee.ifa_addr {
                if let address = numericAddress(rawAddress.pointee) {
                    if address == localDevVPNAddress || address == fallbackLoopbackAddress {
                        addresses.append(address)
                    }
                }
            }
            cursor = current.pointee.ifa_next
        }

        return TunnelInfo(interfaceNames: Array(Set(names)).sorted(),
                          addresses: Array(Set(addresses)).sorted())
    }

    /// Chuyển `sockaddr` sang chuỗi số (không phụ thuộc `sa_len` của Darwin).
    private static func numericAddress(_ address: sockaddr) -> String? {
        let family = Int32(address.sa_family)
        let length: socklen_t
        switch family {
        case AF_INET: length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6: length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default: return nil
        }

        var mutable = address
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &mutable) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard status == 0 else { return nil }
        return String(cString: host)
    }
}
