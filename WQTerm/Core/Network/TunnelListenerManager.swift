import Foundation
import Network
import Combine

/// Vòng đời TCP listener của Pairing Host.
///
/// Tách khỏi `PairingManager` để tách bạch hai mối quan tâm:
///  1. *Listener có thật sự nhận được kết nối không* (file này),
///  2. *Pairing handshake có hợp lệ không* (`PairingManager`).
///
/// Bất biến:
/// * Chỉ báo `.listening` khi `NWListener` phát `.ready` — có port thật.
/// * Bind vào **địa chỉ tunnel đã xác minh** (`NetworkUtils` + `TunnelResolver`),
///   không bind mù `10.7.0.1`.
/// * Mọi callback mang `generation`; callback của listener cũ bị bỏ qua.
/// * Không tạo listener thứ hai khi đang giữ một listener; mọi object cũ được
///   `cancel()` trước khi tạo mới.
/// * Timeout + retry có giới hạn, không bao giờ loop vô hạn.
final class TunnelListenerManager: ObservableObject {
    static let shared = TunnelListenerManager()

    @Published private(set) var state: ListenerState = .stopped
    @Published private(set) var port: UInt16?
    @Published private(set) var boundAddress: String?
    @Published private(set) var boundInterface: String?
    @Published private(set) var lastFailure: ListenerFailure?
    @Published private(set) var acceptedConnectionCount: Int = 0
    @Published private(set) var isAccepting = false

    /// Thời gian tối đa chờ `NWListener` đạt `.ready` trước khi coi là thất bại.
    var listenTimeout: TimeInterval = 6
    /// Thời gian tối đa chờ tunnel xuất hiện (khi được yêu cầu chờ).
    var tunnelTimeout: TimeInterval = 5

    /// Listener hiện tại (chỉ để `BonjourAdvertiser` gắn service).
    /// Chỉ trả về listener đã đạt `.ready` — không bao giờ trả object đã cancel.
    var currentListener: NWListener? {
        guard machine.state == .listening || machine.state == .acceptingConnections else {
            return nil
        }
        return listener
    }

    /// Được gọi khi có kết nối TCP mới *đã sẵn sàng* (`.ready`).
    /// `PairingManager` gắn handshake vào đây.
    var onReadyConnection: ((NWConnection) -> Void)?
    /// Được gọi mỗi khi state đổi (dùng để log/publish).
    var onStateChange: ((ListenerState, ListenerFailure?) -> Void)?

    private let queue = DispatchQueue(label: "com.wqterm.tunnel.listener", qos: .userInitiated)
    private let machine: ListenerStateMachine
    private var listener: NWListener?
    private var generation: UInt64 = 0
    private var waitTimer: DispatchWorkItem?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tunnelObserver: NSObjectProtocol?

    private init() {
        self.machine = ListenerStateMachine(maxAttempts: 3)
        // Block-based observer: không cần @objc/#selector (hoạt động cả khi
        // Objective-C interop bị tắt, và không giữ vòng tham chiếu tới self).
        tunnelObserver = NotificationCenter.default.addObserver(
            forName: .wqTunnelDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleTunnelChange()
        }
    }

    deinit {
        if let tunnelObserver { NotificationCenter.default.removeObserver(tunnelObserver) }
    }

    // MARK: - Public

    /// Bắt đầu listener. Trả về `false` khi không thể bắt đầu (kèm `lastFailure`).
    /// - Parameters:
    ///   - requireTunnel: nếu `true`, chờ tunnel xuất hiện tới `tunnelTimeout`.
    ///   - allowCandidateAdoption: chỉ `true` khi người dùng đã xác nhận địa chỉ
    ///     ứng viên (không tự đoán IP).
    @discardableResult
    func start(requireTunnel: Bool = true, allowCandidateAdoption: Bool = false) -> Bool {
        queue.async { [self] in
            startLocked(requireTunnel: requireTunnel, allowCandidateAdoption: allowCandidateAdoption)
        }
        return true
    }

    /// Dừng listener và đóng mọi connection. An toàn khi gọi nhiều lần.
    func stop(reason: String? = nil) {
        queue.async { [self] in
            stopLocked(logReason: reason)
        }
    }

    /// Khởi động lại: đóng sạch rồi mở lại từ STOPPED (reset retry counter).
    func restart(reason: String) {
        queue.async { [self] in
            stopLocked(logReason: reason)
            machine.resetAttempts()
            startLocked(requireTunnel: true, allowCandidateAdoption: false)
        }
    }

