import XCTest
@testable import PairingCore

/// Kiểm thử bộ phân giải địa chỉ tunnel — trọng tâm của Phase 1.
///
/// Bối cảnh lỗi thực tế (từ chẩn đoán):
///   ipsec4 = 28.215.155.104
///   ipsec5 = 28.215.155.104
///   utun4  = 10.7.1.1
///   (không có 10.7.0.1)
/// Trước đây app coi "10.7.0.1 trên utun*" là điều kiện duy nhất ⇒ luôn false.
final class TunnelResolverTests: XCTestCase {

    // MARK: - IPv4 primitive

    func testIPv4ParsingRejectsMalformedInput() {
        XCTAssertNil(IPv4.parse("10.7.0"))
        XCTAssertNil(IPv4.parse("10.7.0.1.2"))
        XCTAssertNil(IPv4.parse("10.7.0.256"))
        XCTAssertNil(IPv4.parse("10.7..1"))
        XCTAssertNil(IPv4.parse(""))
        XCTAssertNil(IPv4.parse("a.b.c.d"))
        XCTAssertNotNil(IPv4.parse("10.7.1.1"))
        XCTAssertNotNil(IPv4.parse("0.0.0.0"))
    }

    func testPrivateRanges() {
        XCTAssertTrue(IPv4.isPrivate(IPv4.parse("10.7.1.1")!))
        XCTAssertTrue(IPv4.isPrivate(IPv4.parse("172.20.0.1")!))
        XCTAssertTrue(IPv4.isPrivate(IPv4.parse("192.168.1.5")!))
        XCTAssertTrue(IPv4.isPrivate(IPv4.parse("100.100.1.1")!))
        XCTAssertFalse(IPv4.isPrivate(IPv4.parse("28.215.155.104")!))
        XCTAssertFalse(IPv4.isPrivate(IPv4.parse("8.8.8.8")!))
        XCTAssertFalse(IPv4.isPrivate(IPv4.parse("172.32.0.1")!))
    }

    func testPrefixLengthFromNetmask() {
        XCTAssertEqual(IPv4.prefixLength(netmask: "255.255.255.0"), 24)
        XCTAssertEqual(IPv4.prefixLength(netmask: "255.255.0.0"), 16)
        XCTAssertEqual(IPv4.prefixLength(netmask: "255.255.255.255"), 32)
        XCTAssertNil(IPv4.prefixLength(netmask: "255.0.255.0"), "netmask không liên tục phải bị từ chối")
        XCTAssertNil(IPv4.prefixLength(netmask: nil))
        XCTAssertEqual(IPv4.cidr(address: "10.7.1.1", netmask: "255.255.255.0"), "10.7.1.1/24")
    }

    // MARK: - Rejections (dữ liệu đúng như máy thật báo cáo)

    /// `ipsec*` mang địa chỉ công khai KHÔNG phải LocalDevVPN.
    func testIPSecPublicAddressIsRejected() {
        let snapshot = InterfaceSnapshot(name: "ipsec4", address: "28.215.155.104",
                                        netmask: "255.255.255.255",
                                        isPointToPoint: true)
        XCTAssertFalse(snapshot.isTunnelEligible)
        XCTAssertEqual(snapshot.tunnelRejection,
                       "28.215.155.104 không phải địa chỉ riêng (RFC1918/CGNAT)")
    }

    func testLoopbackIsNeverTunnel() {
        let lo = InterfaceSnapshot(name: "lo0", address: "127.0.0.1",
                                   netmask: "255.0.0.0", isLoopback: true)
        XCTAssertFalse(lo.isTunnelEligible)

        // Cả khi tên giả là utun nhưng địa chỉ loopback ⇒ vẫn từ chối.
        let fakeTunnel = InterfaceSnapshot(name: "utun9", address: "127.0.0.1",
                                           isPointToPoint: true)
        XCTAssertFalse(fakeTunnel.isTunnelEligible)
        XCTAssertEqual(fakeTunnel.tunnelRejection, "địa chỉ loopback (127.0.0.0/8)")
    }

