import Foundation
import Network
import Security
import Combine
import UserNotifications

/// Pairing Host — iOS 27 device-initiated remote pairing.
///
/// State machine: STOPPED → STARTING → LISTENING → ADVERTISING → CONNECTED
///                → PAIRING → COMPLETED, với nhánh lỗi về STOPPED/FAILED.
/// Mọi chuyển trạng thái đều có log riêng (PairingLogger), mọi callback async
/// đều mang `generation` để bỏ callback của listener/connection đã bị huỷ.
final class PairingManager: ObservableObject {
    static let shared = PairingManager()

    static let serviceType = "_remotepairing-pairable-host._tcp"
    static let serviceName = "WQTerm"

    enum HostState: String {
        case stopped = "STOPPED"
        case starting = "STARTING"
        case listening = "LISTENING"
        case advertising = "ADVERTISING"
        case connected = "CONNECTED"
        case pairing = "PAIRING"
        case completed = "COMPLETED"
        case failed = "FAILED"
    }

    enum DiagnosticStatus: String {
        case pending, pass, fail, warning, skipped
    }

    struct DiagnosticResult: Identifiable, Equatable {
        let id: String
        let title: String
        var status: DiagnosticStatus
        var detail: String
        var errorText: String?

        init(id: String, title: String, status: DiagnosticStatus = .pending,
             detail: String = "", errorText: String? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
            self.errorText = errorText
        }
    }

    @Published private(set) var state: HostState = .stopped
    @Published private(set) var isPaired: Bool
    @Published private(set) var pairingCode: String
    @Published private(set) var isAdvertising = false
    @Published private(set) var isDeviceConnected = false
    @Published private(set) var advertisedPort: UInt16?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorCode: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var pairingFileURL: URL?
    @Published private(set) var tunnelReady = false
    @Published private(set) var tunnelSummary = ""
    @Published private(set) var bonjourDiscovered = false
    @Published private(set) var pinConfirmed = false
    @Published private(set) var handshakeVerified = false
    @Published private(set) var diagnostics: [DiagnosticResult] = []
    @Published private(set) var isRunningDiagnostics = false

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let pairedKey = "WQTerm.Pairing.IsPaired"
    private let deviceNameKey = "WQTerm.Pairing.DeviceName"
    private let identifierKey = "WQTerm.Pairing.HostIdentifier"
    private let altIRKKey = "WQTerm.Pairing.AltIRK"
    private let verifiedKey = "WQTerm.Pairing.HandshakeVerified"

    private let queue = DispatchQueue(label: "com.wqterm.pairing", qos: .userInitiated)
    private var listener: NWListener?
    private var discoveryBrowser: NWBrowser?
    private var permissionBrowser: NWBrowser?
    private var permissionTimer: DispatchWorkItem?
    private var permissionAttempted = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var generation: UInt64 = 0
    private var retryCount = 0
    private let maxRetries = 2
    private var handshakeTimer: DispatchWorkItem?
    private var tunnelObserver: NSObjectProtocol?
    private let maxHandshakeDuration: TimeInterval = 90

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let fileExists = FileManager.default.fileExists(atPath: file.path)
        let verified = defaults.bool(forKey: verifiedKey)
        self.isPaired = verified
        self.handshakeVerified = verified
        self.pairingCode = Self.generateCode()
        self.deviceName = defaults.string(forKey: deviceNameKey)
        self.pairingFileURL = fileExists ? file : nil
        self.tunnelReady = NetworkUtils.isLocalDevVPNActive
        self.tunnelSummary = NetworkUtils.currentTunnelInfo().summary
        ensureHostIdentity()