    /// Xác nhận địa chỉ ứng viên rồi restart — dùng sau khi người dùng đồng ý.
    func adoptCandidate(_ candidate: TunnelCandidate) {
        guard TunnelConfiguration.shared.confirm(address: candidate.address) else {
            queue.async { [self] in
                publishFailure(ListenerFailure(
                    code: .invalidAddress,
                    message: "Không xác nhận được \(candidate.address)",
                    recovery: "Chỉ xác nhận được địa chỉ IPv4 riêng (RFC1918/CGNAT)."
                ))
            }
            return
        }
        restart(reason: "Xác nhận địa chỉ tunnel \(candidate.address)")
    }

    // MARK: - Start / stop (luôn chạy trên `queue`)

    private func startLocked(requireTunnel: Bool, allowCandidateAdoption: Bool) {
        // Không bao giờ tạo listener trùng khi đang giữ một listener.
        if listener != nil || machine.state.holdsListener {
            PairingLogger.shared.log(.warn, stage: "LISTENER",
                                     "Bỏ qua start — đang \(machine.state.rawValue)")
            return
        }
        guard machine.beginAttempt() else {
            publishFailure(machine.lastFailure ?? ListenerFailure(
                code: .retryExhausted,
                message: "Hết lượt thử listener",
                recovery: "Bấm Khởi động lại sau khi kiểm tra LocalDevVPN."
            ))
            return
        }
        generation &+= 1
        let gen = generation

        transitionLocked(.initializing)
        PairingLogger.shared.log(.info, stage: "LISTENER",
                                 "Bắt đầu (attempt \(machine.attempt)/\(machine.maxAttempts))")

        transitionLocked(.waitingForTunnel)
        let topology = NetworkUtils.captureTopology()
        switch resolveHost(topology: topology, allowCandidateAdoption: allowCandidateAdoption) {
        case let .success(host):
            transitionLocked(.validatingAddress)
            validateAndBind(host: host, topology: topology, gen: gen)
        case let .failure(failure):
            if requireTunnel, failure.code == .noTunnel {
                waitForTunnel(gen: gen, timeout: tunnelTimeout) { [weak self] in
                    self?.startLocked(requireTunnel: false, allowCandidateAdoption: allowCandidateAdoption)
                } onTimeout: { [weak self] in
                    self?.handleFailureLocked(failure, gen: gen)
                }
            } else {
                handleFailureLocked(failure, gen: gen)
            }
        }
    }

    /// Quyết định địa chỉ bind từ kết quả phân giải — không bao giờ tự đổi IP.
    private func resolveHost(topology: NetworkUtils.Topology,
                             allowCandidateAdoption: Bool) -> Result<(address: String, interface: String?), ListenerFailure> {
        switch topology.resolution {
        case let .active(address, interface, _, _):
            return .success((address, interface))
        case let .candidateAvailable(candidates):
            guard let first = candidates.first else {
                return .failure(ListenerFailure(
                    code: .noUsableAddress,
                    message: "Không có ứng viên địa chỉ tunnel",
                    recovery: "Bật LocalDevVPN rồi thử lại."
                ))
            }
            if allowCandidateAdoption {
                return .success((first.address, first.interface))
            }
            let list = candidates.map(\.summary).joined(separator: ", ")
            return .failure(ListenerFailure(
                code: .addressNotConfirmed,
                message: "Địa chỉ cấu hình \(TunnelConfiguration.shared.preferredAddress) "
                    + "không có trên tunnel. Ứng viên thực tế: \(list)",
                recovery: "Chạy Kiểm tra kết nối rồi bấm \"Dùng địa chỉ này\" để xác nhận "
                    + "(không tự đổi IP)."
            ))
        case let .noUsableAddress(names, rejections):
            return .failure(ListenerFailure(
                code: .noUsableAddress,
                message: "Interface \(names.joined(separator: ", ")) không có địa chỉ dùng được: "
                    + rejections.joined(separator: "; "),
                recovery: "LocalDevVPN phải tạo tunnel point-to-point với địa chỉ riêng "
                    + "(vd 10.x). ipsec*/utun* hệ thống không được tính."
            ))
        case .noTunnelInterface:
            return .failure(ListenerFailure(
                code: .noTunnel,
                message: "Chưa có interface tunnel nào (LocalDevVPN chưa bật)",
                recovery: "Bật LocalDevVPN trong app cung cấp tunnel rồi thử lại."
            ))
        }
    }

