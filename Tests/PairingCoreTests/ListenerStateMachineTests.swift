import XCTest
@testable import PairingCore

/// Kiểm thử state machine của listener: không báo LISTENING khi chưa ready,
/// không retry vô hạn, không tái sử dụng listener đã cancel.
final class ListenerStateMachineTests: XCTestCase {

    func testHappyPathFollowsRequiredOrder() {
        let machine = ListenerStateMachine(maxAttempts: 3)
        XCTAssertTrue(machine.beginAttempt())
        XCTAssertTrue(machine.transition(to: .initializing))
        XCTAssertTrue(machine.transition(to: .waitingForTunnel))
        XCTAssertTrue(machine.transition(to: .validatingAddress))
        XCTAssertTrue(machine.transition(to: .startingListener))
        XCTAssertTrue(machine.transition(to: .listening))
        XCTAssertTrue(machine.transition(to: .acceptingConnections))
        XCTAssertEqual(machine.state, .acceptingConnections)
    }

    /// Không được nhảy thẳng sang LISTENING: đây chính là kiểu "báo LISTENING giả".
    func testCannotJumpStraightToListening() {
        let machine = ListenerStateMachine()
        XCTAssertTrue(machine.transition(to: .initializing))
        XCTAssertFalse(machine.transition(to: .listening))
        XCTAssertEqual(machine.state, .initializing)
        XCTAssertEqual(machine.lastFailure?.code, .invalidTransition)
    }

    func testCannotSkipTunnelValidation() {
        let machine = ListenerStateMachine()
        _ = machine.transition(to: .initializing)
        _ = machine.transition(to: .waitingForTunnel)
        XCTAssertFalse(machine.transition(to: .startingListener))
        XCTAssertEqual(machine.state, .waitingForTunnel)
    }

    func testRetryIsBoundedByMaxAttempts() {
        let machine = ListenerStateMachine(maxAttempts: 2)
        XCTAssertTrue(machine.beginAttempt())
        XCTAssertTrue(machine.beginAttempt())
        XCTAssertFalse(machine.beginAttempt(), "lần thứ 3 phải bị chặn")
        XCTAssertEqual(machine.attempt, 2)
        XCTAssertEqual(machine.lastFailure?.code, .retryExhausted)
    }

    func testRecoveryThenInitializeIsAllowed() {
        let machine = ListenerStateMachine(maxAttempts: 3)
        _ = machine.beginAttempt()
        _ = machine.transition(to: .initializing)
        _ = machine.transition(to: .waitingForTunnel)
        let failure = ListenerFailure(code: .waitingTimeout,
                                      message: "timeout",
                                      recovery: "retry")
        XCTAssertTrue(machine.enterRecovery(failure: failure))
        XCTAssertEqual(machine.state, .recovering)
        XCTAssertTrue(machine.transition(to: .initializing))
    }

    func testForceStopAlwaysLandsOnStopped() {
        let machine = ListenerStateMachine()
        _ = machine.transition(to: .initializing)
        _ = machine.transition(to: .waitingForTunnel)
        machine.forceStop()
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertNil(machine.lastFailure)
        XCTAssertTrue(machine.history.contains(.stopping))
    }

    func testHoldsListenerFlagsOnlyForLiveStates() {
        XCTAssertFalse(ListenerState.stopped.holdsListener)
        XCTAssertFalse(ListenerState.validatingAddress.holdsListener)
        XCTAssertTrue(ListenerState.startingListener.holdsListener)
        XCTAssertTrue(ListenerState.listening.holdsListener)
        XCTAssertTrue(ListenerState.acceptingConnections.holdsListener)
        XCTAssertFalse(ListenerState.failed.holdsListener)
    }

    func testFailureAfterListeningDoesNotClaimSuccess() {
        let machine = ListenerStateMachine()
        _ = machine.transition(to: .initializing)
        _ = machine.transition(to: .waitingForTunnel)
        _ = machine.transition(to: .validatingAddress)
        _ = machine.transition(to: .startingListener)
        _ = machine.transition(to: .listening)
        XCTAssertTrue(machine.fail(ListenerFailure(code: .bindFailed,
                                                   message: "listener died",
                                                   recovery: "restart")))
        XCTAssertEqual(machine.state, .failed)
        XCTAssertFalse(machine.state.isAccepting)
    }
}