    /// utun không có cờ point-to-point và không có peer ⇒ chưa chứng minh là tunnel.
    func testUtunWithoutPointToPointIsRejected() {
        let snapshot = InterfaceSnapshot(name: "utun4", address: "10.7.1.1",
                                        netmask: "255.255.255.0", isPointToPoint: false)
        XCTAssertEqual(snapshot.tunnelRejection,
                       "thiếu cờ point-to-point/peer ⇒ chưa chứng minh là tunnel")
    }

    func testInterfaceDownOrNotRunningIsRejected() {
        let down = InterfaceSnapshot(name: "utun4", address: "10.7.1.1",
                                     isUp: false, isPointToPoint: true)
        XCTAssertEqual(down.tunnelRejection, "interface không UP")

        let notRunning = InterfaceSnapshot(name: "utun4", address: "10.7.1.1",
                                           isRunning: false, isPointToPoint: true)
        XCTAssertEqual(notRunning.tunnelRejection, "interface không RUNNING")
    }

    func testLinkLocalAndUnspecifiedRejected() {
        let linkLocal = InterfaceSnapshot(name: "utun4", address: "169.254.10.20",
                                          isPointToPoint: true)
        XCTAssertEqual(linkLocal.tunnelRejection, "link-local 169.254/16")

        let zero = InterfaceSnapshot(name: "utun4", address: "0.0.0.0", isPointToPoint: true)
        XCTAssertEqual(zero.tunnelRejection, "0.0.0.0")
    }

    // MARK: - Resolver behaviour