    /// Kiểm tra địa chỉ trước khi bind (tồn tại thật, không trùng IP khác) rồi tạo listener.
    private func validateAndBind(host: (address: String, interface: String?),
                                 topology: NetworkUtils.Topology,
                                 gen: UInt64) {
        guard IPv4.parse(host.address) != nil else {
            handleFailureLocked(ListenerFailure(
                code: .invalidAddress,
                message: "Địa chỉ bind không hợp lệ: \(host.address)",
                recovery: "Đặt lại cấu hình tunnel về giá trị hợp lệ."
            ), gen: gen)
            return
        }

        // Địa chỉ phải thực sự nằm trên interface tunnel đang hoạt động.
        let onTunnel = topology.interfaces.contains {
            $0.address == host.address && $0.kind.isTunnel && $0.isUp && $0.isRunning
        }
        guard onTunnel else {
            handleFailureLocked(ListenerFailure(
                code: .addressNotAvailable,
                message: "\(host.address) không còn trên interface tunnel",
                recovery: "Tunnel vừa thay đổi — chờ LocalDevVPN ổn định rồi thử lại."
            ), gen: gen)
            return
        }

        // Xung đột IP: cùng địa chỉ trên interface khác (không phải tunnel này).
        if NetworkUtils.isAddressInUseOnDevice(host.address, excluding: host.interface) {
            PairingLogger.shared.log(.warn, stage: "LISTENER",
                                     "Địa chỉ \(host.address) cũng xuất hiện trên interface khác",
                                     detail: topology.tunnelDetail)
        }

        transitionLocked(.startingListener)

        let config = TunnelConfiguration.shared
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false      // pairing là unicast TCP, không cần P2P
        parameters.allowLocalEndpointReuse = true  // restart nhanh mà không EADDRINUSE
        parameters.requiredInterfaceType = .other  // ưu tiên interface tunnel, không ép Wi-Fi

        let requested = config.listenerPort
        let port: NWEndpoint.Port? = requested == 0 ? nil : NWEndpoint.Port(rawValue: requested)

        let newListener: NWListener
        do {
            if let port {
                newListener = try NWListener(using: parameters, on: port)
            } else {
                newListener = try NWListener(using: parameters)
            }
        } catch {
            handleFailureLocked(bindFailure(error, port: requested), gen: gen)
            return
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == gen else {
                newListener.cancel()
                return
            }
            self.listenerStateChanged(state, listener: newListener, address: host.address,
                                      interface: host.interface, gen: gen)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.generation == gen else {
                connection.cancel()
                return
            }
            self.handleNewConnection(connection, gen: gen)
        }

        listener = newListener
        newListener.start(queue: queue)
        scheduleListenTimeout(gen: gen, address: host.address, port: requested)
    }

    private func listenerStateChanged(_ state: NWListener.State,
                                      listener newListener: NWListener,
                                      address: String,
                                      interface: String?,
                                      gen: UInt64) {
        switch state {
        case .setup:
            PairingLogger.shared.log(.info, stage: "LISTENER", "NWListener .setup")
        case .waiting(let error):
            // Đây là lý do "TCP listener: STOPPED" cũ: bind vào địa chỉ không tồn tại
            // khiến listener kẹt ở .waiting vĩnh viễn mà không ai báo lỗi.
            let failure = mapWaitingError(error, address: address)
            publishFailure(failure)
            PairingLogger.shared.log(.warn, stage: "LISTENER",
                                     "NWListener .waiting: \(failure.code.rawValue)",
                                     detail: failure.message)
            // Không đợi vô hạn: .waiting kéo dài quá timeout sẽ bị xử lý.
        case .ready:
            guard let actualPort = newListener.port?.rawValue else {
                handleFailureLocked(ListenerFailure(
                    code: .portUnavailable,
                    message: "Listener ready nhưng không có port",
                    recovery: "Đặt port listener = 0 (tự động) rồi thử lại."
                ), gen: gen)
                return
            }
            waitTimer?.cancel()
            waitTimer = nil
            port = actualPort
            boundAddress = address
            boundInterface = interface
            transitionLocked(.listening)
            PairingLogger.shared.log(.info, stage: "LISTENER",
                                     "NWListener ready", detail: "\(address):\(actualPort) @ \(interface ?? "?") — "
                                        + "giao thức TCP, chưa có kết nối")
        case .failed(let error):
            handleFailureLocked(mapListenerError(error, address: address), gen: gen)
        case .cancelled:
            PairingLogger.shared.log(.info, stage: "LISTENER", "NWListener .cancelled")
            if generation == gen {
                transitionLocked(.stopping)
                transitionLocked(.stopped)
            }
        @unknown default:
            PairingLogger.shared.log(.warn, stage: "LISTENER", "NWListener state lạ: \(state)")
        }
    }

