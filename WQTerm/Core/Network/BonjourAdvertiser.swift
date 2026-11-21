import Foundation
import Network
import Combine

/// Quảng bá Bonjour cho Pairing Host — **chỉ sau khi TCP listener thật sự ready**.
///
/// Lỗi gốc trước đây: service được gán vào `NWListener.service` ngay cả khi
/// listener còn `.waiting`, và nếu tunnel không hợp lệ thì listener không bao giờ
/// `.ready` ⇒ không có quảng bá, và UI vẫn hiển thị "chưa gọi startHost()".
///
/// Thiết kế hiện tại:
/// * `publish(port:)` **bắt buộc** nhận port từ listener đã `.ready` (không đoán).
/// * `unpublish()` luôn được gọi khi listener dừng/khởi động lại.
/// * `browse()` kiểm tra discovery thật (không giả định multicast đi xuyên VPN).
final class BonjourAdvertiser: ObservableObject {
    static let shared = BonjourAdvertiser()

    /// Service type theo chuẩn remotepairing của Apple.
    static let serviceType = "_remotepairing-pairable-host._tcp"
    /// Service type dùng để discovery đối tác (host companion).
    static let discoveryServiceType = "_remotepairing._tcp"

    @Published private(set) var isPublished = false
    @Published private(set) var publishedName: String?
    @Published private(set) var publishedPort: UInt16?
    @Published private(set) var lastFailure: ListenerFailure?
    @Published private(set) var lastDiscoveredCount = 0

    private let queue = DispatchQueue(label: "com.wqterm.bonjour", qos: .userInitiated)
    private var serviceName: String

    private init() {
        // Tên duy nhất theo host identifier để hai thiết bị không đè tên nhau.
        let suffix = (UserDefaults(suiteName: "group.com.wqterm.app")?
            .string(forKey: "WQTerm.Pairing.HostIdentifier") ?? UUID().uuidString)
            .prefix(6)
        self.serviceName = "WQTerm-\(suffix)"
    }

    var type: String { Self.serviceType }

    /// Dựng bản ghi TXT.
    ///
    /// CẢNH BÁO: `authTag` là `AltIRK` base64 và **được quảng bá công khai** qua
    /// multicast Bonjour (bất kỳ ai trên cùng L2 đều đọc được). Đây là hành vi của
    /// bản cũ nên được giữ để không phá vỡ luồng pairing đang chạy, nhưng nó làm
    /// giảm tính bí mật của IRK. Không thêm bất kỳ trường bí mật nào khác vào đây;
    /// handshake HMAC thật sự dùng `PairingData` (không bao giờ được quảng bá).
    static func makeTXTRecord(name: String,
                              identifier: String,
                              authTag: String,
                              model: String = "iPhone") -> Data {
        let entries: [String: String] = [
            "identifier": identifier,
            "authTag": authTag,
            "model": model,
            "name": name,
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ]
        var data = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let bytes = Array("\(key)=\(value)".utf8)
            guard bytes.count <= 255 else { continue }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    /// Gắn service vào listener đã `.ready`. Trả về `false` nếu listener chưa sẵn sàng
    /// hoặc port không hợp lệ — không bao giờ quảng bá khi chưa có listener thật.
    @discardableResult
    func attach(to listener: NWListener,
                port: UInt16,
                identifier: String,
                authTag: String) -> Bool {
        // `NWListener.State` không phải `Equatable` ⇒ phải pattern-match.
        var isReady = false
        if case .ready = listener.state { isReady = true }
        guard isReady, port > 0 else {
            queue.async { [self] in
                publishFailure(ListenerFailure(
                    code: .bonjourFailed,
                    message: "Không thể quảng bá: listener chưa ready hoặc port = 0",
                    recovery: "Chờ listener đạt LISTENING rồi mới quảng bá Bonjour."
                ))
            }
            return false
        }

        let txt = Self.makeTXTRecord(name: serviceName, identifier: identifier, authTag: authTag)
        listener.service = NWListener.Service(name: serviceName,
                                              type: Self.serviceType,
                                              txtRecord: txt)
        let published = serviceName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPublished = true
            self.publishedName = published
            self.publishedPort = port
            self.lastFailure = nil
        }
        PairingLogger.shared.log(.info, stage: "BONJOUR",
                                 "Đã gắn service \(Self.serviceType)",
                                 detail: "name=\(serviceName) port=\(port)")
        return true
    }

    /// Ngừng quảng bá. Gọi khi listener dừng/khởi động lại.
    func detach(from listener: NWListener?) {
        listener?.service = nil
        DispatchQueue.main.async { [weak self] in
            self?.isPublished = false
            self?.publishedName = nil
            self?.publishedPort = nil
        }
        PairingLogger.shared.log(.info, stage: "BONJOUR", "Đã ngừng quảng bá service")
    }

    /// Discovery thật sự: browse và trả về danh sách endpoint thấy được trong `timeout`.
    /// Không giả định multicast đi xuyên VPN — kết quả rỗng là thông tin thật.
    func browse(timeout: TimeInterval = 2.5,
                type: String? = nil) async -> [NWEndpoint] {
        let serviceType = type ?? Self.serviceType
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil),
                               using: parameters)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var found: [NWEndpoint] = []

            let finish: () -> Void = {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let results = found
                lock.unlock()
                browser.cancel()
                continuation.resume(returning: results)
            }

            browser.browseResultsChangedHandler = { results, _ in
                lock.lock()
                found = results.map(\.endpoint)
                let empty = found.isEmpty
                lock.unlock()
                if !empty { finish() }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed:
                    finish()
                case .cancelled:
                    finish()
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    /// Kiểm tra discovery + cập nhật trạng thái quan sát được.
    /// Dùng cho bước 6 của chẩn đoán.
    func verifyDiscovery(timeout: TimeInterval = 2.5) async -> (count: Int, endpoints: [NWEndpoint]) {
        let endpoints = await browse(timeout: timeout)
        DispatchQueue.main.async { [weak self] in
            self?.lastDiscoveredCount = endpoints.count
        }
        PairingLogger.shared.log(endpoints.isEmpty ? .warn : .info, stage: "BONJOUR",
                                 "Discovery \(Self.serviceType): \(endpoints.count) kết quả",
                                 detail: endpoints.map { "\($0)" }.joined(separator: ", "))
        return (endpoints.count, endpoints)
    }

    private func publishFailure(_ failure: ListenerFailure) {
        DispatchQueue.main.async { [weak self] in
            self?.lastFailure = failure
        }
    }
}
