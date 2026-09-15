import Foundation

/// How recently a thread changed.
///
/// The Amp External API does not expose the agent's run state (the plugin API's
/// `idle | running | awaiting-approval | error` is not available over HTTP), so
/// this is deliberately named after what it actually measures: the age of
/// `updatedAt`. It is an approximation of "is my agent still working", and the
/// UI must not present it as an authoritative run state.
public enum ThreadActivity: String, Sendable, CaseIterable {
    /// Changed within the live window — almost certainly mid-turn.
    case live
    /// Changed within the recent window — probably just finished.
    case recent
    /// Quiet for longer than the recent window.
    case dormant
    /// No `updatedAt` was returned.
    case unknown
}

extension ThreadActivity {
    public static let defaultLiveWindow: TimeInterval = 90
    public static let defaultRecentWindow: TimeInterval = 15 * 60

    /// Classifies a thread by how long ago it was updated.
    ///
    /// A timestamp in the future (client/server clock skew) counts as `.live`
    /// rather than falling through to `.dormant`.
    public static func derive(
        updatedAt: Date?,
        now: Date,
        liveWindow: TimeInterval = defaultLiveWindow,
        recentWindow: TimeInterval = defaultRecentWindow
    ) -> ThreadActivity {
        guard let updatedAt else { return .unknown }
        let age = now.timeIntervalSince(updatedAt)
        if age < liveWindow { return .live }
        if age < recentWindow { return .recent }
        return .dormant
    }
}

extension ThreadSummary {
    public func activity(
        now: Date,
        liveWindow: TimeInterval = ThreadActivity.defaultLiveWindow,
        recentWindow: TimeInterval = ThreadActivity.defaultRecentWindow
    ) -> ThreadActivity {
        ThreadActivity.derive(
            updatedAt: updatedAt,
            now: now,
            liveWindow: liveWindow,
            recentWindow: recentWindow
        )
    }
}