        tunnelObserver = NotificationCenter.default.addObserver(
            forName: .wqTunnelDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let info = TunnelMonitor.shared.info
            self.tunnelReady = info.isReady
            self.tunnelSummary = info.summary
            PairingLogger.shared.log(.info, stage: "VPN", "Tunnel thay đổi: \(info.summary)")
            if !info.isReady {
                PairingLogger.shared.log(.warn, stage: "VPN", "Tunnel mất — dừng Pairing Host")
                self.stopHost(reason: "LocalDevVPN đã ngắt")
            }
        }
        TunnelMonitor.shared.start()
        resetDiagnostics()
    }

    deinit {
        if let tunnelObserver { NotificationCenter.default.removeObserver(tunnelObserver) }
        listener?.cancel()
        discoveryBrowser?.cancel()
        permissionBrowser?.cancel()
        permissionTimer?.cancel()
        handshakeTimer?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    // MARK: - Public constants

    static var supportsDeviceInitiatedPairing: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    static let vpnWarning = "Vui lòng bật LocalDevVPN trước khi ghép nối"

    static let steps: [(title: String, detail: String)] = [
        ("Bật LocalDevVPN",
         "Bật LocalDevVPN để tạo tunnel \(TunnelConfiguration.shared.tunnelAddress). "
            + "Chưa có tunnel thì màn hình nhập mã PIN sẽ không xuất hiện."),
        ("Mở Chế độ nhà phát triển",
         "Vào Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Ghép nối với WQTerm."),
        ("Nhập mã PIN 6 số",
         "Mã hiển thị trên Dynamic Island hoặc thông báo. Chỉ báo ghép nối sau khi nhận được handshake hợp lệ.")
    ]

    static func generateCode() -> String {
        (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    var tunnelAddressLabel: String { TunnelConfiguration.shared.tunnelAddress }
    var listenerPortLabel: String { TunnelConfiguration.shared.listenerPortLabel }

    // MARK: - State transitions

    private func transition(_ newState: HostState, message: String? = nil) {
        DispatchQueue.main.async {
            let old = self.state
            self.state = newState
            if newState == .listening || newState == .advertising {
                self.isAdvertising = true
            } else if newState == .stopped || newState == .failed {
                self.isAdvertising = false
            }
            if let message { self.statusMessage = message }
            PairingLogger.shared.log(.info, stage: "STATE", "\(old.rawValue) → \(newState.rawValue)",
                                     detail: message)
        }
    }

    private func logError(_ stage: String, _ message: String, code: String? = nil) {
        DispatchQueue.main.async {
            self.lastError = message
            self.lastErrorCode = code
        }
        PairingLogger.shared.log(.error, stage: stage, message, detail: code)
    }

    // MARK: - Entry point

    /// Chỉ bắt đầu khi tunnel thật sự sẵn sàng (đã loại trừ 127.0.0.1 / lo0).
    @discardableResult
    func beginPairing() -> Bool {
        let info = NetworkUtils.currentTunnelInfo()
        guard info.isReady else {
            let message = Self.vpnWarning + " (\(info.summary))"
            logError("VPN", message)
            transition(.failed, message: message)
            return false
        }
        guard state == .stopped || state == .failed else {
            PairingLogger.shared.log(.warn, stage: "STATE", "Bỏ qua beginPairing — đang \(state.rawValue)")
            return false
        }
        retryCount = 0
        pinConfirmed = false
        requestLocalNetworkPermissionOnce()
        startHost()
        return true
    }

    func refreshCode() {
        pairingCode = Self.generateCode()
        postPINNotification()
        PairingLogger.shared.log(.info, stage: "PIN", "Đổi mã PIN", detail: pairingCode)
    }

    /// Xác nhận người dùng đã nhập PIN — KHÔNG đồng nghĩa handshake thành công.
    func markPaired() {
        pinConfirmed = true
        let message = "Đã xác nhận nhập PIN. Đang chờ handshake từ thiết bị — "
            + "chưa báo ghép nối thành công."
        statusMessage = message
        PairingLogger.shared.log(.warn, stage: "HANDSHAKE", message)
    }

    // MARK: - Host lifecycle

    func startHost(force: Bool = false) {
        guard force || state == .stopped || state == .failed else {
            PairingLogger.shared.log(.warn, stage: "HOST", "startHost bỏ qua — state=\(state.rawValue)")
            return
        }
        guard NetworkUtils.isLocalDevVPNActive else {
            let message = Self.vpnWarning
            logError("VPN", message)
            transition(.failed, message: message)
            return
        }

        generation &+= 1
        let gen = generation
        teardownObjects()

        transition(.starting, message: "Đang tạo TCP listener…")
        PairingLogger.shared.log(.info, stage: "HOST", "Tạo listener", detail: TunnelConfiguration.shared.summary)

        let config = TunnelConfiguration.shared
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let address = IPv4Address(config.tunnelAddress) {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(address),
                port: NWEndpoint.Port(rawValue: config.listenerPort) ?? 0
            )
        }

        let listener: NWListener
        do {
            if config.listenerPort > 0, let port = NWEndpoint.Port(rawValue: config.listenerPort) {
                listener = try NWListener(using: parameters, port: port)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            logError("TCP", "Không tạo được NWListener: \(error.localizedDescription)")
            transition(.failed, message: error.localizedDescription)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == gen else { return }
            switch state {
            case .setup, .preparing:
                PairingLogger.shared.log(.info, stage: "TCP", "Listener \(state)")
            case .waiting(let reason):
                PairingLogger.shared.log(.warn, stage: "TCP", "Listener đang chờ",
                                         detail: String(describing: reason))
                DispatchQueue.main.async {
                    self.statusMessage = "Listener đang chờ quyền Mạng nội bộ hoặc mạng."
                }
            case .ready:
                guard let port = listener.port else {
                    self.handleFailure("Listener ready nhưng không lấy được port",
                                       code: "NO_PORT", gen: gen)
                    return
                }
                // Quảng bá Bonjour CHỈ SAU KHI listener ready và biết port thật.
                listener.service = NWListener.Service(name: Self.serviceName,
                                                      type: Self.serviceType,
                                                      txtRecord: Self.makeTXTRecord())
                DispatchQueue.main.async { self.advertisedPort = port.rawValue }
                PairingLogger.shared.log(.info, stage: "BONJOUR", "Đăng service \(Self.serviceType)",
                                         detail: "port \(port.rawValue)")
                self.transition(.listening, message: "Listener sẵn sàng tại port \(port.rawValue).")
                self.transition(.advertising,
                                message: "Đang quảng bá \(Self.serviceName). Mã \(self.pairingCode) "
                                    + "hiện trên thông báo.")
                self.postPINNotification()
                self.scheduleConnectionTimeout(gen: gen)
            case .failed(let error):
                self.handleFailure("Listener thất bại: \(error.localizedDescription)",
                                   code: Self.errorCode(error), gen: gen)
            case .cancelled:
                PairingLogger.shared.log(.info, stage: "TCP", "Listener cancelled")
                if self.generation == gen { self.transition(.stopped) }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, gen: gen)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stopHost(reason: String? = nil) {
        generation &+= 1
        teardownObjects()
        let message = reason.map { "Pairing Host đã dừng: \($0)" }
        transition(.stopped, message: message)
        PairingLogger.shared.log(.info, stage: "HOST", "Dừng host", detail: reason)
    }

    func forceReset() {
        stopHost(reason: "Đặt lại thủ công")
        retryCount = 0
        pinConfirmed = false
        handshakeVerified = false
        pairingCode = Self.generateCode()
        statusMessage = "Đã đặt lại. Bấm \"Bắt đầu ghép nối\" để thử lại."
    }

    /// Dọn mọi object async. Không giữ connection/listener đã cancel.
    private func teardownObjects() {
        listener?.cancel()
        listener = nil
        discoveryBrowser?.cancel()
        discoveryBrowser = nil
        permissionTimer?.cancel()
        permissionTimer = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        receiveBuffers.removeAll()
        DispatchQueue.main.async {
            self.isDeviceConnected = false
            self.bonjourDiscovered = false
            self.advertisedPort = nil
        }
    }

    private func handleFailure(_ message: String, code: String?, gen: UInt64) {
        guard generation == gen else {
            PairingLogger.shared.log(.warn, stage: "HOST", "Bỏ lỗi của generation cũ", detail: message)
            return
        }
        logError("HOST", message, code: code)
        if retryCount < maxRetries, NetworkUtils.isLocalDevVPNActive {
            retryCount += 1
            transition(.failed, message: "\(message) — thử lại \(retryCount)/\(maxRetries)")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.teardownObjects()
                self.startHost(force: true)
            }
        } else {
            teardownObjects()
            transition(.failed, message: message)
        }
    }

    private func scheduleConnectionTimeout(gen: UInt64) {
        handshakeTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, !self.isPaired else { return }
            self.logError("HANDSHAKE",
                          "Không nhận được handshake trong \(Int(self.maxHandshakeDuration)) giây.",
                          code: "TIMEOUT")
            self.handleFailure("Pairing timeout", code: "TIMEOUT", gen: gen)
        }
        handshakeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + maxHandshakeDuration, execute: timer)
    }

    // MARK: - Local Network permission (chỉ một browser, một lần)

    func requestLocalNetworkPermissionOnce() {
        guard !permissionAttempted else { return }
        permissionAttempted = true
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                PairingLogger.shared.log(.error, stage: "BONJOUR",
                                         "Browser lỗi: \(error.localizedDescription)",
                                         detail: Self.errorCode(error))
            }
        }
        browser.start(queue: queue)
        permissionBrowser = browser
        PairingLogger.shared.log(.info, stage: "BONJOUR", "Đã kích hoạt quyền Mạng nội bộ")

        // Timer này chỉ huỷ đúng browser nó tạo ra (không nhầm browser khác).
        let work = DispatchWorkItem { [weak self] in
            browser.cancel()
            if self?.permissionBrowser === browser { self?.permissionBrowser = nil }
        }
        permissionTimer = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - Socket handling

    private func accept(_ connection: NWConnection, gen: UInt64) {
        guard generation == gen else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        PairingLogger.shared.log(.info, stage: "TCP", "Nhận kết nối mới")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == gen else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.isDeviceConnected = true }
                self.transition(.connected, message: "Thiết bị đã kết nối — chờ handshake.")
                self.receive(on: connection, gen: gen)
            case .waiting(let reason):
                PairingLogger.shared.log(.warn, stage: "TCP", "Connection waiting",
                                         detail: String(describing: reason))
            case .failed(let error):
                self.logError("TCP", "Kết nối lỗi: \(error.localizedDescription)",
                              code: Self.errorCode(error))
                self.remove(connection)
            case .cancelled:
                PairingLogger.shared.log(.info, stage: "TCP", "Connection cancelled")
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, gen: UInt64) {
        let key = ObjectIdentifier(connection)
        // Không bao giờ nhận lại từ connection đã bị huỷ / generation cũ.
        guard generation == gen, connections[key] != nil else {
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.generation == gen, self.connections[key] != nil else { return }
            if let data, !data.isEmpty {
                var buffer = self.receiveBuffers[key] ?? Data()
                buffer.append(data)
                if buffer.count > 4 * 1024 * 1024 { buffer = Data(buffer.suffix(4 * 1024 * 1024)) }
                self.receiveBuffers[key] = buffer

                if let parsed = self.parsePairingRecord(buffer) {
                    DispatchQueue.main.async { self.transition(.pairing) }
                    self.finishHandshake(name: parsed.name, record: parsed.record, gen: gen)
                    return
                }
            }
            if let error {
                self.logError("HANDSHAKE", "Kết nối đóng: \(error.localizedDescription)",
                              code: Self.errorCode(error))
                self.remove(connection)
                return
            }
            if isComplete {
                self.remove(connection)
            } else {
                self.receive(on: connection, gen: gen)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard connections.removeValue(forKey: key) != nil else { return }
        receiveBuffers.removeValue(forKey: key)
        connection.cancel()
        DispatchQueue.main.async { self.isDeviceConnected = false }
    }

    /// Chỉ chấp nhận record có PairingData KHÁC RỖNG + ít nhất một định danh.
    /// Không còn "text chứa PairingData" → báo ghép nối giả.
    private func parsePairingRecord(_ data: Data) -> (name: String, record: [String: Any])? {
        var dictionary: [String: Any]?
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            dictionary = plist as? [String: Any]
        }
        if dictionary == nil, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dictionary = json
        }
        guard let dictionary, isVerifiedPairingDictionary(dictionary) else { return nil }
        let name = (dictionary["DeviceName"] as? String)
            ?? (dictionary["Name"] as? String) ?? "iPhone"
        return (name, dictionary)
    }

    private func isVerifiedPairingDictionary(_ dictionary: [String: Any]) -> Bool {
        func nonEmpty(_ key: String) -> Bool {
            guard let value = dictionary[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasPayload = nonEmpty("PairingData") || (dictionary["PairingData"] as? Data)?.isEmpty == false
        let hasIdentity = nonEmpty("AltIRK") || nonEmpty("DeviceUDID")
        return hasPayload && hasIdentity
    }

    private func finishHandshake(name: String, record: [String: Any], gen: UInt64) {
        guard generation == gen else { return }
        handshakeVerified = true
        defaults.set(true, forKey: verifiedKey)
        _ = completePairing(deviceName: name, record: record, verified: true)
        transition(.completed, message: "Handshake hợp lệ — đã ghép nối với \(name).")
        PairingLogger.shared.log(.info, stage: "HANDSHAKE", "Handshake thành công", detail: name)
    }

    // MARK: - Pairing file

    /// - Parameter verified: `true` chỉ khi handshake thật sự hoàn tất.
    @discardableResult
    func completePairing(deviceName: String, record: [String: Any], verified: Bool = false) -> URL? {
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
            "HandshakeVerified": verified,
            "CreatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        for (key, value) in record where payload[key] == nil { payload[key] = value }

        guard let data = try? PropertyListSerialization.data(fromPropertyList: payload,
                                                            format: .xml, options: 0) else {
            logError("PAIRING_FILE", "Không tạo được nội dung pairing file.")
            return nil
        }
        do {
            try data.write(to: primaryURL, options: .atomic)
            try data.write(to: shareURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primaryURL.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shareURL.path)
        } catch {
            logError("PAIRING_FILE", "Không ghi được pairing file: \(error.localizedDescription)")
            return nil
        }

        defaults.set(verified, forKey: verifiedKey)
        if verified {
            defaults.set(deviceName, forKey: deviceNameKey)
            self.deviceName = deviceName
            self.isPaired = true
            self.handshakeVerified = true
            self.statusMessage = "Đã ghép nối với \(deviceName)."
            stopHost(reason: "Hoàn tất ghép nối")
        } else {
            // Tạo file để export/kiểm tra, nhưng KHÔNG báo đã ghép nối.
            self.statusMessage = "Đã tạo file pairing cục bộ (chưa xác thực handshake)."
        }
        self.pairingFileURL = primaryURL
        AuditLogger.shared.log(event: .backupCreated(path: primaryURL.path))
        return primaryURL
    }

    func exportCompositePairingFile() -> URL? {
        if let pairingFileURL, FileManager.default.fileExists(atPath: pairingFileURL.path) {
            return pairingFileURL
        }
        return completePairing(deviceName: deviceName ?? "iPhone", record: [:], verified: false)
    }

    /// Không làm mất trạng thái host khi chuyển tab / quay lại màn hình.
    func recheck() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let exists = FileManager.default.fileExists(atPath: file.path)
        let verified = defaults.bool(forKey: verifiedKey)
        handshakeVerified = verified
        isPaired = verified
        pairingFileURL = exists ? file : nil
        deviceName = defaults.string(forKey: deviceNameKey)
        tunnelReady = NetworkUtils.isLocalDevVPNActive
        tunnelSummary = NetworkUtils.currentTunnelInfo().summary
    }

    func resetPairingState() {
        defaults.set(false, forKey: pairedKey)
        defaults.set(false, forKey: verifiedKey)
        defaults.removeObject(forKey: deviceNameKey)
        isPaired = false
        handshakeVerified = false
        pinConfirmed = false
        deviceName = nil
        statusMessage = "Đã đặt lại trạng thái ghép nối. File pairing cũ vẫn được giữ."
    }

    // MARK: - PIN notification

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

    // MARK: - Diagnostics (7 bước)

    private func resetDiagnostics() {
        let titles = [
            ("vpn", "1. LocalDevVPN"),
            ("address", "2. Tunnel address"),
            ("route", "3. Tunnel routing"),
            ("listener", "4. TCP listener"),
            ("bonjour", "5. Bonjour advertisement"),
            ("discovery", "6. Host discovery"),
            ("connection", "7. Pairing connection")
        ]
        diagnostics = titles.map { DiagnosticResult(id: $0.0, title: $0.1) }
    }

    private func setDiagnostic(_ id: String, _ status: DiagnosticStatus,
                               _ detail: String, error: String? = nil) {
        DispatchQueue.main.async {
            guard let index = self.diagnostics.firstIndex(where: { $0.id == id }) else { return }
            self.diagnostics[index].status = status
            self.diagnostics[index].detail = detail
            self.diagnostics[index].errorText = error
            PairingLogger.shared.log(status == .fail ? .error : .info,
                                     stage: "CHECK", "\(id): \(status.rawValue)", detail: detail)
        }
    }

    func runDiagnostics() async {
        guard !isRunningDiagnostics else { return }
        DispatchQueue.main.async {
            self.isRunningDiagnostics = true
            self.resetDiagnostics()
        }
        defer {
            DispatchQueue.main.async { self.isRunningDiagnostics = false }
        }

        let info = NetworkUtils.currentTunnelInfo()
        setDiagnostic("vpn", info.isReady ? .pass : .fail,
                      info.isReady ? info.summary
                                   : "\(info.summary). 127.0.0.1 không được tính là LocalDevVPN.",
                      error: info.isReady ? nil : Self.vpnWarning)

        let expected = TunnelConfiguration.shared.tunnelAddress
        setDiagnostic("address", info.hasExpectedAddress ? .pass : .fail,
                      info.hasExpectedAddress
                        ? "\(expected) nằm trên \(info.matchedInterfaces.joined(separator: ", "))"
                        : "Không thấy \(expected) trên interface tunnel. \(info.detail)")

        if info.isReady {
            let reachable = await NetworkUtils.canReachTunnel()
            setDiagnostic("route", reachable ? .pass : .warning,
                          reachable ? "TCP tới \(expected):\(TunnelConfiguration.shared.relayPort) OK"
                                    : "Không kết nối được tới \(expected):\(TunnelConfiguration.shared.relayPort) "
                                        + "(relay có thể không chạy)")
        } else {
            setDiagnostic("route", .skipped, "Bỏ qua vì tunnel chưa sẵn sàng")
        }

        if let port = advertisedPort, state == .listening || state == .advertising {
            let localReachable = await NetworkUtils.canReach(host: expected, port: port, timeout: 1.5)
            setDiagnostic("listener", localReachable ? .pass : .warning,
                          "Listener port \(port), bind \(TunnelConfiguration.shared.listenerPortLabel). "
                            + "Probe: \(localReachable ? "OK" : "không phản hồi")")
        } else {
            setDiagnostic("listener", .fail, "Listener chưa ready (state=\(state.rawValue))",
                          error: lastError)
        }

        let advertised = listener?.service != nil && (state == .advertising || state == .listening)
        setDiagnostic("bonjour", advertised ? .pass : .fail,
                      advertised ? "Đã đăng \(Self.serviceType)" : "Chưa đăng dịch vụ Bonjour",
                      error: advertised ? nil : (lastError ?? "Chưa gọi startHost()"))

        let discovered = await discoverOwnService()
        DispatchQueue.main.async { self.bonjourDiscovered = discovered }
        setDiagnostic("discovery", discovered ? .pass : .warning,
                      discovered ? "Thấy dịch vụ \(Self.serviceType) trên mạng"
                                 : "Không thấy dịch vụ trong 2s (thiết bị khác có thể chưa quét)")

        let connected = state == .connected || state == .pairing || state == .completed
        setDiagnostic("connection", connected ? .pass : .fail,
                      connected ? "state=\(state.rawValue), handshakeVerified=\(handshakeVerified)"
                                : "Chưa có kết nối pairing được xác thực",
                      error: connected ? nil : (lastError ?? lastErrorCode))
    }

    private func discoverOwnService(timeout: TimeInterval = 2) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: parameters)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { result in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                browser.cancel()
                continuation.resume(returning: result)
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { finish(true) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(false) }
            }
            browser.start(queue: queue)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: - Host identity / TXT

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
        if let data = defaults.data(forKey: altIRKKey) { return data.base64EncodedString() }
        let data = Self.randomBytes(count: 16)
        defaults.set(data, forKey: altIRKKey)
        return data.base64EncodedString()
    }

    private static func makeTXTRecord() -> Data {
        let entries: [String: String] = [
            "identifier": shared.hostIdentifier(),
            "authTag": shared.altIRKBase64(),
            "model": "Mac17,7",
            "name": serviceName,
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

    private static func errorCode(_ error: NWError) -> String {
        if case .posix(let code) = error { return "POSIX \(code.rawValue)" }
        return String(describing: error)
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
