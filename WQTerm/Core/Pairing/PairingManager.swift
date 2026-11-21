import Foundation
import Network
import Security
import Combine
import UserNotifications

/// Pairing Host — iOS 27 device-initiated remote pairing.
///
/// Luồng bắt buộc (KHÔNG được nhảy bước):
/// 1. VPN configuration → 2. VPN provider → 3. tunnel validation →
/// 4. tunnel address → 5. routing → 6. TCP listener → 7. Bonjour advertisement →
/// 8. host discovery → 9. TCP connection → 10. pairing handshake → 11. completion.
///
/// Pairing chỉ được báo thành công ở bước 10 khi HMAC của `response` khớp
/// `challenge` thật sự (xem `HandshakeSession`). Mọi lỗi mạng (bao gồm
/// `NWError -65569 DefunctConnection` = EBADF) đều đóng connection và KHÔNG tái sử
/// dụng nó.
final class PairingManager: ObservableObject {
    static let shared = PairingManager()

    static let serviceType = BonjourAdvertiser.serviceType
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

    /// Kết quả một bước chẩn đoán: trạng thái + nguyên nhân + mã lỗi + thời gian + cách sửa.
    struct DiagnosticResult: Identifiable, Equatable {
        let id: String
        let title: String
        var status: DiagnosticStatus
        var detail: String
        var errorText: String?
        var errorCode: String?
        var recovery: String?
        var duration: TimeInterval?

        init(id: String, title: String, status: DiagnosticStatus = .pending,
             detail: String = "", errorText: String? = nil, errorCode: String? = nil,
             recovery: String? = nil, duration: TimeInterval? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
            self.errorText = errorText
            self.errorCode = errorCode
            self.recovery = recovery
            self.duration = duration
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
    @Published private(set) var tunnelCandidates: [TunnelCandidate] = []
    @Published private(set) var bonjourDiscovered = false
    @Published private(set) var pinConfirmed = false
    @Published private(set) var handshakeVerified = false
    @Published private(set) var handshakeState: HandshakeState = .idle
    @Published private(set) var diagnostics: [DiagnosticResult] = []
    @Published private(set) var isRunningDiagnostics = false
    @Published private(set) var listenerState: ListenerState = .stopped

    private let defaults = UserDefaults(suiteName: "group.com.wqterm.app") ?? UserDefaults.standard
    private let deviceNameKey = "WQTerm.Pairing.DeviceName"
    private let identifierKey = "WQTerm.Pairing.HostIdentifier"
    private let altIRKKey = "WQTerm.Pairing.AltIRK"
    private let verifiedKey = "WQTerm.Pairing.HandshakeVerified"

    private let queue = DispatchQueue(label: "com.wqterm.pairing", qos: .userInitiated)
    private let listenerManager = TunnelListenerManager.shared
    private let bonjour = BonjourAdvertiser.shared
    private var tunnelObserver: NSObjectProtocol?

    /// Phiên đang mở. Mỗi connection có session riêng; không dùng lại sau lỗi.
    /// Dictionary được bảo vệ bằng `sessionLock`: callback của NWConnection chạy
    /// trên listener queue, còn `stopHost()`/`forceReset()` có thể gọi từ main.
    private struct ActiveSession {
        let connection: NWConnection
        var handshake: HandshakeSession
        var buffer: Data
        var isClosed: Bool
    }
    private var sessions: [ObjectIdentifier: ActiveSession] = [:]
    private let sessionLock = NSLock()

    private func withSessions<T>(_ body: (inout [ObjectIdentifier: ActiveSession]) -> T) -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return body(&sessions)
    }

    private func sessionSnapshot() -> [ObjectIdentifier: ActiveSession] {
        withSessions { $0 }
    }

    private var sessionCount: Int { withSessions { $0.count } }
    private var hasSessions: Bool { withSessions { !$0.isEmpty } }
    private var handshakeTimeout: DispatchWorkItem?
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
        let info = NetworkUtils.currentTunnelInfo()
        self.tunnelReady = info.isReady
        self.tunnelSummary = info.summary
        self.tunnelCandidates = info.resolution.candidates
        ensureHostIdentity()

        wireListener()

