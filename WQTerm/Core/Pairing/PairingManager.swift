import Foundation
import Network
import Security
import Combine
import UserNotifications

/// Pairing (PRD Module 8.1) — iOS 27 device-initiated remote pairing.
///
/// iOS 27 cho phép thiết bị tự tìm một "pairable host" trên mạng nội bộ qua
/// Bonjour (`_remotepairing-pairable-host._tcp`). WQTerm đóng vai trò host:
/// 1. Quảng bá service bằng `NWListener` + TXT record.
/// 2. Sinh mã PIN 6 chữ số và hiển thị để người dùng nhập trên iPhone
///    (Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Ghép nối).
/// 3. Khi nhận được pairing record từ thiết bị (hoặc người dùng xác nhận đã
///    nhập mã), lưu file `mobiledevicepairing` vào `Documents/`.
///
/// Lưu ý kỹ thuật: handshake SRP-3072/OPACK đầy đủ nằm trong thư viện FFI
/// (idevice/StikPair). Lớp này giữ đúng ranh giới giao thức: mọi dữ liệu
/// pairing nhận được đều đi qua `parsePairingRecord` → `completePairing`.
/// Khi tích hợp FFI, chỉ cần thay phần đọc socket bằng lời gọi `accept`.
final class PairingManager: ObservableObject {
    static let shared = PairingManager()

    /// Bonjour service type dùng cho iOS 27 device-initiated pairing.
    static let serviceType = "_remotepairing-pairable-host._tcp"
    /// Tên hiển thị trên thiết bị iOS.
    static let serviceName = "WQTerm"

    @Published private(set) var isPaired: Bool
    @Published private(set) var pairingCode: String
    @Published private(set) var isAdvertising = false
    @Published private(set) var isDeviceConnected = false
    @Published private(set) var advertisedPort: UInt16?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var pairingFileURL: URL?

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let pairedKey = "WQTerm.Pairing.IsPaired"
    private let deviceNameKey = "WQTerm.Pairing.DeviceName"
    private let identifierKey = "WQTerm.Pairing.HostIdentifier"
    private let altIRKKey = "WQTerm.Pairing.AltIRK"

    private let queue = DispatchQueue(label: "com.wqterm.pairing", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let fileExists = FileManager.default.fileExists(atPath: file.path)
        self.isPaired = defaults.bool(forKey: pairedKey) || fileExists
        self.pairingCode = Self.generateCode()
        self.deviceName = defaults.string(forKey: deviceNameKey)
        self.pairingFileURL = fileExists ? file : nil
        ensureHostIdentity()
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
        connections.forEach { $0.cancel() }
    }

    // MARK: - Public state

    /// `true` nếu iOS hiện tại hỗ trợ pairing kiểu iOS 27.
    static var supportsDeviceInitiatedPairing: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// Hướng dẫn 3 bước theo luồng pairing iOS 27 (dùng cho cả Onboarding).
    static let steps: [(title: String, detail: String)] = [
        ("Bật LocalDevVPN",
         "Bật LocalDevVPN để tạo tunnel loopback 10.7.0.1. Nếu chưa bật, màn hình nhập mã PIN sẽ không xuất hiện."),
        ("Mở Chế độ nhà phát triển",
         "Vào Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Ghép nối với WQTerm."),
        ("Nhập mã PIN 6 số",
         "Mã hiển thị trên Dynamic Island hoặc thanh thông báo. Nhập mã đó trên iPhone để hoàn tất ghép nối.")
    ]

