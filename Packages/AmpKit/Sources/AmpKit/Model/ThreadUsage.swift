import Foundation

/// Per-model cost and token breakdown for a thread.
public struct ModelUsage: Sendable, Equatable, Codable {
    public let provider: String
    public let model: String
    public let requests: Double
    public let inputTokens: Double
    public let outputTokens: Double
    public let cacheReadInputTokens: Double
    public let cacheCreationInputTokens: Double
    public let usage: Double

    public init(
        provider: String,
        model: String,
        requests: Double = 0,
        inputTokens: Double = 0,
        outputTokens: Double = 0,
        cacheReadInputTokens: Double = 0,
        cacheCreationInputTokens: Double = 0,
        usage: Double = 0
    ) {
        self.provider = provider
        self.model = model
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.usage = usage
    }
}

/// `GET /api/v2/threads/{threadID}/usage`.
///
/// `estimatedProviderCostAtListPriceUSD` is deliberately not modelled: the API
/// marks it EXPERIMENTAL and tells integrators not to rely on it.
public struct ThreadUsage: Sendable, Equatable, Codable {
    public let threadID: String
    public let subThreadIDs: [String]
    /// Total thread cost in USD.
    public let usage: Double
    public let models: [ModelUsage]

    public init(threadID: String, subThreadIDs: [String] = [], usage: Double = 0, models: [ModelUsage] = []) {
        self.threadID = threadID
        self.subThreadIDs = subThreadIDs
        self.usage = usage
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case threadID, subThreadIDs, usage, models
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try c.decode(String.self, forKey: .threadID)
        subThreadIDs = try c.decodeIfPresent([String].self, forKey: .subThreadIDs) ?? []
        usage = try c.decodeIfPresent(Double.self, forKey: .usage) ?? 0
        models = try c.decodeIfPresent([ModelUsage].self, forKey: .models) ?? []
    }

    /// Models ordered by spend, which is what a 40mm screen should show first.
    public var modelsByCost: [ModelUsage] {
        models.sorted { $0.usage > $1.usage }
    }
}
