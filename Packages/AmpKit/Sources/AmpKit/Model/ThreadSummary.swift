import Foundation

/// A repository a thread started working in.
public struct Repository: Sendable, Hashable, Codable {
    public let url: String
    public let dir: String?

    public init(url: String, dir: String? = nil) {
        self.url = url
        self.dir = dir
    }

    /// `owner/repo` when the URL looks like a normal forge URL, otherwise the
    /// last path component. The API warns that normalization is not guaranteed,
    /// so this never fails — it falls back to the raw string.
    public var shortName: String {
        guard let components = URL(string: url)?.pathComponents.filter({ $0 != "/" }),
              !components.isEmpty
        else { return url }
        let trimmed = components.suffix(2).map { $0.hasSuffix(".git") ? String($0.dropLast(4)) : $0 }
        return trimmed.joined(separator: "/")
    }
}

/// A thread as returned by `GET /api/v2/threads`.
///
/// `title` and `repositories` are only populated when the access token carries
/// the `amp.api:workspace.threads.contents:view` scope, so both are optional.
public struct ThreadSummary: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let title: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let creatorUserID: String
    public let mainThreadID: String?
    public let parentThreadID: String?
    public let repositories: [Repository]
    public let subThreads: [ThreadSummary]

    public init(
        id: String,
        title: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        creatorUserID: String = "",
        mainThreadID: String? = nil,
        parentThreadID: String? = nil,
        repositories: [Repository] = [],
        subThreads: [ThreadSummary] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.creatorUserID = creatorUserID
        self.mainThreadID = mainThreadID
        self.parentThreadID = parentThreadID
        self.repositories = repositories
        self.subThreads = subThreads
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, creatorUserID
        case mainThreadID, parentThreadID, repositories, subThreads
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        creatorUserID = try c.decodeIfPresent(String.self, forKey: .creatorUserID) ?? ""
        mainThreadID = try c.decodeIfPresent(String.self, forKey: .mainThreadID)
        parentThreadID = try c.decodeIfPresent(String.self, forKey: .parentThreadID)
        // The API models nested arrays as nullable in its examples.
        repositories = try c.decodeIfPresent([Repository?].self, forKey: .repositories)?
            .compactMap { $0 } ?? []
        subThreads = try c.decodeIfPresent([ThreadSummary?].self, forKey: .subThreads)?
            .compactMap { $0 } ?? []
    }

    /// What a watch face should show when the thread has no title yet.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return String(id.prefix(10))
    }
}
