import Foundation

/// Logic thuần (không phụ thuộc Darwin/Network) cho việc xác định địa chỉ tunnel.
///
/// Tách khỏi phần đọc `getifaddrs` để có thể kiểm thử trên Linux/CI: mọi quyết
/// định "interface nào là LocalDevVPN" đều là hàm thuần trên dữ liệu đầu vào.
///
/// Nguyên tắc:
/// * Không bao giờ coi `127.0.0.1` / `lo0` là tunnel.
/// * Không coi `ipsec*` mang địa chỉ công khai (ví dụ 28.215.155.104) là
///   LocalDevVPN — đó là VPN hệ thống/do app khác tạo.
/// * Chỉ nhận địa chỉ **riêng** (RFC1918 + CGNAT) nằm trên interface
///   point-to-point đang UP + RUNNING.
enum IPv4 {
    /// Parse dotted-quad nghiêm ngặt (không chấp nhận "10.7.0", "10.7.0.1.2", " 10.7.0.1").
    static func parse(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), number >= 0, number <= 255 else { return nil }
            octets.append(UInt8(number))
        }
        return octets
    }

    static func string(_ octets: [UInt8]) -> String {
        octets.map(String.init).joined(separator: ".")
    }

    static func isLoopback(_ octets: [UInt8]) -> Bool {
        octets.count == 4 && octets[0] == 127
    }

    static func isLinkLocal(_ octets: [UInt8]) -> Bool {
        octets.count == 4 && octets[0] == 169 && octets[1] == 254
    }

    /// RFC1918 (10/8, 172.16/12, 192.168/16) + CGNAT 100.64/10.
    /// CGNAT được tính vì nhiều tunnel loopback dùng dải này.
    static func isPrivate(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(Int(octets[1])) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 100, (64...127).contains(Int(octets[1])) { return true }
        return false
    }

    static func isUnspecified(_ octets: [UInt8]) -> Bool {
        octets == [0, 0, 0, 0]
    }

    /// Độ dài prefix từ netmask dạng chuỗi. Netmask không liên tục ⇒ `nil`.
    static func prefixLength(netmask: String?) -> Int? {
        guard let netmask, let octets = parse(netmask) else { return nil }
        var bits = 0
        var seenZero = false
        for byte in octets {
            for shift in stride(from: 7, through: 0, by: -1) {
                let isSet = ((Int(byte) >> shift) & 1) == 1
                if isSet {
                    if seenZero { return nil }   // bit 1 sau bit 0 ⇒ netmask sai
                    bits += 1
                } else {
                    seenZero = true
                }
            }
        }
        return bits
    }

    /// `10.7.1.1/24` nếu có netmask hợp lệ.
    static func cidr(address: String, netmask: String?) -> String? {
        guard parse(address) != nil, let prefix = prefixLength(netmask: netmask) else { return nil }
        return "\(address)/\(prefix)"
    }
}

/// Loại interface dạng tunnel dựa trên tên do kernel đặt.
enum TunnelInterfaceKind: String, CaseIterable {
    case utun
    case ipsec
    case ppp
    case other

    init(name: String) {
        let lower = name.lowercased()
        if lower.hasPrefix("utun") {
            self = .utun
        } else if lower.hasPrefix("ipsec") {
            self = .ipsec
        } else if lower.hasPrefix("ppp") {
            self = .ppp
        } else {
            self = .other
        }
    }

    var isTunnel: Bool { self != .other }

    /// Thứ tự ưu tiên khi có nhiều candidate (utun là dạng mà
    /// `NEPacketTunnelProvider` tạo ra nên đáng tin nhất).
    var priority: Int {
        switch self {
        case .utun: return 0
        case .ppp: return 1
        case .ipsec: return 2
        case .other: return 3
        }
    }
}

enum InterfaceFamily: String {
    case ipv4
    case ipv6
}

/// Một bản ghi địa chỉ của interface (đã chuẩn hoá, không còn con trỏ C).
struct InterfaceSnapshot: Equatable {
    let name: String
    let family: InterfaceFamily
    let address: String
    let netmask: String?
    let peerAddress: String?
    let isUp: Bool
    let isRunning: Bool
    let isPointToPoint: Bool
    let isLoopback: Bool

    init(name: String,
         family: InterfaceFamily = .ipv4,
         address: String,
         netmask: String? = nil,
         peerAddress: String? = nil,
         isUp: Bool = true,
         isRunning: Bool = true,
         isPointToPoint: Bool = false,
         isLoopback: Bool = false) {
        self.name = name
        self.family = family
        self.address = address
        self.netmask = netmask
        self.peerAddress = peerAddress
        self.isUp = isUp
        self.isRunning = isRunning
        self.isPointToPoint = isPointToPoint
        self.isLoopback = isLoopback
    }

    var kind: TunnelInterfaceKind { TunnelInterfaceKind(name: name) }

