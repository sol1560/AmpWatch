import XCTest
@testable import AmpKit

/// A sink that can be switched between "online" and "offline" between calls.
private final class SwitchableSink: AmpPromptSink, @unchecked Sendable {
    private let lock = NSLock()
    private var offline: Bool
    private var log: [(command: WatchCommand, key: String?)] = []

    init(offline: Bool = false) { self.offline = offline }

    var isOffline: Bool {
        get { lock.withLock { offline } }
        set { lock.withLock { offline = newValue } }
    }

    var sent: [(command: WatchCommand, key: String?)] { lock.withLock { log } }

    func send(_ command: WatchCommand, idempotencyKey: String?) async throws {
        try lock.withLock {
            if offline { throw AmpError.transport("offline") }
            log.append((command, idempotencyKey))
        }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_773_480_060)

final class DispatcherTests: XCTestCase {

    func testOnlineSubmitDeliversAndLeavesNothingQueued() async {
        let sink = SwitchableSink()
        let dispatcher = Dispatcher(outbox: Outbox(now: { t0 }), sink: sink)

        let outcome = await dispatcher.submit(.cancel(threadID: "T-1"), id: "k1", at: t0)

        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(sink.sent.map(\.key), ["k1"])
        let remaining = await dispatcher.outbox.count
        XCTAssertEqual(remaining, 0)
    }

    func testOfflineSubmitQueuesInsteadOfFailingAndReportsPosition() async {
        let sink = SwitchableSink(offline: true)
        let dispatcher = Dispatcher(outbox: Outbox(now: { t0 }), sink: sink)

        let first = await dispatcher.submit(.prompt(threadID: "T-1", text: "one", steer: true), id: "a", at: t0)
        let second = await dispatcher.submit(.prompt(threadID: "T-1", text: "two", steer: true), id: "b", at: t0)

        XCTAssertEqual(first, .queued(behind: 0))
        // The second prompt must wait for the first; a UI saying "sent" here
        // would be lying.
        XCTAssertEqual(second, .queued(behind: 1))
        XCTAssertTrue(sink.sent.isEmpty)
    }

    func testReconnectFlushDeliversQueuedItemsInOrderWithTheirOriginalKeys() async {
        let sink = SwitchableSink(offline: true)
        let dispatcher = Dispatcher(outbox: Outbox(now: { t0 }), sink: sink)
        _ = await dispatcher.submit(.prompt(threadID: "T-1", text: "one", steer: true), id: "a", at: t0)
        _ = await dispatcher.submit(.prompt(threadID: "T-1", text: "two", steer: true), id: "b", at: t0)

        sink.isOffline = false
        let result = await dispatcher.flush()

        XCTAssertEqual(result.delivered, ["a", "b"])
        // The idempotency key must be the queued item's id, not a fresh one per
        // attempt, or a retry after a lost 2xx double-prompts the agent.
        XCTAssertEqual(sink.sent.map(\.key), ["a", "b"])
        XCTAssertEqual(sink.sent.map(\.command), [
            .prompt(threadID: "T-1", text: "one", steer: true),
            .prompt(threadID: "T-1", text: "two", steer: true),
        ])
    }

    func testStaleDecisionIsDroppedNotDeliveredLate() async {
        let clock = Clock(t0)
        let sink = SwitchableSink(offline: true)
        let dispatcher = Dispatcher(outbox: Outbox(now: { clock.now }), sink: sink)
        let decide = WatchCommand.decide(approvalID: "TU-1", threadID: "T-1", decision: .approve)
        let queued = await dispatcher.submit(decide, id: "d", at: t0)
        XCTAssertEqual(queued, .queued(behind: 0))

        // Just past the bridge's own timeout: the held call is already gone.
        clock.now = t0.addingTimeInterval(Outbox.decisionTTL + 1)
        sink.isOffline = false
        let result = await dispatcher.flush()

        XCTAssertEqual(result.delivered, [])
        XCTAssertEqual(result.dropped.map(\.id), ["d"])
        XCTAssertEqual(result.dropped.first?.reason, .expired)
        XCTAssertTrue(sink.sent.isEmpty, "an approve delivered after the timeout could land on a later call")
    }

    func testDecisionTTLMatchesTheBridgeTimeout() {
        // `APPROVAL_TIMEOUT_MS` in Plugin/amp-watch-bridge.ts is 10 minutes.
        // If one side moves, both must.
        XCTAssertEqual(Outbox.decisionTTL, 600)
    }
}

/// A settable clock the outbox can read from a `@Sendable` closure.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
