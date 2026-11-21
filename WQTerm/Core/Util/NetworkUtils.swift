import Foundation
import Network
import Combine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Kiểm tra chính xác trạng thái tunnel LocalDevVPN.
///
/// QUAN TRỌNG: `lo0 / 127.0.0.1` luôn tồn tại trên mọi iPhone và KHÔNG phải là
/// LocalDevVPN. Tương tự, `utun0..utunN` / `ipsec*` cũng có thể là tunnel hệ
/// thống. Vì vậy địa chỉ mong đợi phải nằm TRÊN CHÍNH interface tunnel thì mới
/// được coi là "VPN sẵn sàng". Không bao giờ đánh đồng 127.0.0.1 với 10.7.0.1.
enum NetworkUtils {
    struct InterfaceAddress {
        let interface: String
        let address: String
    }

    struct TunnelInfo {
        /// Địa chỉ cấu hình (nguồn: TunnelConfiguration, không hardcode ở đây).
        let expectedAddress: String
        /// Interface thực sự mang địa chỉ mong đợi.
        let matchedInterfaces: [String]
        /// Mọi địa chỉ IPv4 tìm thấy trên interface dạng tunnel.
        let tunnelAddresses: [InterfaceAddress]
        /// Địa chỉ mong đợi có tồn tại nhưng nằm ngoài tunnel (ví dụ trên lo0).
        let addressFoundOutsideTunnel: Bool

        var hasExpectedAddress: Bool { !matchedInterfaces.isEmpty }

        /// Chỉ `true` khi địa chỉ cấu hình nằm trên interface tunnel thực tế.
        var isReady: Bool { hasExpectedAddress }

        var summary: String {
            guard isReady else {
                return addressFoundOutsideTunnel
                    ? "\(expectedAddress) có trên interface thường, không phải tunnel"
                    : "Chưa thấy \(expectedAddress) trên tunnel"
            }
            return "\(expectedAddress) @ \(matchedInterfaces.joined(separator: ", "))"
        }

        var detail: String {
            let interfaces = tunnelAddresses.isEmpty
                ? "không có interface tunnel IPv4"
                : tunnelAddresses.map { "\($0.interface)=\($0.address)" }.joined(separator: ", ")
            return "\(summary) | \(interfaces)"
        }
    }

    /// `true` khi LocalDevVPN thực sự sẵn sàng (địa chỉ cấu hình nằm trên tunnel).
    static var isLocalDevVPNActive: Bool { currentTunnelInfo().isReady }

    static func currentTunnelInfo() -> TunnelInfo {
        let expected = TunnelConfiguration.shared.tunnelAddress
        var matched: [String] = []
        var tunnelAddresses: [InterfaceAddress] = []
        var foundOutside = false

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return TunnelInfo(expectedAddress: expected,
                              matchedInterfaces: [],
                              tunnelAddresses: [],
                              addressFoundOutsideTunnel: false)
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let name = current.pointee.ifa_name.map { String(cString: $0) } ?? ""
            let isTunnelInterface = name.hasPrefix("utun") || name.hasPrefix("ppp")
                || name.hasPrefix("ipsec")

            if let rawAddress = current.pointee.ifa_addr,
               let address = numericAddress(rawAddress.pointee) {
                if isTunnelInterface {
                    tunnelAddresses.append(InterfaceAddress(interface: name, address: address))
                }
                if address == expected {
                    if isTunnelInterface {
                        matched.append(name)
                    } else {
                        foundOutside = true
                    }
                }
            }
            cursor = current.pointee.ifa_next
        }

        return TunnelInfo(expectedAddress: expected,
                          matchedInterfaces: Array(Set(matched)).sorted(),
                          tunnelAddresses: tunnelAddresses,
                          addressFoundOutsideTunnel: foundOutside)
    }

    /// Kiểm tra route/traffic tới địa chỉ tunnel bằng TCP connect có timeout.
    /// Không phải là bằng chứng handshake pairing, chỉ là kiểm tra mạng.
    static func canReachTunnel(port: UInt16? = nil,
                               timeout: TimeInterval = 1.5) async -> Bool {
        let host = TunnelConfiguration.shared.tunnelAddress
        let targetPort = port ?? TunnelConfiguration.shared.relayPort
        return await canReach(host: host, port: targetPort, timeout: timeout)
    }

    static func canReach(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: endpointPort,
                                      using: .tcp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { result in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.wqterm.tunnel.probe"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
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

/// Theo dõi tunnel liên tục để UI không báo "VPN đang bật" khi tunnel đã mất.
final class TunnelMonitor: ObservableObject {
    static let shared = TunnelMonitor()

    @Published private(set) var info: NetworkUtils.TunnelInfo
    @Published private(set) var lastChangeDate: Date = Date()

    private var timer: Timer?
    private var running = false

    private init() {
        info = NetworkUtils.currentTunnelInfo()
    }

    var isReady: Bool { info.isReady }

    func start() {
        guard !running else { return }
        running = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    func refresh() {
        let newInfo = NetworkUtils.currentTunnelInfo()
        let changed = newInfo.matchedInterfaces != info.matchedInterfaces
            || newInfo.addressFoundOutsideTunnel != info.addressFoundOutsideTunnel
        info = newInfo
        if changed {
            lastChangeDate = Date()
            NotificationCenter.default.post(name: .wqTunnelDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let wqTunnelDidChange = Notification.Name("WQTerm.Tunnel.DidChange")
}