    /// Tạo mã hiển thị cho người dùng nhập trên thiết bị iOS.
    static func generateCode() -> String {
        (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// Tạo mã mới (dùng khi mã cũ đã hết hạn).
    func refreshCode() {
        pairingCode = Self.generateCode()
        statusMessage = isAdvertising
            ? "Mã mới: \(pairingCode). Mã hiện trên Dynamic Island/thông báo."
            : statusMessage
        postPINNotification()
    }

    // MARK: - Điều kiện tiên quyết (LocalDevVPN)

    /// `true` nếu LocalDevVPN đang bật — điều kiện bắt buộc để hiện màn hình PIN.
    var isLocalDevVPNActive: Bool { NetworkUtils.isLocalDevVPNActive }

    /// Thông tin tunnel hiển thị trên UI.
    var tunnelSummary: String { NetworkUtils.currentTunnelInfo().summary }

    /// Cảnh báo hiển thị khi VPN chưa bật.
    static let vpnWarning = "Vui lòng bật LocalDevVPN trước khi ghép nối"

    /// Entry point duy nhất được nút "Ghép nối" gọi.
    ///
    /// Trả về `false` kèm `lastError` nếu LocalDevVPN chưa bật — UI không được
    /// chuyển sang màn hình nhập PIN trong trường hợp này.
    @discardableResult
    func beginPairing() -> Bool {
        guard isLocalDevVPNActive else {
            lastError = Self.vpnWarning
            statusMessage = nil
            AuditLogger.shared.log(event: .worseQueryExtensionFailed(bundleID: "LocalDevVPN"))
            return false
        }
        lastError = nil
        requestLocalNetworkPermission()
        startHost()
        postPINNotification()
        return true
    }

    /// Đưa mã PIN lên thanh thông báo (Dynamic Island cần widget extension riêng).
    func postPINNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "WQTerm — mã ghép nối"
            content.body = "Mã PIN 6 số: \(self.pairingCode). Nhập trong Cài đặt › Chế độ nhà phát triển."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "WQTerm.Pairing.PIN",
                                                content: content, trigger: nil)
            center.add(request) { _ in
                DispatchQueue.main.async {
                    self.statusMessage = "Mã \(self.pairingCode) đã được gửi tới thanh thông báo."
                }
            }
        }
    }

    /// Đặt lại mọi trạng thái "treo" sau khi nhập mật khẩu khóa máy.
    func forceReset() {
        stopHost()
        lastError = nil
        statusMessage = "Đã đặt lại luồng ghép nối. Bấm \"Bắt đầu ghép nối\" để thử lại."
        pairingCode = Self.generateCode()
    }

    // MARK: - Host lifecycle

    /// Bắt đầu quảng bá dịch vụ pairing và sinh PIN mới.
    func startHost() {
        guard !isAdvertising else { return }
        // Dọn listener cũ (có thể còn sống sau lần trước bị ngắt bởi mật khẩu khóa máy).
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        lastError = nil
        isDeviceConnected = false
        pairingCode = Self.generateCode()
        ensureHostIdentity()

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            let txt = makeTXTRecord()
            listener.service = NWListener.Service(name: Self.serviceName,
                                                  type: Self.serviceType,
                                                  txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isAdvertising = true
                        self.advertisedPort = listener.port?.rawValue
                        self.statusMessage = "Đang quảng bá \(Self.serviceName). Mã \(self.pairingCode) "
                            + "hiện trên Dynamic Island/thông báo — nhập trong Cài đặt › Chế độ nhà phát triển."
                    case .failed(let error):
                        self.isAdvertising = false
                        self.advertisedPort = nil
                        self.listener = nil
                        self.lastError = "Không mở được pairing host: \(error.localizedDescription)"
                        self.statusMessage = nil
                    case .cancelled:
                        self.isAdvertising = false
                        self.advertisedPort = nil
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
            statusMessage = "Đang khởi động pairing host…"
            // Chạm vào NWBrowser để iOS hiện prompt quyền Mạng nội bộ.
            requestLocalNetworkPermission()
            scheduleWatchdog()
        } catch {
            lastError = "Không tạo được NWListener: \(error.localizedDescription)"
        }
    }

    /// Dừng quảng bá và đóng mọi kết nối đang mở.
    func stopHost() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        receiveBuffers.removeAll()
        isAdvertising = false
        isDeviceConnected = false
        advertisedPort = nil
        if statusMessage != nil, !isPaired {
            statusMessage = nil
        }
    }

    /// Chủ động kích hoạt prompt quyền Mạng nội bộ (iOS không có API đọc trực tiếp).
    func requestLocalNetworkPermission() {
        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                DispatchQueue.main.async {
                    self.lastError = "Không duyệt được Bonjour: \(error.localizedDescription)"
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser

        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.browser = nil
        }
    }

    /// Nếu sau 30 giây vẫn không có thiết bị kết nối, đưa ra hướng dẫn cụ thể
    /// thay vì để UI đứng im ở trạng thái "Đang khởi động…".
    private func scheduleWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.isAdvertising,
                  !self.isDeviceConnected, !self.isPaired else { return }
            self.statusMessage = "Chưa thấy thiết bị. Kiểm tra LocalDevVPN, "
                + "Developer Mode và quyền Mạng nội bộ rồi thử lại. "
                + "Mã PIN: \(self.pairingCode)"
        }
    }

    // MARK: - Pairing completion

    /// Đánh dấu đã ghép nối và lưu pairing file (dùng khi người dùng xác nhận
    /// đã nhập đúng PIN, hoặc khi FFI báo handshake thành công).
    func markPaired() {
        completePairing(deviceName: deviceName ?? "iPhone",
                        record: [:])
    }

    /// Xử lý sự kiện pairing thành công: lưu `mobiledevicepairing` vào Documents/.
    ///
    /// - Parameters:
    ///   - deviceName: tên thiết bị nhận được từ pairing record.
    ///   - record: dictionary pairing (AltIRK, DeviceUDID, PairingData…).
    @discardableResult
    func completePairing(deviceName: String, record: [String: Any]) -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let primaryURL = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let shareURL = documents.appendingPathComponent("WQTerm.mobiledevicepairing", isDirectory: false)

        var payload: [String: Any] = [
            "DeviceName": deviceName,
            "HostName": Self.serviceName,
            "HostIdentifier": hostIdentifier(),
            "AltIRK": record["AltIRK"] ?? altIRKBase64(),
            "DeviceUDID": record["DeviceUDID"] ?? record["UDID"] ?? "",
            "PairingData": record["PairingData"] ?? "",
            "Protocol": "RPPairing",
            "Version": 1,
            "RPPairing": true,
            "Lockdown": true,
            "CreatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        for (key, value) in record where payload[key] == nil {
            payload[key] = value
        }

        guard let data = try? PropertyListSerialization.data(fromPropertyList: payload,
                                                             format: .xml,
                                                             options: 0) else {
            lastError = "Không tạo được nội dung pairing file."
            return nil
        }

        do {
            try data.write(to: primaryURL, options: .atomic)
            try data.write(to: shareURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                                   ofItemAtPath: primaryURL.path)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                                   ofItemAtPath: shareURL.path)
        } catch {
            lastError = "Không ghi được pairing file: \(error.localizedDescription)"
            return nil
        }

        defaults.set(true, forKey: pairedKey)
        defaults.set(deviceName, forKey: deviceNameKey)
        self.deviceName = deviceName
        self.pairingFileURL = primaryURL
        self.isPaired = true
        self.statusMessage = "Đã ghép nối với \(deviceName). Pairing file đã lưu vào Documents/."
        self.lastError = nil
        AuditLogger.shared.log(event: .backupCreated(path: primaryURL.path))
        stopHost()
        return primaryURL
    }

    /// Tạo / trả về file pairing để chia sẻ ra ngoài.
    func exportCompositePairingFile() -> URL? {
        if let pairingFileURL, FileManager.default.fileExists(atPath: pairingFileURL.path) {
            return pairingFileURL
        }
        return completePairing(deviceName: deviceName ?? "iPhone", record: [:])
    }

    /// Kiểm tra lại trạng thái khi app quay lại foreground.
    func recheck() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let exists = FileManager.default.fileExists(atPath: file.path)
        isPaired = defaults.bool(forKey: pairedKey) || exists
        pairingFileURL = exists ? file : nil
        deviceName = defaults.string(forKey: deviceNameKey)
    }

    /// Xoá trạng thái pairing (không xoá file đã lưu để tránh mất dữ liệu).
    func resetPairingState() {
        defaults.set(false, forKey: pairedKey)
        defaults.removeObject(forKey: deviceNameKey)
        isPaired = false
        deviceName = nil
        statusMessage = "Đã đặt lại trạng thái ghép nối. File pairing cũ vẫn còn trong Documents/."
    }

    // MARK: - Socket handling

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.isDeviceConnected = true
                    self.statusMessage = "Thiết bị đã kết nối. Nhập mã \(self.pairingCode) trên iPhone."
                }
                self.receive(on: connection)
            case .failed, .cancelled:
                DispatchQueue.main.async { self.isDeviceConnected = false }
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let key = ObjectIdentifier(connection)
            if let data, !data.isEmpty {
                var buffer = self.receiveBuffers[key] ?? Data()
                buffer.append(data)
                // Giới hạn bộ đệm để tránh cấp phát vô hạn từ peer lạ.
                if buffer.count > 4 * 1024 * 1024 {
                    buffer = Data(buffer.suffix(4 * 1024 * 1024))
                }
                self.receiveBuffers[key] = buffer

                if let parsed = self.parsePairingRecord(buffer) {
                    DispatchQueue.main.async {
                        self.completePairing(deviceName: parsed.name, record: parsed.record)
                    }
                    self.remove(connection)
                    return
                }
            }

            if let error {
                DispatchQueue.main.async {
                    self.lastError = "Kết nối pairing đóng: \(error.localizedDescription)"
                }
                self.remove(connection)
                return
            }
            if isComplete {
                self.remove(connection)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
        DispatchQueue.main.async { self.isDeviceConnected = false }
    }

    /// Nhận diện pairing record từ dữ liệu thô (plist, JSON hoặc chuỗi OPACK).
    private func parsePairingRecord(_ data: Data) -> (name: String, record: [String: Any])? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = plist as? [String: Any],
           isPairingDictionary(dictionary) {
            let name = (dictionary["DeviceName"] as? String)
                ?? (dictionary["Name"] as? String)
                ?? "iPhone"
            return (name, dictionary)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           isPairingDictionary(json) {
            let name = (json["DeviceName"] as? String) ?? "iPhone"
            return (name, json)
        }

        // OPACK/TLV nhị phân: chỉ nhận diện khi có dấu hiệu pairing rõ ràng.
        if let text = String(data: data, encoding: .utf8),
           text.contains("PairingData") || text.contains("AltIRK") || text.contains("DeviceName") {
            return ("iPhone", [
                "PairingData": data.base64EncodedString(),
                "DeviceName": "iPhone"
            ])
        }
        return nil
    }

    private func isPairingDictionary(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys)
        return keys.contains("PairingData")
            || keys.contains("AltIRK")
            || keys.contains("DeviceUDID")
            || keys.contains("DeviceName")
    }

    // MARK: - Host identity / Bonjour TXT

    private func ensureHostIdentity() {
        if defaults.string(forKey: identifierKey) == nil {
            defaults.set(UUID().uuidString, forKey: identifierKey)
        }
        if defaults.data(forKey: altIRKKey) == nil {
            defaults.set(Self.randomBytes(count: 16), forKey: altIRKKey)
        }
    }

    private func hostIdentifier() -> String {
        if let value = defaults.string(forKey: identifierKey) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: identifierKey)
        return value
    }

    private func altIRKBase64() -> String {
        if let data = defaults.data(forKey: altIRKKey) {
            return data.base64EncodedString()
        }
        let data = Self.randomBytes(count: 16)
        defaults.set(data, forKey: altIRKKey)
        return data.base64EncodedString()
    }

    private func makeTXTRecord() -> Data {
        let entries: [String: String] = [
            "identifier": hostIdentifier(),
            "authTag": altIRKBase64(),
            "model": "Mac17,7",
            "name": Self.serviceName,
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ]
        return Self.txtRecordData(entries)
    }

    /// Mã hoá TXT record theo định dạng DNS-SD (length-prefixed key=value).
    private static func txtRecordData(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let pair = "\(key)=\(value)"
            let bytes = Array(pair.utf8)
            guard bytes.count <= 255 else { continue }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