    /// Topology thật của máy bị lỗi: không có 10.7.0.1 → candidateAvailable, KHÔNG tự active.
    func testRealWorldTopologyProducesCandidateNotAutoAdoption() {
        let interfaces = [
            InterfaceSnapshot(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0",
                              isLoopback: true),
            InterfaceSnapshot(name: "en0", address: "192.168.1.23", netmask: "255.255.255.0"),
            InterfaceSnapshot(name: "ipsec4", address: "28.215.155.104",
                              netmask: "255.255.255.255", isPointToPoint: true),
            InterfaceSnapshot(name: "ipsec5", address: "28.215.155.104",
                              netmask: "255.255.255.255", isPointToPoint: true),
            InterfaceSnapshot(name: "utun4", address: "10.7.1.1", netmask: "255.255.255.0",
                              peerAddress: "10.7.1.2", isPointToPoint: true)
        ]
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.7.0.1",
                                  confirmedAddress: nil,
                                  interfaces: interfaces)
        )

        guard case let .candidateAvailable(candidates) = resolution else {
            return XCTFail("Phải là candidateAvailable, nhận \(resolution)")
        }
        XCTAssertEqual(candidates.count, 1, "chỉ utun4 đủ điều kiện; ipsec công khai bị loại")
        XCTAssertEqual(candidates[0].address, "10.7.1.1")
        XCTAssertEqual(candidates[0].interface, "utun4")
        XCTAssertEqual(candidates[0].peerAddress, "10.7.1.2")
        XCTAssertFalse(resolution.isActive, "không được tự coi 10.7.1.1 là active")
    }

    /// Chỉ khi người dùng xác nhận thì 10.7.1.1 mới thành active (isAdopted = true).
    func testConfirmedAddressBecomesActiveButFlaggedAsAdopted() {
        let interfaces = [
            InterfaceSnapshot(name: "utun4", address: "10.7.1.1", netmask: "255.255.255.0",
                              peerAddress: "10.7.1.2", isPointToPoint: true)
        ]
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.7.0.1",
                                  confirmedAddress: "10.7.1.1",
                                  interfaces: interfaces)
        )
        guard case let .active(address, interface, peer, adopted) = resolution else {
            return XCTFail("Phải active sau khi xác nhận, nhận \(resolution)")
        }
        XCTAssertEqual(address, "10.7.1.1")
        XCTAssertEqual(interface, "utun4")
        XCTAssertEqual(peer, "10.7.1.2")
        XCTAssertTrue(adopted, "phải đánh dấu là đã chấp nhận địa chỉ khác cấu hình")
    }

    /// Khi cấu hình đúng (10.7.0.1 có thật trên tunnel) thì active ngay, không cần xác nhận.
    func testMatchingConfiguredAddressIsActiveImmediately() {
        let interfaces = [
            InterfaceSnapshot(name: "utun4", address: "10.7.0.1", netmask: "255.255.255.0",
                              isPointToPoint: true)
        ]
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.7.0.1",
                                  confirmedAddress: nil,
                                  interfaces: interfaces)
        )
        XCTAssertTrue(resolution.isActive)
        XCTAssertEqual(resolution.activeAddress, "10.7.0.1")
        guard case let .active(_, _, _, adopted) = resolution else { return XCTFail() }
        XCTAssertFalse(adopted)
    }

    /// Địa chỉ cấu hình nằm trên interface thường (lo0/en0) không được tính.
    func testConfiguredAddressOnNonTunnelIsNotActive() {
        let interfaces = [
            InterfaceSnapshot(name: "en0", address: "10.7.0.1", netmask: "255.255.255.0"),
            InterfaceSnapshot(name: "lo0", address: "127.0.0.1", isLoopback: true)
        ]
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.7.0.1",
                                  confirmedAddress: nil,
                                  interfaces: interfaces)
        )
        XCTAssertEqual(resolution, .noTunnelInterface)
        XCTAssertFalse(resolution.isActive)
    }

    func testNoTunnelInterfaceCase() {
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.7.0.1", confirmedAddress: nil,
                                  interfaces: [
                                    InterfaceSnapshot(name: "en0", address: "192.168.1.2",
                                                      netmask: "255.255.255.0")
                                  ])
        )
        XCTAssertEqual(resolution, .noTunnelInterface)
    }

    /// Tunnel tồn tại nhưng mọi địa chỉ đều bị loại ⇒ báo lý do từng cái.
    func testNoUsableAddressReportsPerInterfaceReasons() {
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.7.0.1", confirmedAddress: nil,
                                  interfaces: [
                                    InterfaceSnapshot(name: "ipsec4", address: "28.215.155.104",
                                                      isPointToPoint: true),
                                    InterfaceSnapshot(name: "utun4", address: "10.7.1.1",
                                                      isPointToPoint: false)
                                  ])
        )
        guard case let .noUsableAddress(names, rejections) = resolution else {
            return XCTFail("Phải noUsableAddress, nhận \(resolution)")
        }
        XCTAssertEqual(names, ["ipsec4", "utun4"])
        XCTAssertEqual(rejections.count, 2)
        XCTAssertTrue(rejections.contains { $0.contains("không phải địa chỉ riêng") })
        XCTAssertTrue(rejections.contains { $0.contains("point-to-point") })
    }

    /// utun được ưu tiên hơn ppp/ipsec khi nhiều candidate hợp lệ.
    func testUtunPreferredOverOtherTunnelKinds() {
        let resolution = TunnelResolver.resolve(
            TunnelResolutionInput(configuredAddress: "10.9.9.9", confirmedAddress: nil,
                                  interfaces: [
                                    InterfaceSnapshot(name: "ppp0", address: "10.8.0.2",
                                                      peerAddress: "10.8.0.1", isPointToPoint: true),
                                    InterfaceSnapshot(name: "utun2", address: "10.7.0.7",
                                                      peerAddress: "10.7.0.6", isPointToPoint: true)
                                  ])
        )
        XCTAssertEqual(resolution.candidates.first?.interface, "utun2")
    }
}
