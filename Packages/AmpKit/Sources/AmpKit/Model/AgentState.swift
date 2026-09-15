import Foundation

/// The agent's real activity state, as reported by the bridge plugin.
///
/// This mirrors the plugin API's `ThreadState`. It is **not** available over
/// the External API, so it only arrives when the bridge plugin is loaded in the
/// thread's orb. `ThreadActivity`, derived from `updatedAt`, remains the
/// fallback for threads the bridge cannot see.
public enum AgentState: String, Sendable, Codable, CaseIterable {
    case idle
    case running
    /// Blocked on a human decision. This is the state the watch exists for.
    case awaitingApproval = "awaiting-approval"
    case error
}

extension AgentState {
    /// Whether the thread cannot progress without the user.
    public var needsYou: Bool {
        switch self {
        case .awaitingApproval, .error: true
        case .idle, .running: false
        }
    }
}

/// What the watch knows about a thread: the External API's summary, plus live
/// state from the bridge when it is present.
public struct ThreadStatus: Sendable, Hashable, Identifiable {
    public let thread: ThreadSummary
    /// `nil` when the bridge plugin is not loaded in this thread's orb.
    public let agentState: AgentState?
    public let pendingApproval: PendingApproval?

    public var id: String { thread.id }

    public init(
        thread: ThreadSummary,
        agentState: AgentState? = nil,
        pendingApproval: PendingApproval? = nil
    ) {
        self.thread = thread
        self.agentState = agentState
        self.pendingApproval = pendingApproval
    }

    /// True only when the bridge actually told us so.
    ///
    /// Deliberately not inferred from `updatedAt`: claiming a thread is blocked
    /// on the user when nothing said so would send them to a screen with
    /// nothing to approve.
    public var isBlockedOnUser: Bool {
        agentState?.needsYou ?? false
    }

    /// Ranking key for the thread list: blocked threads first, then running,
    /// then by recency. Lower sorts first.
    public func rank(now: Date) -> (Int, TimeInterval) {
        let bucket: Int
        switch agentState {
        case .awaitingApproval: bucket = 0
        case .error: bucket = 1
        case .running: bucket = 2
        case .idle, nil:
            // Without bridge state, fall back to observed recency so these
            // threads interleave sensibly rather than sinking to the bottom.
            bucket = thread.activity(now: now) == .live ? 2 : 3
        }
        let age = thread.updatedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        return (bucket, age)
    }
}

extension Array where Element == ThreadStatus {
    /// Threads ordered by how much they need the user right now.
    public func rankedForWatch(now: Date) -> [ThreadStatus] {
        sorted { left, right in
            let (lb, la) = left.rank(now: now)
            let (rb, ra) = right.rank(now: now)
            return lb == rb ? la < ra : lb < rb
        }
    }

    public func blockedOnUser() -> [ThreadStatus] {
        filter(\.isBlockedOnUser)
    }
}
