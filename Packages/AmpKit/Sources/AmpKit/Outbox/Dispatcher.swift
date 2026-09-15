import Foundation

/// What became of one command the user just asked for.
public enum DeliveryOutcome: Sendable, Equatable {
    /// Amp accepted it.
    case delivered
    /// Saved; will be retried. `behind` is how many older items must go first.
    case queued(behind: Int)
    /// Left the queue without reaching Amp.
    case dropped(OutboxDrop)
}

/// The one way the watch sends anything: through the outbox, never around it.
///
/// Every command is written to the queue first and delivered from there, so
/// a prompt dictated in a stairwell is safe the moment the button is tapped.
/// A send that fails is not an error the user has to act on; it is a queued
/// item that the next `flush` retries.
public struct Dispatcher: Sendable {
    public let outbox: Outbox
    private let sink: any AmpPromptSink

    public init(outbox: Outbox, sink: any AmpPromptSink) {
        self.outbox = outbox
        self.sink = sink
    }

    /// Queues `command` and tries to deliver everything, oldest first.
    ///
    /// `id` is the idempotency key Amp sees, so the same user action retried
    /// after a lost reply is applied once. It defaults to a fresh UUID.
    public func submit(_ command: WatchCommand, id: String = UUID().uuidString, at now: Date = Date()) async -> DeliveryOutcome {
        if case let .decide(approvalID, threadID, decision) = command {
            await outbox.enqueueDecision(id: id, approvalID: approvalID, threadID: threadID, decision: decision)
        } else {
            await outbox.enqueue(OutboxItem(id: id, command: command, createdAt: now))
        }
        let result = await flush()
        if result.delivered.contains(id) { return .delivered }
        if let drop = result.dropped.first(where: { $0.id == id }) { return .dropped(drop.reason) }
        let pending = await outbox.pending
        let position = pending.firstIndex(where: { $0.id == id }) ?? pending.count
        return .queued(behind: position)
    }

    /// Retries whatever is waiting. Safe to call often; an empty queue is a
    /// no-op that sends nothing.
    @discardableResult
    public func flush() async -> OutboxFlush {
        await outbox.flush { item in
            try await sink.send(item.command, idempotencyKey: item.id)
        }
    }
}