    /// Kết nối mới: chỉ gắn handler, KHÔNG báo pairing thành công ở đây.
    private func handleNewConnection(_ connection: NWConnection, gen: UInt64) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == gen else {
                connection.cancel()
                return
            }
            switch state {
            case .ready:
                self.acceptedConnectionCount += 1
                self.isAccepting = true
                if self.machine.state == .listening {
                    self.transitionLocked(.acceptingConnections)
                }
                PairingLogger.shared.log(.info, stage: "TCP",
                                         "Kết nối TCP đã ready (#\(self.acceptedConnectionCount))",
                                         detail: "pending=\(self.connections.count)")
                self.onReadyConnection?(connection)
            case .failed(let error):
                PairingLogger.shared.log(.warn, stage: "TCP",
                                         "Kết nối lỗi: \(error.localizedDescription)",
                                         detail: TunnelListenerManager.errorCode(error))
                self.drop(connection)
            case .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func drop(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        if connections.removeValue(forKey: key) != nil {
            connection.cancel()
        }
    }

    // MARK: - Timeout / recovery

    private func scheduleListenTimeout(gen: UInt64, address: String, port: UInt16) {
        waitTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, !self.machine.state.isAccepting,
                  self.machine.state != .listening else { return }
            self.handleFailureLocked(ListenerFailure(
                code: .waitingTimeout,
                message: "Listener không đạt .ready trong \(Int(self.listenTimeout))s "
                    + "(bind \(address):\(port))",
                recovery: "Địa chỉ tunnel có thể chưa sẵn sàng hoặc bị xung đột. "
                    + "Kiểm tra lại đường tunnel rồi khởi động lại listener."
            ), gen: gen)
        }
        waitTimer = work
        queue.asyncAfter(deadline: .now() + listenTimeout, execute: work)
    }