        tunnelObserver = NotificationCenter.default.addObserver(
            forName: .wqTunnelDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tunnelTopologyChanged()
        }
        TunnelMonitor.shared.start()
        resetDiagnostics()
    }

    deinit {
        if let tunnelObserver { NotificationCenter.default.removeObserver(tunnelObserver) }
        handshakeTimeout?.cancel()
        let snapshot = sessionSnapshot()
        snapshot.values.forEach { $0.connection.cancel() }
    }

    // MARK: - Public constants

    static var supportsDeviceInitiatedPairing: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    static let vpnWarning = "Vui lòng bật LocalDevVPN trước khi ghép nối"

    static let steps: [(title: String, detail: String)] = [
        ("Bật LocalDevVPN",
         "Bật LocalDevVPN để tạo tunnel riêng. Chưa có tunnel thì listener không bind được "
            + "và màn hình nhập mã PIN sẽ không xuất hiện."),
        ("Mở Chế độ nhà phát triển",
         "Vào Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Ghép nối với WQTerm."),
        ("Nhập mã PIN 6 số",
         "Mã hiển thị trên Dynamic Island hoặc thông báo. Chỉ báo ghép nối sau khi nhận được "
            + "handshake hợp lệ.")
    ]

    static func generateCode() -> String {
        (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    var tunnelAddressLabel: String { TunnelConfiguration.shared.effectiveAddress }
    var listenerPortLabel: String { TunnelConfiguration.shared.listenerPortLabel }

    // MARK: - State transitions

    private func transition(_ newState: HostState, message: String? = nil) {
        DispatchQueue.main.async {
            let old = self.state
            self.state = newState
            if newState == .advertising || newState == .connected {
                self.isAdvertising = true
            } else if newState == .stopped || newState == .failed || newState == .completed {
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

    /// Bắt đầu luồng ghép nối. Chỉ đi tiếp khi tunnel được xác minh.
    /// Trả về `false` kèm `lastError` khi dừng ở bước đầu.
    @discardableResult
    func beginPairing() -> Bool {
        let info = NetworkUtils.currentTunnelInfo()
        tunnelReady = info.isReady
        tunnelSummary = info.summary
        tunnelCandidates = info.resolution.candidates

        guard info.isReady else {
            // Không báo "ghép nối thất bại" như lỗi handshake — đây là thiếu tiền đề.
            let message: String
            switch info.resolution {
            case let .candidateAvailable(candidates):
                message = "Tunnel có nhưng không khớp \(info.expectedAddress). "
                    + "Ứng viên: \(candidates.map(\.summary).joined(separator: ", ")). "
                    + "Chạy Kiểm tra kết nối để xác nhận địa chỉ thật."
            case .noTunnelInterface:
                message = Self.vpnWarning + " (chưa có interface tunnel)"
            case let .noUsableAddress(names, _):
                message = "Interface \(names.joined(separator: ", ")) không có địa chỉ tunnel dùng được. "
                    + "ipsec*/utun* hệ thống không được tính."
            case .active:
                message = Self.vpnWarning
            }
            logError("VPN", message, code: "E_TUNNEL_NOT_READY")
            transition(.failed, message: message)
            return false
        }

        guard state == .stopped || state == .failed || state == .completed else {
            PairingLogger.shared.log(.warn, stage: "STATE", "Bỏ qua beginPairing — đang \(state.rawValue)")
            return false
        }
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
        guard force || state == .stopped || state == .failed || state == .completed else {
            PairingLogger.shared.log(.warn, stage: "HOST", "startHost bỏ qua — state=\(state.rawValue)")
            return
        }
        transition(.starting, message: "Đang chuẩn bị listener trên tunnel…")
        PairingLogger.shared.log(.info, stage: "HOST", "Bắt đầu host",
                                 detail: TunnelConfiguration.shared.summary)
        listenerManager.start(requireTunnel: true, allowCandidateAdoption: false)
    }

    func stopHost(reason: String? = nil) {
        bonjour.detach(from: nil)
        listenerManager.stop(reason: reason)
        closeAllSessions()
        advertisedPort = nil
        bonjourDiscovered = false
        handshakeState = .idle
        let message = reason.map { "Pairing Host đã dừng: \($0)" }
        transition(.stopped, message: message)
        PairingLogger.shared.log(.info, stage: "HOST", "Dừng host", detail: reason)
    }

    func forceReset() {
        stopHost(reason: "Đặt lại thủ công")
        pinConfirmed = false
        handshakeVerified = false
        handshakeState = .idle
        pairingCode = Self.generateCode()
        statusMessage = "Đã đặt lại. Bấm \"Bắt đầu ghép nối\" để thử lại."
    }

    /// Người dùng xác nhận địa chỉ tunnel thực tế rồi dựng lại listener.
    func adoptCandidate(_ candidate: TunnelCandidate) {
        bonjour.detach(from: nil)
        closeAllSessions()
        listenerManager.adoptCandidate(candidate)
        tunnelSummary = NetworkUtils.currentTunnelInfo().summary
        statusMessage = "Đã xác nhận \(candidate.address) @ \(candidate.interface). Đang dựng lại listener."
    }

    // MARK: - Listener wiring

    private func wireListener() {
        listenerManager.onStateChange = { [weak self] state, failure in
            guard let self else { return }
            DispatchQueue.main.async { self.listenerState = state }
            self.listenerStateDidChange(state, failure: failure)
        }
        listenerManager.onReadyConnection = { [weak self] connection in
            self?.beginSession(on: connection)
        }
    }

    private func listenerStateDidChange(_ listenerState: ListenerState, failure: ListenerFailure?) {
        DispatchQueue.main.async { self.listenerState = listenerState }

        switch listenerState {
        case .listening:
            let port = listenerManager.port
            DispatchQueue.main.async { self.advertisedPort = port }
            transition(.listening, message: port.map { "Listener sẵn sàng tại port \($0)." } ?? "Listener sẵn sàng.")
            // Bonjour CHỈ sau khi listener ready và biết port thật.
            guard let port else {
                logError("BONJOUR", "Listener ready nhưng thiếu port", code: ListenerErrorCode.portUnavailable.rawValue)
                return
            }
            if let rawListener = listenerManager.currentListener,
               bonjour.attach(to: rawListener, port: port,
                              identifier: hostIdentifier(), authTag: altIRKBase64()) {
                transition(.advertising,
                           message: "Đang quảng bá \(bonjour.type) tại port \(port). "
                               + "Mã \(pairingCode) trên thông báo.")
                postPINNotification()
                scheduleHandshakeTimeout()
            }
        case .acceptingConnections:
            break
        case .failed:
            bonjour.detach(from: nil)
            if let failure {
                logError("LISTENER", failure.message, code: failure.displayCode)
                transition(.failed, message: "\(failure.message) → \(failure.recovery)")
            } else {
                transition(.failed)
            }
        case .recovering:
            bonjour.detach(from: nil)
        case .stopped, .stopping:
            bonjour.detach(from: nil)
            DispatchQueue.main.async { self.advertisedPort = nil }
        case .initializing, .waitingForTunnel, .validatingAddress, .startingListener:
            break
        }
    }

    private func tunnelTopologyChanged() {
        let info = NetworkUtils.currentTunnelInfo()
        DispatchQueue.main.async {
            self.tunnelReady = info.isReady
            self.tunnelSummary = info.summary
            self.tunnelCandidates = info.resolution.candidates
        }
        PairingLogger.shared.log(.info, stage: "VPN", "Tunnel thay đổi: \(info.summary)")
        if !info.isReady {
            PairingLogger.shared.log(.warn, stage: "VPN", "Tunnel mất — dừng Pairing Host")
            stopHost(reason: "LocalDevVPN đã ngắt")
        }
    }

    // MARK: - Pairing session (challenge → hello → response → verify)

    private func beginSession(on connection: NWConnection) {
        // Mỗi connection là một phiên mới; không tái sử dụng session/connection cũ.
        let key = ObjectIdentifier(connection)
        let alreadyKnown = withSessions { $0[key] != nil }
        if alreadyKnown {
            PairingLogger.shared.log(.warn, stage: "TCP", "Bỏ qua connection trùng")
            connection.cancel()
            return
        }
        let handshake = HandshakeSession(challenge: HandshakeSession.randomChallenge())
        withSessions { sessions in
            sessions[key] = ActiveSession(connection: connection,
                                          handshake: handshake,
                                          buffer: Data(),
                                          isClosed: false)
        }
        DispatchQueue.main.async { self.isDeviceConnected = true }
        transition(.connected, message: "Thiết bị đã kết nối — gửi challenge, chờ handshake.")

        // Gửi challenge ngay: thiết bị phải trả HMAC thì mới có bằng chứng.
        let message = handshake.challengeMessage()
        connection.send(content: message, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.failSession(key, stage: "HANDSHAKE",
                                 message: "Không gửi được challenge: \(error.localizedDescription)",
                                 code: Self.errorCode(error))
            }
        })
        receiveNext(key)
    }

    private func receiveNext(_ key: ObjectIdentifier) {
        let connection: NWConnection? = withSessions { $0[key]?.connection }
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            let stillOpen = self.withSessions { sessions -> Bool in
                guard var current = sessions[key], !current.isClosed else { return false }
                if let data, !data.isEmpty {
                    current.buffer.append(data)
                    sessions[key] = current
                }
                return true
            }
            guard stillOpen else { return }

            if let data, !data.isEmpty, self.drainFrames(key) {
                return   // session đã đóng/hoàn tất
            }
            if let error {
                self.failSession(key, stage: "HANDSHAKE",
                                 message: "Kết nối đóng: \(error.localizedDescription)",
                                 code: Self.errorCode(error))
                return
            }
            if isComplete {
                self.closeSession(key, reason: "Thiết bị đóng kết nối")
                return
            }
            self.receiveNext(key)
        }
    }

    /// Bóc toàn bộ khung có trong buffer. Trả về `true` khi session đã kết thúc.
    /// Không giữ lock trong lúc gọi callback (tránh deadlock).
    private func drainFrames(_ key: ObjectIdentifier) -> Bool {
        while true {
            enum Next { case needMore, closed, step(HandshakeStep), badFrame(UInt32) }

            let next: Next = withSessions { sessions in
                guard var session = sessions[key], !session.isClosed else { return .closed }
                guard let decoded = PairingFrame.decode(session.buffer) else { return .needMore }
                switch decoded {
                case let .invalidLength(length):
                    return .badFrame(length)
                case let .complete(message, remainder):
                    session.buffer = remainder
                    let step = session.handshake.handle(message: message)
                    sessions[key] = session
                    return .step(step)
                }
            }

            switch next {
            case .needMore:
                return false
            case .closed:
                return true
            case let .badFrame(length):
                failSession(key, stage: "HANDSHAKE",
                            message: "Khung có độ dài không hợp lệ: \(length)",
                            code: "E_FRAME_LENGTH")
                return true
            case let .step(step):
                let state = withSessions { $0[key]?.handshake.state ?? .idle }
                DispatchQueue.main.async { self.handshakeState = state }

                switch step {
                case .continueReading:
                    continue
                case .awaitingResponse:
                    let name = withSessions { $0[key]?.handshake.deviceName } ?? "?"
                    PairingLogger.shared.log(.info, stage: "HANDSHAKE",
                                             "Nhận hello từ \(name) — chờ response HMAC")
                    DispatchQueue.main.async {
                        self.transition(.pairing, message: "Đã nhận hồ sơ thiết bị — chờ xác thực HMAC.")
                    }
                    continue
                case let .verified(name, record):
                    completeVerifiedSession(key, name: name, record: record)
                    return true
                case let .rejected(reason):
                    failSession(key, stage: "HANDSHAKE", message: "Handshake bị từ chối: \(reason)",
                                code: "E_HANDSHAKE_REJECTED")
                    return true
                }
            }
        }
    }

    private func completeVerifiedSession(_ key: ObjectIdentifier, name: String, record: [String: Any]) {
        let open = withSessions { sessions -> Bool in
            guard let session = sessions[key], !session.isClosed else { return false }
            return true
        }
        guard open else { return }
        handshakeVerified = true
        DispatchQueue.main.async { self.handshakeState = .verified }
        defaults.set(true, forKey: verifiedKey)
        _ = completePairing(deviceName: name, record: record, verified: true)
        transition(.completed, message: "Handshake hợp lệ — đã ghép nối với \(name).")
        PairingLogger.shared.log(.info, stage: "HANDSHAKE", "HMAC khớp — handshake thành công",
                                 detail: name)
        closeSession(key, reason: "Hoàn tất handshake")
        stopHost(reason: "Hoàn tất ghép nối")
    }

    /// Đóng phiên bị lỗi. **Không** tái sử dụng connection: nó bị cancel và xoá khỏi
    /// danh sách ngay, nên lần kết nối sau luôn là connection mới (tránh
    /// `NWError -65569 DefunctConnection`).
    private func failSession(_ key: ObjectIdentifier, stage: String, message: String, code: String?) {
        logError(stage, message, code: code)
        closeSession(key, reason: message)
        DispatchQueue.main.async {
            if self.state == .connected || self.state == .pairing {
                self.transition(.advertising, message: "Handshake thất bại — vẫn đang chờ thiết bị khác.")
            }
        }
    }

    private func closeSession(_ key: ObjectIdentifier, reason: String) {
        let removed: ActiveSession? = withSessions { sessions in
            guard let session = sessions.removeValue(forKey: key) else { return nil }
            return session
        }
        guard let removed else { return }
        removed.connection.stateUpdateHandler = nil
        removed.connection.cancel()
        PairingLogger.shared.log(.info, stage: "TCP", "Đóng phiên", detail: reason)
        let remaining = sessionCount
        DispatchQueue.main.async { self.isDeviceConnected = remaining > 0 }
    }

    private func closeAllSessions() {
        let keys = withSessions { Array($0.keys) }
        for key in keys {
            closeSession(key, reason: "Dọn toàn bộ phiên")
        }
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
    }

    private func scheduleHandshakeTimeout() {
        handshakeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.handshakeVerified, !self.hasSessions else { return }
            self.logError("HANDSHAKE",
                          "Không có handshake trong \(Int(self.maxHandshakeDuration))s.",
                          code: "E_HANDSHAKE_TIMEOUT")
            DispatchQueue.main.async {
                self.statusMessage = "Chưa có thiết bị nào hoàn tất handshake. Host vẫn đang chờ."
            }
        }
        handshakeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxHandshakeDuration, execute: work)
    }

