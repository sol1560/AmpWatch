import Foundation

/// What a complication can say about Amp without a network call.
///
/// The app builds one of these every time the thread list loads and writes it
/// to the app group; the widget extension reads it back. The extension has no
/// credentials, never talks to the API, and never sees a message body — the
/// only text that crosses over is one thread title.
public struct Glance: Sendable, Equatable, Codable {
    /// Bumped when the shape changes, so an old widget reading a new file (or
    /// the reverse, mid-update) shows the placeholder rather than garbage.
    public static let currentVersion = 1
    /// After this long the numbers are a memory, not a status.
    public static let maxAge: TimeInterval = 30 * 60

    public var version: Int
    /// Threads inside the live window: probably mid-turn.
    public var live: Int
    /// Held tool calls whose notification is still waiting in Notification
    /// Center. The watch has no other record of what is waiting on it.
    public var awaiting: Int
    /// USD spent by the threads that changed today, as far as the watch knows.
    public var spentTodayUSD: Double
    /// How many of today's threads the figure above covers; the rest had no
    /// usage loaded.
    public var spentTodayThreads: Int
    /// The most recently changed live thread, for the rectangular face.
    public var headline: String?
    public var updatedAt: Date

    public init(
        version: Int = Glance.currentVersion,
        live: Int,
        awaiting: Int,
        spentTodayUSD: Double,
        spentTodayThreads: Int,
        headline: String?,
        updatedAt: Date
    ) {
        self.version = version
        self.live = live
        self.awaiting = awaiting
        self.spentTodayUSD = spentTodayUSD
        self.spentTodayThreads = spentTodayThreads
        self.headline = headline
        self.updatedAt = updatedAt
    }

    /// Reduces a loaded thread list to the numbers a face can show.
    ///
    /// "Today" is the calendar day of `now` in `calendar`, not the last 24
    /// hours: a student asking "what did I spend today" means since midnight.
    public static func make(
        threads: [ThreadSummary],
        usage: [String: ThreadUsage],
        awaiting: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> Glance {
        let live = threads
            .filter { $0.activity(now: now) == .live }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let today = threads.filter { thread in
            guard let updatedAt = thread.updatedAt else { return false }
            return calendar.isDate(updatedAt, inSameDayAs: now)
        }
        let covered = today.compactMap { usage[$0.id] }
        return Glance(
            live: live.count,
            awaiting: awaiting,
            spentTodayUSD: covered.reduce(0) { $0 + $1.usage },
            spentTodayThreads: covered.count,
            headline: live.first?.displayTitle,
            updatedAt: now
        )
    }

    public func isStale(now: Date, maxAge: TimeInterval = Glance.maxAge) -> Bool {
        now.timeIntervalSince(updatedAt) > maxAge
    }
}

/// The file the app writes and the widget reads.
///
/// Writes are atomic so a widget waking mid-write reads the previous glance,
/// not half a file. A missing file, unreadable JSON or a foreign version all
/// read as `nil`: the widget shows its placeholder and asks to be opened.
public struct GlanceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> Glance? {
        guard let data = try? Data(contentsOf: fileURL),
              let glance = try? JSONDecoder().decode(Glance.self, from: data),
              glance.version == Glance.currentVersion
        else { return nil }
        return glance
    }

    public func save(_ glance: Glance) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(glance).write(to: fileURL, options: .atomic)
    }
}