    /// Địa chỉ có đủ điều kiện làm điểm cuối tunnel hay không.
    /// Trả về lý do loại trừ để chẩn đoán hiển thị được nguyên nhân thật.
    var tunnelRejection: String? {
        guard family == .ipv4 else { return "không phải IPv4" }
        guard kind.isTunnel else { return "không phải interface tunnel" }
        guard !isLoopback else { return "loopback" }
        guard let octets = IPv4.parse(address) else { return "địa chỉ IPv4 không hợp lệ" }
        guard !IPv4.isLoopback(octets) else { return "địa chỉ loopback (127.0.0.0/8)" }
        guard !IPv4.isLinkLocal(octets) else { return "link-local 169.254/16" }
        guard !IPv4.isUnspecified(octets) else { return "0.0.0.0" }
        guard isUp else { return "interface không UP" }
        guard isRunning else { return "interface không RUNNING" }
        // Tunnel thật là point-to-point: có cờ IFF_POINTOPOINT hoặc có peer.
        guard isPointToPoint || peerAddress != nil else {
            return "thiếu cờ point-to-point/peer ⇒ chưa chứng minh là tunnel"
        }
        guard IPv4.isPrivate(octets) else {
            return "\(address) không phải địa chỉ riêng (RFC1918/CGNAT)"
        }
        return nil
    }

    var isTunnelEligible: Bool { tunnelRejection == nil }
}

/// Ứng viên địa chỉ tunnel đã vượt qua mọi kiểm tra.
struct TunnelCandidate: Equatable {
    let interface: String
    let address: String
    let netmask: String?
    let peerAddress: String?
    let kind: TunnelInterfaceKind

    var cidr: String? { IPv4.cidr(address: address, netmask: netmask) }

    var summary: String {
        if let cidr { return "\(cidr) @ \(interface)" }
        return "\(address) @ \(interface)"
    }
}

/// Kết quả phân giải địa chỉ tunnel từ topology thực tế.
enum TunnelResolution: Equatable {
    /// Có địa chỉ đã xác minh và được phép dùng để bind listener.
    /// `isAdopted == true` nghĩa là địa chỉ khác giá trị cấu hình ưu tiên và
    /// người dùng đã xác nhận (không tự đổi IP).
    case active(address: String, interface: String, peerAddress: String?, isAdopted: Bool)
    /// Tunnel tồn tại nhưng không có địa chỉ nào trùng cấu hình; cần người dùng xác nhận.
    case candidateAvailable([TunnelCandidate])
    /// Có interface tunnel nhưng không địa chỉ nào đủ điều kiện (kèm lý do từng cái).
    case noUsableAddress(tunnelInterfaces: [String], rejections: [String])
    /// Không có interface tunnel nào.
    case noTunnelInterface

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var activeAddress: String? {
        if case let .active(address, _, _, _) = self { return address }
        return nil
    }

    var candidates: [TunnelCandidate] {
        if case let .candidateAvailable(list) = self { return list }
        return []
    }
}

/// Cấu hình đầu vào cho bộ phân giải (tách khỏi UserDefaults để test được).
struct TunnelResolutionInput {
    /// Địa chỉ người dùng cấu hình (mặc định 10.7.0.1 nhưng KHÔNG được giả định).
    let configuredAddress: String
    /// Địa chỉ người dùng đã xác nhận sau khi discovery (nếu có).
    let confirmedAddress: String?
    let interfaces: [InterfaceSnapshot]
}

enum TunnelResolver {
    /// Phân giải theo thứ tự: địa chỉ đã xác nhận → địa chỉ cấu hình → ứng viên.
    /// Không bao giờ tự động "đổi IP": kết quả chỉ `active` khi địa chỉ nằm trên tunnel
    /// thật và trùng cấu hình hoặc trùng địa chỉ người dùng đã xác nhận.
    static func resolve(_ input: TunnelResolutionInput) -> TunnelResolution {
        let tunnelInterfaces = input.interfaces.filter { $0.kind.isTunnel }
        guard !tunnelInterfaces.isEmpty else { return .noTunnelInterface }

        let eligible = tunnelInterfaces.filter { $0.isTunnelEligible }
        guard !eligible.isEmpty else {
            let names = Array(Set(tunnelInterfaces.map(\.name))).sorted()
            let reasons = tunnelInterfaces
                .sorted { lhs, rhs in
                    lhs.name == rhs.name ? lhs.address < rhs.address : lhs.name < rhs.name
                }
                .map { "\($0.name)=\($0.address): \($0.tunnelRejection ?? "không rõ")" }
            return .noUsableAddress(tunnelInterfaces: names, rejections: reasons)
        }

        let candidates = eligible
            .map { snapshot in
                TunnelCandidate(interface: snapshot.name,
                                address: snapshot.address,
                                netmask: snapshot.netmask,
                                peerAddress: snapshot.peerAddress,
                                kind: snapshot.kind)
            }
            .sorted(by: preference)

        let preferred = [input.confirmedAddress, input.configuredAddress]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for address in preferred {
            guard IPv4.parse(address) != nil else { continue }
            if let match = candidates.first(where: { $0.address == address }) {
                let adopted = address != input.configuredAddress
                return .active(address: match.address,
                               interface: match.interface,
                               peerAddress: match.peerAddress,
                               isAdopted: adopted)
            }
        }

        return .candidateAvailable(candidates)
    }

    private static func preference(_ lhs: TunnelCandidate, _ rhs: TunnelCandidate) -> Bool {
        if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority < rhs.kind.priority }
        if lhs.interface != rhs.interface { return lhs.interface < rhs.interface }
        return lhs.address < rhs.address
    }
}