    // MARK: - Local Network permission

    func requestLocalNetworkPermissionOnce() {
        // Browse chính service của mình một lần: iOS sẽ hiển thị prompt quyền
        // Mạng nội bộ khi có browse Bonjour đầu tiên.
        Task {
            _ = await bonjour.browse(timeout: 3)
            PairingLogger.shared.log(.info, stage: "BONJOUR",
                                     "Đã kích hoạt quyền Mạng nội bộ (browse thử)")
        }
    }

    // MARK: - Pairing file

    /// - Parameter verified: `true` chỉ khi handshake HMAC thật sự hoàn tất.
    @discardableResult
    func completePairing(deviceName: String, record: [String: Any], verified: Bool = false) -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let primaryURL = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let shareURL = documents.appendingPathComponent("WQTerm.mobiledevicepairing", isDirectory: false)

        var payload: [String: Any] = [
            "DeviceName": deviceName,
            "HostName": Self.serviceName,
            "HostIdentifier": hostIdentifier(),
            "Protocol": "RPPairing",
            "Version": 1,
            "HandshakeVerified": verified,
            "CreatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        for (key, value) in record { payload[key] = value }

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

    /// Đọc lại trạng thái từ đĩa/UserDefaults (không làm mất host đang chạy).
    func recheck() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("mobiledevicepairing", isDirectory: false)
        let exists = FileManager.default.fileExists(atPath: file.path)
        let verified = defaults.bool(forKey: verifiedKey)
        handshakeVerified = verified
        isPaired = verified
        pairingFileURL = exists ? file : nil
        deviceName = defaults.string(forKey: deviceNameKey)
        let info = NetworkUtils.currentTunnelInfo()
        tunnelReady = info.isReady
        tunnelSummary = info.summary
        tunnelCandidates = info.resolution.candidates
    }

