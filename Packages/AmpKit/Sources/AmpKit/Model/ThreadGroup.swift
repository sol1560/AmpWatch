import Foundation

/// Repository grouping for one fetched page, not Amp project membership.
/// A multi-repository thread appears once, under its first repository.
public struct ThreadGroup: Identifiable, Sendable {
    public let repository: Repository?
    public let threads: [ThreadSummary]

    public var id: String? { repository?.url }
    public var title: String { repository?.shortName ?? "Repository unavailable" }

    public static func grouped(_ threads: [ThreadSummary]) -> [ThreadGroup] {
        // Do not group on shortName: different hosts can share owner/repo.
        let buckets = Dictionary(grouping: threads) { $0.repositories.first?.url }
        return buckets.values.map { items in
            let sorted = items.sorted(by: newestFirst)
            return ThreadGroup(repository: sorted[0].repositories.first, threads: sorted)
        }.sorted { newestFirst($0.threads[0], $1.threads[0]) }
    }

    private static func newestFirst(_ lhs: ThreadSummary, _ rhs: ThreadSummary) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        return lhs.id < rhs.id
    }
}
