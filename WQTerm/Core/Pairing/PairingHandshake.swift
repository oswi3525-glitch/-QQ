import Foundation
#if canImport(Security)
import Security
#endif

/// Giao thức khung cho pairing handshake: `[UInt32 big-endian length][payload]`.
///
/// Lý do: đọc TCP thô rồi thử parse plist trên toàn bộ buffer (cách cũ) không phân
/// biệt được "một mẩu dữ liệu" với "một message hoàn chỉnh", nên dễ báo thành công
/// khi mới nhận một phần record. Framing cho phép biết chính xác khi nào có đủ message.
///
/// TUYỆT ĐỐI không báo pairing thành công chỉ vì parse được dictionary: handshake
/// phải là trao đổi hai chiều — host gửi `challenge`, thiết bị trả `response` khớp.
enum PairingFrame {
    static let maxPayload = 1 * 1024 * 1024
    static let headerSize = 4

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    /// Kết quả bóc khung. `nil` = chưa đủ dữ liệu (cần đọc tiếp).
    enum DecodeResult: Equatable {
        case complete(message: Data, remainder: Data)
        case invalidLength(UInt32)
    }

    static func decode(_ buffer: Data) -> DecodeResult? {
        guard buffer.count >= headerSize else { return nil }
        let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maxPayload) else { return .invalidLength(length) }
        let total = headerSize + Int(length)
        guard buffer.count >= total else { return nil }
        let start = buffer.index(buffer.startIndex, offsetBy: headerSize)
        let end = buffer.index(start, offsetBy: Int(length))
        let message = Data(buffer[start..<end])
        let remainder = Data(buffer[end...])
        return .complete(message: message, remainder: remainder)
    }
}

/// Nội dung handshake và các trạng thái của nó.
///
/// Luồng bắt buộc:
/// 1. Kết nối TCP ready → host sinh `challenge` ngẫu nhiên 32 byte, gửi đi.
/// 2. Thiết bị gửi khung `hello` chứa deviceName + record.
/// 3. Thiết bị gửi khung `response` = HMAC(key: PairingData, msg: challenge).
/// 4. Host xác minh HMAC → khi đó mới `verified`.
///
/// Nếu thiết bị chỉ gửi record mà không trả response (hoặc ngược lại), trạng thái
/// dừng ở `awaitingResponse` và **không** báo thành công.
enum HandshakeState: String {
    case idle = "IDLE"
    case awaitingHello = "AWAITING_HELLO"
    case awaitingResponse = "AWAITING_RESPONSE"
    case verifying = "VERIFYING"
    case verified = "VERIFIED"
    case rejected = "REJECTED"
    case timedOut = "TIMED_OUT"

    var isTerminal: Bool {
        switch self {
        case .verified, .rejected, .timedOut:
            return true
        default:
            return false
        }
    }
}

/// Một phiên handshake phía host, thuần logic (không giữ socket).
///
/// Host chủ động: sinh `challenge` → gửi đi → chờ `hello` (có record) → chờ
/// `response` (HMAC) → xác minh. Chỉ khi HMAC khớp mới `verified = true`.
struct HandshakeSession {
    let challenge: Data
    private(set) var state: HandshakeState = .awaitingHello
    private(set) var deviceName: String?
    private(set) var record: [String: Any]?
    private(set) var receivedResponse = false
    private(set) var failureReason: String?

    init(challenge: Data) {
        self.challenge = challenge
    }

    /// Sinh challenge ngẫu nhiên 32 byte từ CSPRNG (`SecRandomCopyBytes` trên Darwin,
    /// `SystemRandomNumberGenerator` — vẫn là CSPRNG của hệ điều hành — khi thiếu).
    static func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess { return Data(bytes) }
        #endif
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return Data(bytes)
    }

    /// Message host gửi ngay khi TCP ready: `{"type":"challenge","value":"<base64>"}`.
    func challengeMessage() -> Data {
        let payload: [String: Any] = [
            "type": "challenge",
            "value": challenge.base64EncodedString(),
            "version": 1
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
        return PairingFrame.encode(data)
    }
}

/// Kết quả xử lý một message đến.
enum HandshakeStep {
    /// Cần đọc thêm dữ liệu.
    case continueReading
    /// Đã có đủ `hello`; host cần chờ `response`.
    case awaitingResponse
    /// Handshake hoàn tất và HMAC khớp — đây là bằng chứng duy nhất để báo thành công.
    case verified(deviceName: String, record: [String: Any])
    /// Message sai/không đủ điều kiện.
    case rejected(reason: String)

