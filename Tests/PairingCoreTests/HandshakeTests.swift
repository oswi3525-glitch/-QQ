import XCTest
@testable import PairingCore

/// Kiểm thử handshake: chỉ VERIFIED khi có hello + HMAC response khớp challenge.
final class HandshakeTests: XCTestCase {

    private let pairingData = Data("0123456789abcdef0123456789abcdef".utf8)

    private func record() -> [String: Any] {
        // JSON không mã hoá được `Data` thô ⇒ dùng base64 như một thiết bị thật sẽ gửi.
        // `HandshakeSession.handshakeKey` chấp nhận cả base64 string và Data.
        ["PairingData": pairingData.base64EncodedString(),
         "AltIRK": "AAAABBBBCCCCDDDD",
         "DeviceName": "iPhone Test"]
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func helloMessage() -> Data {
        json(["type": "hello", "deviceName": "iPhone Test", "record": record()])
    }

    private func responseMessage(challenge: Data, key: Data? = nil) -> Data {
        let mac = SHA256.hmac(key: key ?? pairingData, message: challenge)
        return json(["type": "response", "hmac": mac.base64EncodedString()])
    }

    // MARK: - Framing

    func testFrameRoundTrip() {
        let payload = Data("hello world".utf8)
        let framed = PairingFrame.encode(payload)
        guard case let .complete(message, remainder)? = PairingFrame.decode(framed) else {
            return XCTFail("phải bóc được khung")
        }
        XCTAssertEqual(message, payload)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testFrameKeepsRemainderForNextMessage() {
        let first = PairingFrame.encode(Data("one".utf8))
        let second = PairingFrame.encode(Data("two".utf8))
        guard case let .complete(message, remainder)? = PairingFrame.decode(first + second) else {
            return XCTFail()
        }
        XCTAssertEqual(message, Data("one".utf8))
        guard case let .complete(secondMessage, _)? = PairingFrame.decode(remainder) else {
            return XCTFail("phần dư phải bóc tiếp được")
        }
        XCTAssertEqual(secondMessage, Data("two".utf8))
    }

    /// Dữ liệu chưa đủ ⇒ nil (không được đoán là hoàn chỉnh).
    func testPartialFrameReturnsNil() {
        let framed = PairingFrame.encode(Data("incomplete".utf8))
        XCTAssertNil(PairingFrame.decode(framed.prefix(3)))
        XCTAssertNil(PairingFrame.decode(framed.prefix(framed.count - 1)))
    }

    func testOversizedLengthIsRejected() {
        var header = Data([0xFF, 0xFF, 0xFF, 0xFF])
        header.append(Data(repeating: 0, count: 8))
        guard case let .invalidLength(length)? = PairingFrame.decode(header) else {
            return XCTFail("phải báo invalidLength")
        }
        XCTAssertEqual(length, 0xFFFF_FFFF)
    }

    // MARK: - Handshake ordering

    func testResponseBeforeHelloIsRejected() {
        var session = HandshakeSession(challenge: Data(repeating: 7, count: 32))
        let step = session.handle(message: responseMessage(challenge: session.challenge))
        XCTAssertEqual(step.label, "rejected")
        XCTAssertEqual(session.state, .rejected)
    }

    func testHelloWithoutPairingDataIsRejected() {
        var session = HandshakeSession(challenge: Data(repeating: 7, count: 32))
        let bad = json(["type": "hello", "deviceName": "X",
                        "record": ["DeviceName": "X"]])
        XCTAssertEqual(session.handle(message: bad).label, "rejected")
        XCTAssertEqual(session.state, .rejected)
    }

    // MARK: - Positive path

    func testVerifiedOnlyAfterHelloAndMatchingHMAC() {
        var session = HandshakeSession(challenge: Data(repeating: 7, count: 32))
        XCTAssertEqual(session.state, .awaitingHello)

        let helloStep = session.handle(message: helloMessage())
        XCTAssertEqual(helloStep.label, "awaitingResponse")
        XCTAssertEqual(session.state, .awaitingResponse)
        XCTAssertEqual(session.deviceName, "iPhone Test")

        let responseStep = session.handle(message: responseMessage(challenge: session.challenge))
        guard case let .verified(name, record) = responseStep else {
            return XCTFail("HMAC đúng phải verified, nhận \(responseStep.label)")
        }
        XCTAssertEqual(name, "iPhone Test")
        XCTAssertNotNil(record["PairingData"])
        XCTAssertEqual(session.state, .verified)
    }

    func testWrongHMACIsRejected() {
        var session = HandshakeSession(challenge: Data(repeating: 7, count: 32))
        _ = session.handle(message: helloMessage())
        let wrongKey = Data("ffffffffffffffffffffffffffffffff".utf8)
        let step = session.handle(message: responseMessage(challenge: session.challenge,
                                                          key: wrongKey))
        XCTAssertEqual(step.label, "rejected")
        XCTAssertEqual(session.state, .rejected)
    }

    /// HMAC của challenge khác cũng phải bị từ chối (chống replay).
    func testHMACForDifferentChallengeIsRejected() {
        var session = HandshakeSession(challenge: Data(repeating: 7, count: 32))
        _ = session.handle(message: helloMessage())
        let otherChallenge = Data(repeating: 9, count: 32)
        let step = session.handle(message: responseMessage(challenge: otherChallenge))
        XCTAssertEqual(step.label, "rejected")
    }

    /// Sau khi đã verified không được nhận thêm message (chống tái sử dụng phiên).
    func testSessionIsTerminalAfterVerified() {
        var session = HandshakeSession(challenge: Data(repeating: 1, count: 32))
        _ = session.handle(message: helloMessage())
        _ = session.handle(message: responseMessage(challenge: session.challenge))
        XCTAssertEqual(session.state, .verified)
        XCTAssertEqual(session.handle(message: helloMessage()).label, "rejected")
    }

    func testChallengeMessageIsFramedJSON() {
        let session = HandshakeSession(challenge: Data(repeating: 3, count: 32))
        let framed = session.challengeMessage()
        guard case let .complete(message, _)? = PairingFrame.decode(framed) else {
            return XCTFail("challenge phải có framing")
        }
        let object = try! JSONSerialization.jsonObject(with: message) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "challenge")
        XCTAssertEqual(Data(base64Encoded: object?["value"] as? String ?? ""), session.challenge)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(HandshakeSession.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(HandshakeSession.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(HandshakeSession.constantTimeEquals(Data([1, 2]), Data([1, 2, 3])))
    }

    // MARK: - SHA-256 / HMAC vectors

    func testSHA256KnownVectors() {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA256.hash(Data("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256.hash(Data())),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hmac(key: Data("key".utf8),
                                       message: Data("The quick brown fox jumps over the lazy dog".utf8))),
                       "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }
}
