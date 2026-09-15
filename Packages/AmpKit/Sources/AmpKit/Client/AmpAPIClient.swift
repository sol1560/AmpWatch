import Foundation

/// Supplies the bearer token for External API requests.
///
/// The External API authenticates machine-to-machine OAuth clients created at
/// ampcode.com/workspace/applications. Token acquisition is behind this
/// protocol so a long-lived workspace secret never has to live on the watch:
/// a static token works for development, and a broker can be substituted later
/// without touching the client.
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

public struct StaticAccessToken: AccessTokenProvider {
    private let token: String

    public init(_ token: String) {
        self.token = token
    }

    public func accessToken() async throws -> String { token }
}

/// Read-only client for the Amp External API v2.
public struct AmpAPIClient: AmpClient {
    public static let productionBaseURL = URL(string: "https://ampcode.com/api/v2")!

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let tokens: any AccessTokenProvider
    private let dates = DateParsing()

    public init(
        baseURL: URL = AmpAPIClient.productionBaseURL,
        transport: any HTTPTransport,
        tokens: any AccessTokenProvider
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    public func threads(limit: Int, cursor: String?) async throws -> Page<ThreadSummary> {
        let body = try await get(
            path: "threads",
            query: [("limit", String(limit)), ("cursor", cursor), ("sort", "DESC")]
        )
        let decoded = try decode(ThreadListResponse.self, from: body)
        return Page(items: decoded.threads, nextCursor: decoded.nextCursor)
    }

    public func messages(threadID: String, limit: Int, cursor: String?) async throws -> Page<ThreadMessage> {
        let body = try await get(
            path: "threads/\(threadID)/messages",
            query: [("limit", String(limit)), ("cursor", cursor)]
        )
        let decoded = try decode(MessageListResponse.self, from: body)
        let messages = decoded.messages.enumerated().map { index, value in
            ThreadMessage.extract(from: value, index: index, dates: dates)
        }
        return Page(items: messages, nextCursor: decoded.nextCursor)
    }

    public func usage(threadID: String) async throws -> ThreadUsage {
        let body = try await get(path: "threads/\(threadID)/usage", query: [])
        return try decode(ThreadUsage.self, from: body)
    }

    // MARK: - Plumbing

    private func get(path: String, query: [(String, String?)]) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        let items = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        components?.queryItems = items.isEmpty ? nil : items

        guard let url = components?.url else {
            throw AmpError.transport("Could not build URL for \(path)")
        }

        let request = HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(try await tokens.accessToken())",
                "Accept": "application/json",
            ]
        )

        let response = try await transport.send(request)
        if let error = AmpError.from(response: response) { throw error }
        return response.body
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dates.decodingStrategy
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AmpError.decoding(String(describing: error))
        }
    }

    private struct ThreadListResponse: Decodable {
        let nextCursor: String?
        let threads: [ThreadSummary]
    }

    private struct MessageListResponse: Decodable {
        let nextCursor: String?
        let messages: [JSONValue]

        private enum CodingKeys: String, CodingKey { case nextCursor, messages }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            // The API's own example shows `messages: [null]`.
            messages = try c.decodeIfPresent([JSONValue].self, forKey: .messages)?
                .filter { $0 != .null } ?? []
        }
    }
}