    /// Nhãn ổn định để test/so sánh (bỏ payload dictionary).
    var label: String {
        switch self {
        case .continueReading: return "continueReading"
        case .awaitingResponse: return "awaitingResponse"
        case .verified: return "verified"
        case .rejected: return "rejected"
        }
    }
}

extension HandshakeSession {
    /// Xử lý một message đã bóc khung. Trả về bước tiếp theo.
    /// Không bao giờ trả `.verified` nếu chưa nhận `hello` + `response` khớp HMAC.
    mutating func handle(message: Data) -> HandshakeStep {
        guard !state.isTerminal else { return .rejected(reason: "Phiên đã kết thúc (\(state.rawValue))") }

        guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              let type = object["type"] as? String else {
            state = .rejected
            failureReason = "Message không phải JSON object có 'type'"
            return .rejected(reason: failureReason!)
        }

        switch type {
        case "hello":
            return handleHello(object)
        case "response":
            return handleResponse(object)
        default:
            state = .rejected
            failureReason = "Loại message không hỗ trợ: \(type)"
            return .rejected(reason: failureReason!)
        }
    }

    private mutating func handleHello(_ object: [String: Any]) -> HandshakeStep {
        guard state == .awaitingHello else {
            state = .rejected
            failureReason = "hello gửi sai thứ tự (state=\(state.rawValue))"
            return .rejected(reason: failureReason!)
        }
        guard let rawRecord = object["record"] as? [String: Any],
              Self.isUsableRecord(rawRecord) else {
            state = .rejected
            failureReason = "hello thiếu PairingData hoặc định danh thiết bị"
            return .rejected(reason: failureReason!)
        }
        let name = (object["deviceName"] as? String)
            ?? (rawRecord["DeviceName"] as? String)
            ?? (rawRecord["Name"] as? String)
            ?? "iPhone"

        deviceName = name
        record = rawRecord
        state = .awaitingResponse
        return .awaitingResponse
    }

    private mutating func handleResponse(_ object: [String: Any]) -> HandshakeStep {
        guard state == .awaitingResponse, let record else {
            state = .rejected
            failureReason = "response đến trước hello (state=\(state.rawValue))"
            return .rejected(reason: failureReason!)
        }
        guard let encoded = object["hmac"] as? String,
              let provided = Data(base64Encoded: encoded) else {
            state = .rejected
            failureReason = "response không có 'hmac' base64"
            return .rejected(reason: failureReason!)
        }
        receivedResponse = true

        guard let key = Self.handshakeKey(from: record) else {
            state = .rejected
            failureReason = "PairingData không dùng được làm khoá HMAC"
            return .rejected(reason: failureReason!)
        }
        let expected = SHA256.hmac(key: key, message: challenge)
        guard Self.constantTimeEquals(expected, provided) else {
            state = .rejected
            failureReason = "HMAC không khớp challenge"
            return .rejected(reason: failureReason!)
        }
        state = .verified
        return .verified(deviceName: deviceName ?? "iPhone", record: record)
    }

    /// Record phải có PairingData không rỗng + ít nhất một định danh.
    static func isUsableRecord(_ record: [String: Any]) -> Bool {
        let pairingData: Data?
        if let data = record["PairingData"] as? Data {
            pairingData = data
        } else if let string = record["PairingData"] as? String, !string.isEmpty {
            pairingData = Data(base64Encoded: string) ?? Data(string.utf8)
        } else {
            pairingData = nil
        }
        guard let pairingData, !pairingData.isEmpty else { return false }
        let identityKeys = ["AltIRK", "DeviceUDID", "UDID"]
        return identityKeys.contains { key in
            if let value = record[key] as? String {
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let value = record[key] as? Data { return !value.isEmpty }
            return false
        }
    }

    static func handshakeKey(from record: [String: Any]) -> Data? {
        if let data = record["PairingData"] as? Data, !data.isEmpty { return data }
        if let string = record["PairingData"] as? String, !string.isEmpty {
            if let decoded = Data(base64Encoded: string), !decoded.isEmpty { return decoded }
            return Data(string.utf8)
        }
        return nil
    }

    /// So sánh không rò rỉ thời gian.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