    func resetPairingState() {
        defaults.set(false, forKey: verifiedKey)
        defaults.removeObject(forKey: deviceNameKey)
        isPaired = false
        handshakeVerified = false
        handshakeState = .idle
        pinConfirmed = false
        deviceName = nil
        statusMessage = "Đã đặt lại trạng thái ghép nối. File pairing cũ vẫn được giữ."
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
            ("connection", "7. Pairing handshake")
        ]
        diagnostics = titles.map { DiagnosticResult(id: $0.0, title: $0.1) }
    }

    private func setDiagnostic(_ id: String, _ status: DiagnosticStatus, _ detail: String,
                               error: String? = nil, code: String? = nil,
                               recovery: String? = nil, duration: TimeInterval? = nil) {
        DispatchQueue.main.async {
            guard let index = self.diagnostics.firstIndex(where: { $0.id == id }) else { return }
            self.diagnostics[index].status = status
            self.diagnostics[index].detail = detail
            self.diagnostics[index].errorText = error
            self.diagnostics[index].errorCode = code
            self.diagnostics[index].recovery = recovery
            self.diagnostics[index].duration = duration
            PairingLogger.shared.log(status == .fail ? .error : .info,
                                     stage: "CHECK", "\(id): \(status.rawValue)",
                                     detail: detail + (code.map { " [\($0)]" } ?? ""))
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

        await checkVPNStep()
        let address = await checkAddressStep()
        await checkRouteStep(address: address)
        await checkListenerStep()
        await checkBonjourStep()
        await checkDiscoveryStep()
        await checkHandshakeStep()
    }

    // MARK: - Bước 1: VPN / tunnel interface

    private func checkVPNStep() async {
        let start = Date()
        let topology = NetworkUtils.captureTopology()
        let info = NetworkUtils.currentTunnelInfo()
        let elapsed = Date().timeIntervalSince(start)

        switch topology.resolution {
        case let .active(address, interface, peer, adopted):
            let peerText = peer.map { " peer=\($0)" } ?? ""
            setDiagnostic("vpn", .pass,
                          "\(address) @ \(interface)\(peerText)" + (adopted ? " (đã xác nhận)" : ""),
                          code: nil, recovery: nil, duration: elapsed)
        case let .candidateAvailable(candidates):
            let list = candidates.map(\.summary).joined(separator: ", ")
            setDiagnostic("vpn", .warning,
                          "Có interface tunnel nhưng không khớp \(info.expectedAddress). "
                              + "Ứng viên: \(list)",
                          error: "Không tìm thấy \(info.expectedAddress) trên tunnel",
                          code: ListenerErrorCode.addressNotConfirmed.rawValue,
                          recovery: "Nếu đây đúng là tunnel của bạn, bấm \"Dùng địa chỉ này\" "
                              + "để xác nhận. Không tự đổi IP.",
                          duration: elapsed)
        case let .noUsableAddress(names, rejections):
            setDiagnostic("vpn", .fail,
                          "Interface \(names.joined(separator: ", ")): "
                              + rejections.joined(separator: "; "),
                          error: "Không có địa chỉ tunnel dùng được",
                          code: ListenerErrorCode.noUsableAddress.rawValue,
                          recovery: "LocalDevVPN phải tạo tunnel point-to-point với địa chỉ riêng. "
                              + "ipsec*/utun* hệ thống (địa chỉ công khai) không được tính.",
                          duration: elapsed)
        case .noTunnelInterface:
            setDiagnostic("vpn", .fail,
                          "Không có interface utun/ppp/ipsec nào",
                          error: Self.vpnWarning,
                          code: ListenerErrorCode.noTunnel.rawValue,
                          recovery: "Bật LocalDevVPN trong app cung cấp tunnel rồi chạy lại kiểm tra.",
                          duration: elapsed)
        }
        DispatchQueue.main.async {
            self.tunnelReady = info.isReady
            self.tunnelSummary = info.summary
            self.tunnelCandidates = info.resolution.candidates
        }
    }

    /// Trả về địa chỉ đã xác minh (nếu có) để các bước sau dùng.
    private func checkAddressStep() async -> String? {
        let start = Date()
        let topology = NetworkUtils.captureTopology()
        let elapsed = Date().timeIntervalSince(start)
        let expected = TunnelConfiguration.shared.preferredAddress

        guard let address = topology.resolution.activeAddress else {
            setDiagnostic("address", .skipped,
                          "Bỏ qua: chưa có địa chỉ tunnel đã xác minh",
                          code: "SKIPPED_NO_TUNNEL", duration: elapsed)
            return nil
        }

        // Xác minh thêm: địa chỉ phải còn thật trên interface, có netmask/CIDR.
        let snapshot = topology.interfaces.first {
            $0.address == address && $0.kind.isTunnel
        }
        let cidr = snapshot.flatMap { IPv4.cidr(address: $0.address, netmask: $0.netmask) }
        let conflicting = NetworkUtils.isAddressInUseOnDevice(address, excluding: snapshot?.name)
        let adopted = signatureAdopted(topology: topology)

        var detail = cidr ?? address
        if let snapshot {
            detail += " @ \(snapshot.name) (UP=\(snapshot.isUp), RUNNING=\(snapshot.isRunning), "
                + "P2P=\(snapshot.isPointToPoint))"
        }
        if adopted { detail += " — khác cấu hình \(expected), đã xác nhận" }

        if conflicting {
            setDiagnostic("address", .warning, detail,
                          error: "Địa chỉ cũng xuất hiện trên interface khác",
                          code: "E_ADDRESS_CONFLICT",
                          recovery: "Kiểm tra xung đột IP trước khi bind listener.",
                          duration: elapsed)
        } else {
            setDiagnostic("address", .pass, detail, duration: elapsed)
        }
        return address
    }

    // MARK: - Bước 3: routing

    private func checkRouteStep(address: String?) async {
        guard let address else {
            setDiagnostic("route", .skipped, "Bỏ qua: chưa có địa chỉ tunnel")
            return
        }
        let start = Date()
        let port = TunnelConfiguration.shared.relayPort
        let reachable = await NetworkUtils.canReach(host: address, port: port, timeout: 1.5)
        let elapsed = Date().timeIntervalSince(start)

        // Lưu ý: relay có thể không chạy ⇒ unreachable KHÔNG chứng minh tunnel hỏng.
        // Đây là lý do bước này WARNING chứ không FAIL khi tunnel đã xác minh.
        if reachable {
            setDiagnostic("route", .pass,
                          "TCP tới \(address):\(port) thành công",
                          duration: elapsed)
        } else {
            setDiagnostic("route", .warning,
                          "Không kết nối được \(address):\(port) trong \(String(format: "%.1f", elapsed))s",
                          error: "Không có tiến trình nào lắng nghe ở port relay",
                          code: "E_RELAY_UNREACHABLE",
                          recovery: "Bình thường nếu Diagnostics Relay không chạy. "
                              + "Routing tunnel vẫn được coi là hợp lệ vì địa chỉ đã nằm trên interface.",
                          duration: elapsed)
        }
    }

    // MARK: - Bước 4: TCP listener

    private func checkListenerStep() async {
        let start = Date()
        let state = listenerManager.state
        let elapsed = Date().timeIntervalSince(start)

        guard state == .listening || state == .acceptingConnections,
              let port = listenerManager.port,
              let bound = listenerManager.boundAddress else {
            let failure = listenerManager.lastFailure
            setDiagnostic("listener", .fail,
                          "state=\(state.rawValue)" + (listenerManager.port.map { ", port=\($0)" } ?? ", chưa có port"),
                          error: failure?.message ?? "Listener chưa ready",
                          code: failure?.displayCode,
                          recovery: failure?.recovery ?? "Bấm \"Bắt đầu ghép nối\" để dựng listener.",
                          duration: elapsed)
            return
        }

        // Probe thật: connect tới chính listener mình vừa mở.
        let probeStart = Date()
        let reachable = await NetworkUtils.canReach(host: bound, port: port, timeout: 2)
        let probeElapsed = Date().timeIntervalSince(probeStart)
        var detail = "listening \(bound):\(port) @ \(listenerManager.boundInterface ?? "?")"
        detail += ", kết nối đã nhận=\(listenerManager.acceptedConnectionCount)"

        if reachable {
            setDiagnostic("listener", .pass, detail,
                          duration: elapsed + probeElapsed)
        } else {
            setDiagnostic("listener", .warning,
                          detail + ", probe TCP không phản hồi",
                          error: "Listener ready nhưng probe không kết nối được",
                          code: "E_LISTENER_PROBE",
                          recovery: "Kiểm tra lại địa chỉ bind và quyền Mạng nội bộ.",
                          duration: elapsed + probeElapsed)
        }
    }

    // MARK: - Bước 5: Bonjour

    private func checkBonjourStep() async {
        let published = bonjour.isPublished && advertisedPort != nil
        if published {
            setDiagnostic("bonjour", .pass,
                          "Đã quảng bá \(bonjour.type) name=\(bonjour.publishedName ?? "?") "
                              + "port=\(bonjour.publishedPort ?? 0)")
        } else {
            setDiagnostic("bonjour", .fail,
                          "Service chưa được quảng bá",
                          error: bonjour.lastFailure?.message ?? "Chưa gọi attach() sau khi listener ready",
                          code: bonjour.lastFailure?.displayCode ?? "E_BONJOUR_NOT_PUBLISHED",
                          recovery: "Bonjour chỉ publish sau khi listener đạt LISTENING. "
                              + "Kiểm tra bước 4 trước.")
        }
    }

    // MARK: - Bước 6: discovery

    private func checkDiscoveryStep() async {
        guard bonjour.isPublished else {
            setDiagnostic("discovery", .skipped, "Bỏ qua: Bonjour chưa publish")
            return
        }
        let start = Date()
        let result = await bonjour.verifyDiscovery(timeout: 2.5)
        let elapsed = Date().timeIntervalSince(start)
        DispatchQueue.main.async { self.bonjourDiscovered = result.count > 0 }

        if result.count > 0 {
            let names = result.endpoints.prefix(3).map { "\($0)" }.joined(separator: ", ")
            setDiagnostic("discovery", .pass,
                          "Thấy \(result.count) service: \(names)",
                          duration: elapsed)
        } else {
            setDiagnostic("discovery", .warning,
                          "Không thấy service trong \(String(format: "%.1f", elapsed))s",
                          error: "Multicast/Bonjour không đi qua được đường mạng hiện tại",
                          code: "E_DISCOVERY_TIMEOUT",
                          recovery: "Discovery từ chính thiết bị có thể bị chặn bởi tunnel. "
                              + "Thử tắt/bật lại LocalDevVPN, hoặc kiểm tra thiết bị khác có thấy "
                              + "\(bonjour.type) không.",
                          duration: elapsed)
        }
    }

    // MARK: - Bước 7: pairing handshake

    private func checkHandshakeStep() async {
        let verified = handshakeVerified && state == .completed
        if verified {
            setDiagnostic("connection", .pass,
                          "Handshake HMAC hợp lệ với \(deviceName ?? "?") "
                              + "(state=\(state.rawValue))") 
        } else if hasSessions {
            setDiagnostic("connection", .warning,
                          "Có \(sessionCount) kết nối đang chờ, handshake=\(handshakeState.rawValue)",
                          code: "E_HANDSHAKE_IN_PROGRESS",
                          recovery: "Chờ thiết bị gửi hello + response, hoặc kiểm tra debug log.")
        } else {
            setDiagnostic("connection", .fail,
                          "Chưa có handshake được xác thực (handshake=\(handshakeState.rawValue))",
                          error: lastError ?? "Không có kết nối pairing",
                          code: lastErrorCode ?? "E_NO_HANDSHAKE",
                          recovery: "Chỉ báo ghép nối thành công sau khi nhận đủ hello + HMAC response.")
        }
    }

    private func signatureAdopted(topology: NetworkUtils.Topology) -> Bool {
        if case let .active(_, _, _, adopted) = topology.resolution { return adopted }
        return false
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
            center.add(request)
        }
    }

    // MARK: - Host identity

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

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Mã lỗi kèm errno để phân biệt `-65569 DefunctConnection` (EBADF) với timeout.
    static func errorCode(_ error: NWError) -> String {
        switch error {
        case let .posix(code):
            switch code {
            case .EBADF: return "POSIX EBADF (\(code.rawValue)) — defunct connection (-65569)"
            case .ECONNRESET: return "POSIX ECONNRESET (\(code.rawValue))"
            case .ETIMEDOUT: return "POSIX ETIMEDOUT (\(code.rawValue))"
            default: return "POSIX \(code.rawValue)"
            }
        default:
            return "\(error)"
        }
    }
}
