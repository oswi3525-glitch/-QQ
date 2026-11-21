import Foundation
import Network
import Combine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Đọc topology mạng thực tế và phân giải địa chỉ LocalDevVPN.
///
/// QUAN TRỌNG: `lo0 / 127.0.0.1` luôn tồn tại trên mọi iPhone và KHÔNG phải là
/// LocalDevVPN. `utun0..utunN` / `ipsec*` cũng thường là tunnel hệ thống (ví dụ
/// `ipsec4 = 28.215.155.104`). Vì vậy một địa chỉ chỉ được coi là "VPN sẵn sàng"
/// khi nó nằm trên interface tunnel point-to-point đang UP + RUNNING, là địa chỉ
/// riêng, và khớp cấu hình hoặc địa chỉ đã được người dùng xác nhận.
///
/// Toàn bộ quyết định nằm trong `TunnelResolver` (thuần, test được); file này chỉ
/// chịu trách nhiệm đọc `getifaddrs` rồi chuyển thành `InterfaceSnapshot`.
enum NetworkUtils {
    struct InterfaceAddress: Equatable {
        let interface: String
        let address: String
    }

    /// Ảnh chụp topology tại một thời điểm.
    struct Topology {
        let interfaces: [InterfaceSnapshot]
        let resolution: TunnelResolution
        /// Toàn bộ địa chỉ IPv4 (mọi interface) — dùng để hiển thị chẩn đoán.
        let allAddresses: [InterfaceAddress]
        let capturedAt: Date

        /// Interface tunnel nhìn thấy được (kể cả không đủ điều kiện).
        var tunnelInterfaces: [String] {
            Array(Set(interfaces.filter { $0.kind.isTunnel }.map(\.name))).sorted()
        }

        /// Mô tả ngắn "utun4=10.7.1.1, ipsec4=28.215.155.104".
        var tunnelDetail: String {
            let tunnel = interfaces.filter { $0.kind.isTunnel }
            guard !tunnel.isEmpty else { return "không có interface tunnel" }
            return tunnel
                .sorted { $0.name == $1.name ? $0.address < $1.address : $0.name < $1.name }
                .map { "\($0.name)=\($0.address)" }
                .joined(separator: ", ")
        }
    }

    struct TunnelInfo {
        /// Địa chỉ **mong đợi** từ cấu hình (nguồn: TunnelConfiguration).
        let expectedAddress: String
        /// Địa chỉ thực tế đã phân giải được (nếu `isReady`).
        let resolvedAddress: String?
        /// Interface thực sự mang địa chỉ mong đợi cấu hình.
        let matchedInterfaces: [String]
        /// Mọi địa chỉ IPv4 tìm thấy trên interface dạng tunnel.
        let tunnelAddresses: [InterfaceAddress]
        /// Địa chỉ mong đợi có tồn tại nhưng nằm ngoài tunnel (ví dụ trên lo0).
        let addressFoundOutsideTunnel: Bool
        /// Kết quả phân giải đầy đủ (gồm candidate/rejections) để chẩn đoán.
        let resolution: TunnelResolution
        /// Chi tiết topology "utun4=10.7.1.1, ipsec4=…".
        let topologyDetail: String

        var hasExpectedAddress: Bool { !matchedInterfaces.isEmpty }

        /// Chỉ `true` khi có địa chỉ tunnel đã xác minh và được phép dùng.
        var isReady: Bool { resolution.isActive }

        /// Có tunnel nhưng địa chỉ khác cấu hình — cần người dùng xác nhận.
        var hasPendingCandidates: Bool {
            if case .candidateAvailable = resolution { return true }
            return false
        }

        var summary: String {
            switch resolution {
            case let .active(address, interface, _, adopted):
                let suffix = adopted ? " (đã xác nhận)" : ""
                return "\(address) @ \(interface)\(suffix)"
            case let .candidateAvailable(candidates):
                let list = candidates.map(\.summary).joined(separator: ", ")
                return "Có tunnel nhưng không thấy \(expectedAddress): \(list)"
            case let .noUsableAddress(names, _):
                return "Interface \(names.joined(separator: ", ")) không có địa chỉ tunnel dùng được"
            case .noTunnelInterface:
                return "Chưa có interface tunnel — LocalDevVPN chưa bật"
            }
        }

        var detail: String {
            let interfaces = tunnelAddresses.isEmpty
                ? "không có interface tunnel IPv4"
                : tunnelAddresses.map { "\($0.interface)=\($0.address)" }.joined(separator: ", ")
            return "\(summary) | \(interfaces)"
        }
    }

    /// `true` khi LocalDevVPN thực sự sẵn sàng (địa chỉ đã xác minh trên tunnel).
    static var isLocalDevVPNActive: Bool { currentTunnelInfo().isReady }