    /// Chờ tunnel xuất hiện (được gọi lại chính xác một lần khi có/không có).
    private func waitForTunnel(gen: UInt64, timeout: TimeInterval,
                               onAppear: @escaping () -> Void,
                               onTimeout: @escaping () -> Void) {
        PairingLogger.shared.log(.info, stage: "LISTENER",
                                 "Chờ tunnel xuất hiện (tối đa \(Int(timeout))s)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            if NetworkUtils.isLocalDevVPNActive {
                onAppear()
            } else {
                onTimeout()
            }
        }
        waitTimer?.cancel()
        waitTimer = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func handleFailureLocked(_ failure: ListenerFailure, gen: UInt64) {
        guard generation == gen else { return }
        lastFailure = failure
        cancelListenerObjects()
        PairingLogger.shared.log(.error, stage: "LISTENER",
                                 "\(failure.code.rawValue): \(failure.message)",
                                 detail: failure.recovery)

        // Retry chỉ khi còn lượt: không bao giờ retry vô hạn.
        if machine.attempt < machine.maxAttempts, machine.enterRecovery(failure: failure) {
            transitionLocked(.recovering)
            let delay = 1.0 * Double(machine.attempt)
            PairingLogger.shared.log(.warn, stage: "LISTENER",
                                     "Thử lại sau \(delay)s (\(machine.attempt)/\(machine.maxAttempts))")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.startLocked(requireTunnel: true, allowCandidateAdoption: false)
            }
        } else {
            machine.fail(failure)
            transitionLocked(.failed)
        }
    }

    private func stopLocked(logReason: String?) {
        generation &+= 1
        waitTimer?.cancel()
        waitTimer = nil
        cancelListenerObjects()
        machine.forceStop()
        port = nil
        boundAddress = nil
        boundInterface = nil
        isAccepting = false
        acceptedConnectionCount = 0
        publish(state: .stopped, failure: nil)
        if let logReason {
            PairingLogger.shared.log(.info, stage: "LISTENER", "Đã dừng", detail: logReason)
        }
    }

    /// Huỷ listener + mọi connection. Không giữ object đã cancel để tái sử dụng.
    private func cancelListenerObjects() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Publishing

    private func transitionLocked(_ next: ListenerState) {
        guard machine.transition(to: next) else {
            if let failure = machine.lastFailure {
                PairingLogger.shared.log(.error, stage: "LISTENER",
                                         "Transition bị từ chối: \(failure.message)")
            }
            return
        }
        publish(state: machine.state, failure: nil)
    }

    private func publishFailure(_ failure: ListenerFailure) {
        lastFailure = failure
        DispatchQueue.main.async { [weak self] in
            self?.lastFailure = failure
        }
    }

    private func publish(state: ListenerState, failure: ListenerFailure?) {
        let handler = onStateChange
        let portValue = port
        let address = boundAddress
        let interface = boundInterface
        let failureValue = failure ?? lastFailure
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = state
            self.port = portValue
            self.boundAddress = address
            self.boundInterface = interface
            if let failureValue { self.lastFailure = failureValue }
            handler?(state, failureValue)
        }
    }

    private func handleTunnelChange() {
        queue.async { [self] in
            guard machine.state.holdsListener || machine.state == .recovering else { return }
            let resolution = NetworkUtils.captureTopology().resolution
            switch resolution {
            case let .active(address, _, _, _):
                // Tunnel đổi địa chỉ/interface ⇒ listener cũ bind sai chỗ, phải dựng lại.
                if let current = boundAddress, current != address {
                    restart(reason: "Địa chỉ tunnel đổi \(current) → \(address)")
                }
            default:
                restart(reason: "Tunnel mất — dựng lại listener khi tunnel trở lại")
            }
        }
    }

    // MARK: - Error mapping

    private func bindFailure(_ error: Error, port: UInt16) -> ListenerFailure {
        let nsError = error as NSError
        let posix = Int32(nsError.code)
        let code: ListenerErrorCode
        switch posix {
        case EADDRNOTAVAIL: code = .addressNotAvailable
        case EADDRINUSE: code = .addressInUse
        case EACCES, EPERM: code = .permissionDenied
        default: code = .bindFailed
        }
        return ListenerFailure(code: code,
                               message: "Không tạo được NWListener: \(error.localizedDescription)",
                               recovery: recoveryText(for: code, port: port),
                               posixCode: posix)
    }

    private func mapWaitingError(_ error: NWError, address: String) -> ListenerFailure {
        let posix = posixCode(of: error)
        let code: ListenerErrorCode
        switch posix {
        case EADDRNOTAVAIL: code = .addressNotAvailable
        case EADDRINUSE: code = .addressInUse
        case EACCES, EPERM: code = .permissionDenied
        default: code = .waitingTimeout
        }
        return ListenerFailure(code: code,
                               message: "Listener đang chờ: \(error.localizedDescription) "
                                   + "(bind \(address))",
                               recovery: recoveryText(for: code, port: TunnelConfiguration.shared.listenerPort),
                               posixCode: posix)
    }

    private func mapListenerError(_ error: NWError, address: String) -> ListenerFailure {
        let posix = posixCode(of: error)
        let code: ListenerErrorCode
        switch posix {
        case EADDRNOTAVAIL: code = .addressNotAvailable
        case EADDRINUSE: code = .addressInUse
        case EACCES, EPERM: code = .permissionDenied
        default: code = .bindFailed
        }
        return ListenerFailure(code: code,
                               message: "Listener thất bại: \(error.localizedDescription)",
                               recovery: recoveryText(for: code, port: TunnelConfiguration.shared.listenerPort),
                               posixCode: posix)
    }

    private func recoveryText(for code: ListenerErrorCode, port: UInt16) -> String {
        switch code {
        case .addressNotAvailable:
            return "Địa chỉ bind không còn trên tunnel. Bật lại LocalDevVPN hoặc xác nhận "
                + "địa chỉ tunnel thực tế trong Kiểm tra kết nối."
        case .addressInUse:
            return "Port \(port) đang bị chiếm. Đặt port listener về 0 (tự động)."
        case .permissionDenied:
            return "Thiếu quyền Mạng nội bộ. Cấp quyền trong Cài đặt iPhone › WQTerm."
        default:
            return "Kiểm tra LocalDevVPN và khởi động lại listener."
        }
    }

    static func errorCode(_ error: NWError) -> String {
        "\(error)"
    }

    private func posixCode(of error: NWError) -> Int32? {
        if case let .posix(code) = error { return code.rawValue }
        return nil
    }
}
