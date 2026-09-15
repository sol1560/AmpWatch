import Foundation

/// Something the user asked for that must reach Amp eventually.
public struct OutboxItem: Sendable, Hashable, Identifiable, Codable {
    public typealias Command = WatchCommand

    public let id: String
    public let command: Command
    public let createdAt: Date
    /// Number of failed delivery attempts so far.
    public private(set) var attempts: Int

    public init(id: String, command: Command, createdAt: Date, attempts: Int = 0) {
        self.id = id
        self.command = command
        self.createdAt = createdAt
        self.attempts = attempts
    }

    func retried() -> OutboxItem {
        OutboxItem(id: id, command: command, createdAt: createdAt, attempts: attempts + 1)
    }
}

/// Why an item left the outbox without being delivered.
public enum OutboxDrop: Sendable, Equatable {
    /// Too many failed attempts.
    case exhausted
    /// The decision is no longer meaningful — the agent stopped waiting.
    case expired
}

public struct OutboxFlush: Sendable, Equatable {
    public let delivered: [String]
    public let dropped: [(id: String, reason: OutboxDrop)]
    public let remaining: Int

    public static func == (lhs: OutboxFlush, rhs: OutboxFlush) -> Bool {
        lhs.delivered == rhs.delivered
            && lhs.remaining == rhs.remaining
            && lhs.dropped.count == rhs.dropped.count
            && zip(lhs.dropped, rhs.dropped).allSatisfy { $0.id == $1.id && $0.reason == $1.reason }
    }
}

/// A durable, ordered, exactly-once-per-item queue of commands.
///
/// This exists because the watch loses its link constantly — wrist down, out of
/// Bluetooth range, captive Wi-Fi — and a prompt the user dictated must not
/// vanish, nor arrive twice because a reply was lost rather than the request.
///
/// Delivery is **in order and one at a time**. A prompt that lands out of order
/// changes what the agent does, so a parallel flush would be wrong even though
/// it would be faster.
public actor Outbox {
    /// Attempts before an item is dropped rather than retried forever.
    public static let maxAttempts = 5

    /// How long an approval stays meaningful, counted from when the bridge
    /// held the call — not from the tap. Same number as the bridge's own
    /// timeout; see `PendingApproval.decisionWindow`.
    public static let decisionTTL: TimeInterval = PendingApproval.decisionWindow

    private var items: [OutboxItem] = []
    private let now: @Sendable () -> Date
    /// The flush currently sending, if any. Actors are re-entrant at every
    /// `await`, and three things call `flush` (a timer, wrist raise, each new
    /// submit); two passes over the same queue would send an item twice and
    /// drop the one behind it. Later callers wait for this and then run.
    private var inFlight: Task<OutboxFlush, Never>?
    /// Where the queue survives an app kill. `nil` keeps it in memory only,
    /// which is what tests and screenshots want.
    private let fileURL: URL?

    public init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            // A file this app cannot read any more (older schema, corruption)
            // is worth less than a working queue; start empty rather than
            // refuse to launch.
            items = (try? JSONDecoder().decode([OutboxItem].self, from: data)) ?? []
        }
    }

    /// Writes the queue after every change, so the on-disk copy is never
    /// behind what the user was told is queued.
    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // Losing durability is bad; crashing while the user is dictating
            // is worse. The in-memory queue still delivers this session.
        }
    }

    public var pending: [OutboxItem] { items }
    public var count: Int { items.count }

    /// Enqueues a command.
    ///
    /// Re-enqueuing the same `id` replaces the existing item in place rather
    /// than appending, so a retry from a flaky UI cannot duplicate a prompt or
    /// reorder the queue.
    public func enqueue(_ item: OutboxItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        persist()
    }

    /// Enqueues `item` after removing every queued item `supersededBy` says it
    /// replaces. This is how a changed mind sends one decision rather than two
    /// contradictory ones, and how the latest arm level wins.
    public func enqueue(_ item: OutboxItem, replacing superseded: (OutboxItem) -> Bool) {
        items.removeAll { $0.id != item.id && superseded($0) }
        enqueue(item)
    }

    /// Whether two commands answer the same question, so the later one should
    /// replace the earlier in the queue.
    public static func supersedes(_ new: WatchCommand, _ old: WatchCommand) -> Bool {
        switch (new, old) {
        case let (.decide(a, _, _, _), .decide(b, _, _, _)): a == b
        case let (.arm(a, _), .arm(b, _)): a == b
        case (.register, .register): true
        default: false
        }
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Attempts delivery of every queued item, oldest first.
    ///
    /// Stops at the first failure and keeps the rest queued, preserving order.
    /// `send` must be idempotent on the item's `id`: an item whose send throws
    /// may already have been applied upstream, and is retried. Only one pass
    /// runs at a time; a call made mid-pass waits for it and then makes its
    /// own pass, so anything enqueued meanwhile still goes out.
    @discardableResult
    public func flush(_ send: @escaping @Sendable (OutboxItem) async throws -> Void) async -> OutboxFlush {
        while let running = inFlight {
            _ = await running.value
            // Whoever wakes first clears the finished pass. If only its
            // creator did, a waiter resuming before it would see the same
            // finished task, re-await it without yielding, and hold the
            // actor forever.
            if inFlight == running { inFlight = nil }
        }
        let pass = Task { await self.drain(send) }
        inFlight = pass
        let result = await pass.value
        if inFlight == pass { inFlight = nil }
        return result
    }

    private func drain(_ send: @Sendable (OutboxItem) async throws -> Void) async -> OutboxFlush {
        var delivered: [String] = []
        var dropped: [(id: String, reason: OutboxDrop)] = []

        // Everything below the `await` touches the queue by id, never by
        // position: while a send is out, an enqueue can replace the item
        // (same id) or supersede it (a changed mind), so index 0 may no
        // longer be the item that was sent.
        while let item = items.first {
            if isExpired(item) {
                items.removeAll { $0.id == item.id }
                dropped.append((item.id, .expired))
                persist()
                continue
            }

            do {
                try await send(item)
                // The queue on disk must forget this before anything else
                // happens: a kill here would otherwise re-send it on launch.
                items.removeAll { $0.id == item.id }
                delivered.append(item.id)
                persist()
            } catch {
                // No link is not a strike against the item; only a reply
                // that says "no" counts, or the poison would be dropped
                // while the user is still in the stairwell.
                if (error as? AmpError)?.isRetryable == true { break }
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                let retried = items[index].retried()
                if retried.attempts >= Self.maxAttempts {
                    items.remove(at: index)
                    dropped.append((item.id, .exhausted))
                    persist()
                    // A poison item must not block the queue behind it.
                    continue
                }
                items[index] = retried
                persist()
                break
            }
        }

        return OutboxFlush(delivered: delivered, dropped: dropped, remaining: items.count)
    }

    private func isExpired(_ item: OutboxItem) -> Bool {
        guard case let .decide(_, _, _, requestedAt) = item.command else { return false }
        return now() > requestedAt.addingTimeInterval(Self.decisionTTL)
    }
}