    /// Đọc topology hiện tại và phân giải.
    static func captureTopology() -> Topology {
        let interfaces = readInterfaces()
        let config = TunnelConfiguration.shared
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: config.preferredAddress,
                                  confirmedAddress: config.confirmedAddress,
                                  interfaces: interfaces)
        )
        let all = interfaces
            .filter { $0.family == .ipv4 }
            .map { InterfaceAddress(interface: $0.name, address: $0.address) }
        return Topology(interfaces: interfaces,
                        resolution: resolution,
                        allAddresses: all,
                        capturedAt: Date())
    }

    static func currentTunnelInfo() -> TunnelInfo {
        let topology = captureTopology()
        let expected = TunnelConfiguration.shared.preferredAddress

        var matched: [String] = []
        var tunnelAddresses: [InterfaceAddress] = []
        var foundOutside = false

        for snapshot in topology.interfaces {
            let isTunnel = snapshot.kind.isTunnel
            if isTunnel, snapshot.family == .ipv4 {
                tunnelAddresses.append(InterfaceAddress(interface: snapshot.name,
                                                        address: snapshot.address))
            }
            if snapshot.address == expected {
                if isTunnel {
                    matched.append(snapshot.name)
                } else {
                    foundOutside = true
                }
            }
        }

        return TunnelInfo(expectedAddress: expected,
                          resolvedAddress: topology.resolution.activeAddress,
                          matchedInterfaces: Array(Set(matched)).sorted(),
                          tunnelAddresses: tunnelAddresses,
                          addressFoundOutsideTunnel: foundOutside,
                          resolution: topology.resolution,
                          topologyDetail: topology.tunnelDetail)
    }

    /// Đọc toàn bộ interface qua `getifaddrs`, kèm flags + peer + netmask.
    /// Không lọc bớt: `TunnelResolver` quyết định theo dữ liệu đầy đủ.
    static func readInterfaces() -> [InterfaceSnapshot] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [InterfaceSnapshot] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let current = cursor {
            let entry = current.pointee
            let name = entry.ifa_name.map { String(cString: $0) } ?? ""
            let flags = Int32(entry.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isPointToPoint = (flags & IFF_POINTOPOINT) != 0

            if !name.isEmpty, let rawAddress = entry.ifa_addr {
                let family = Int32(rawAddress.pointee.sa_family)
                if let address = numericAddress(rawAddress.pointee) {
                    let netmask = entry.ifa_netmask.flatMap { numericAddress($0.pointee) }
                    let peer = isPointToPoint
                        ? entry.ifa_dstaddr.flatMap { numericAddress($0.pointee) }
                        : nil
                    let ifFamily: InterfaceFamily = (family == AF_INET6) ? .ipv6 : .ipv4
                    // Bỏ địa chỉ IPv6 link-local (fe80::) và ::1 khỏi tunnel candidate.
                    let isLinkLocalV6 = address.lowercased().hasPrefix("fe80")
                    if family == AF_INET || (family == AF_INET6 && !isLinkLocalV6) {
                        result.append(InterfaceSnapshot(name: name,
                                                       family: ifFamily,
                                                       address: address,
                                                       netmask: netmask,
                                                       peerAddress: peer,
                                                       isUp: isUp,
                                                       isRunning: isRunning,
                                                       isPointToPoint: isPointToPoint,
                                                       isLoopback: isLoopback))
                    }
                }
            }
            cursor = entry.ifa_next
        }
        return result
    }

    /// Kiểm tra TCP tới địa chỉ tunnel (mặc định dùng relay port).
    /// Không phải bằng chứng handshake pairing, chỉ là kiểm tra route/reachability.
    static func canReachTunnel(port: UInt16? = nil,
                               timeout: TimeInterval = 1.5) async -> Bool {
        let host = TunnelConfiguration.shared.effectiveAddress
        let targetPort = port ?? TunnelConfiguration.shared.relayPort
        return await canReach(host: host, port: targetPort, timeout: timeout)
    }

    /// TCP probe có timeout + luôn `cancel()` connection (không rò rỉ socket).
    /// Trả về `true` chỉ khi `NWConnection` đạt `.ready`.
    static func canReach(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard IPv4.parse(host) != nil, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }
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

    /// Kiểm tra một địa chỉ IPv4 có đang được một interface bất kỳ sử dụng không
    /// (phát hiện xung đột IP trước khi bind).
    static func isAddressInUseOnDevice(_ address: String,
                                       excluding interfaceName: String? = nil) -> Bool {
        readInterfaces().contains {
            $0.family == .ipv4 && $0.address == address && $0.name != interfaceName
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
///
/// Dùng polling `getifaddrs` (rẻ, không cấp socket) thay vì `NWPathMonitor`:
/// `NWPathMonitor` không cho biết địa chỉ trên interface utun và có thể báo
/// `.satisfied` khi đi qua Wi-Fi trong khi tunnel đã chết.
final class TunnelMonitor: ObservableObject {
    static let shared = TunnelMonitor()

    @Published private(set) var info: NetworkUtils.TunnelInfo
    @Published private(set) var topology: NetworkUtils.Topology
    @Published private(set) var lastChangeDate: Date = Date()

    private var timer: Timer?
    private var running = false
    private let interval: TimeInterval = 3

    private init() {
        let topology = NetworkUtils.captureTopology()
        self.topology = topology
        self.info = NetworkUtils.currentTunnelInfo()
    }

    var isReady: Bool { info.isReady }
    var candidates: [TunnelCandidate] { info.resolution.candidates }

    func start() {
        guard !running else { return }
        running = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    /// Đọc lại topology; phát `wqTunnelDidChange` khi *trạng thái phân giải* đổi
    /// (không chỉ khi interface đổi) để PairingManager biết cần dựng lại listener.
    func refresh() {
        let newTopology = NetworkUtils.captureTopology()
        let newInfo = NetworkUtils.currentTunnelInfo()
        let changed = newInfo.resolution != info.resolution
            || newInfo.matchedInterfaces != info.matchedInterfaces
            || newInfo.addressFoundOutsideTunnel != info.addressFoundOutsideTunnel
            || newTopology.tunnelDetail != topology.tunnelDetail
        topology = newTopology
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
