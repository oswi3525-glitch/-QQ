import Foundation

/// Trạng thái của `TunnelListenerManager`.
///
/// Thứ tự hợp lệ (Phase 1 yêu cầu):
/// `STOPPED → INITIALIZING → WAITING_FOR_TUNNEL → VALIDATING_ADDRESS →
///  STARTING_LISTENER → LISTENING → ACCEPTING_CONNECTIONS`
/// cùng các nhánh `FAILED`, `RECOVERING`, `STOPPING`.
///
/// Quy tắc bất biến:
/// * Chỉ được báo `.listening` sau khi `NWListener.State.ready` thật sự xảy ra
///   (state machine không tự nhảy sang LISTENING).
/// * Không tái sử dụng object đã `cancel` — mọi lần start mới đều đi qua
///   `STOPPED`/`FAILED` và tăng `generation`.
enum ListenerState: String, CaseIterable {
    case stopped = "STOPPED"
    case initializing = "INITIALIZING"
    case waitingForTunnel = "WAITING_FOR_TUNNEL"
    case validatingAddress = "VALIDATING_ADDRESS"
    case startingListener = "STARTING_LISTENER"
    case listening = "LISTENING"
    case acceptingConnections = "ACCEPTING_CONNECTIONS"
    case recovering = "RECOVERING"
    case stopping = "STOPPING"
    case failed = "FAILED"

    /// Trạng thái đã thực sự nhận kết nối được (bằng chứng mạnh hơn `.listening`).
    var isAccepting: Bool { self == .acceptingConnections }

    /// Listener đang tồn tại (kể cả đang chờ) — dùng để chặn tạo trùng.
    var holdsListener: Bool {
        switch self {
        case .startingListener, .listening, .acceptingConnections:
            return true
        default:
            return false
        }
    }

    var isTerminal: Bool { self == .stopped || self == .failed }

    /// Các bước chuyển hợp lệ. Mọi chuyển khác đều bị state machine từ chối
    /// (và được log) thay vì âm thầm gán trạng thái — tránh báo LISTENING giả.
    var allowedNext: Set<ListenerState> {
        switch self {
        case .stopped:
            return [.initializing, .stopping]
        case .initializing:
            return [.waitingForTunnel, .failed, .stopping]
        case .waitingForTunnel:
            return [.validatingAddress, .failed, .stopping, .recovering]
        case .validatingAddress:
            return [.startingListener, .failed, .stopping, .recovering]
        case .startingListener:
            return [.listening, .failed, .stopping, .recovering]
        case .listening:
            return [.acceptingConnections, .failed, .stopping, .recovering]
        case .acceptingConnections:
            return [.failed, .stopping, .recovering]
        case .recovering:
            return [.stopped, .initializing, .failed, .stopping]
        case .stopping:
            return [.stopped, .failed]
        case .failed:
            return [.initializing, .stopped, .stopping]
        }
    }

    func canTransition(to next: ListenerState) -> Bool {
        allowedNext.contains(next)
    }
}

/// Mã lỗi ổn định để UI/chẩn đoán hiển thị (không phụ thuộc chuỗi localizedDescription).
enum ListenerErrorCode: String {
    case noTunnel = "E_NO_TUNNEL"
    case noUsableAddress = "E_NO_USABLE_ADDRESS"
    case addressNotConfirmed = "E_ADDRESS_NOT_CONFIRMED"
    case invalidAddress = "E_INVALID_ADDRESS"
    case bindFailed = "E_BIND_FAILED"
    case addressNotAvailable = "E_ADDRNOTAVAIL"
    case permissionDenied = "E_ACCES"
    case addressInUse = "E_ADDRINUSE"
    case waitingTimeout = "E_LISTEN_WAIT_TIMEOUT"
    case portUnavailable = "E_NO_PORT"
    case invalidTransition = "E_STATE_TRANSITION"
    case cancelled = "E_CANCELLED"
    case retryExhausted = "E_RETRY_EXHAUSTED"
    case bonjourFailed = "E_BONJOUR"
}

/// Lỗi có mã + hướng khắc phục, dùng chung cho listener/Bonjour/pairing.
struct ListenerFailure: Error, Equatable {
    let code: ListenerErrorCode
    let message: String
    let recovery: String
    let posixCode: Int32?

    init(code: ListenerErrorCode, message: String, recovery: String, posixCode: Int32? = nil) {
        self.code = code
        self.message = message
        self.recovery = recovery
        self.posixCode = posixCode
    }

    var displayCode: String {
        guard let posixCode else { return code.rawValue }
        return "\(code.rawValue) (errno \(posixCode))"
    }
}

/// State machine thuần cho listener: kiểm tra transition + đếm retry có giới hạn.
/// Không giữ socket, không chạy async ⇒ kiểm thử được trên Linux.
final class ListenerStateMachine {
    private(set) var state: ListenerState = .stopped
    private(set) var lastFailure: ListenerFailure?
    private(set) var attempt: Int = 0
    private(set) var history: [ListenerState] = [.stopped]

    let maxAttempts: Int

    init(maxAttempts: Int = 3) {
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Trả về `false` nếu transition không hợp lệ (state không đổi).
    @discardableResult
    func transition(to next: ListenerState) -> Bool {
        guard state != next else { return true }
        guard state.canTransition(to: next) else {
            lastFailure = ListenerFailure(
                code: .invalidTransition,
                message: "Chuyển trạng thái không hợp lệ \(state.rawValue) → \(next.rawValue)",
                recovery: "Đặt lại listener (forceRestart) trước khi thử lại."
            )
            return false
        }
        state = next
        history.append(next)
        if next == .stopped {
            lastFailure = nil
        }
        return true
    }

    /// Bắt đầu một lần thử mới. Trả về `false` khi đã vượt giới hạn retry.
    func beginAttempt() -> Bool {
        guard attempt < maxAttempts else {
            lastFailure = ListenerFailure(
                code: .retryExhausted,
                message: "Đã thử \(attempt)/\(maxAttempts) lần — dừng để tránh vòng lặp vô hạn.",
                recovery: "Kiểm tra lại LocalDevVPN/địa chỉ tunnel rồi bấm Khởi động lại."
            )
            return false
        }
        attempt += 1
        return true
    }

    /// Retry chỉ khi state cho phép vào RECOVERING.
    @discardableResult
    func enterRecovery(failure: ListenerFailure) -> Bool {
        lastFailure = failure
        if state.canTransition(to: .recovering) {
            state = .recovering
            history.append(.recovering)
            return true
        }
        if state.canTransition(to: .failed) {
            state = .failed
            history.append(.failed)
        }
        return false
    }

    @discardableResult
    func fail(_ failure: ListenerFailure) -> Bool {
        lastFailure = failure
        guard state.canTransition(to: .failed) else { return false }
        state = .failed
        history.append(.failed)
        return true
    }

    func resetAttempts() {
        attempt = 0
    }

    /// Về STOPPED an toàn từ mọi trạng thái (dùng khi cancel/teardown).
    func forceStop() {
        if state != .stopped && state != .stopping {
            state = .stopping
            history.append(.stopping)
        }
        state = .stopped
        history.append(.stopped)
    }
}
