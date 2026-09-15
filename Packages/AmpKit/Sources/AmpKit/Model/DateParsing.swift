import Foundation

/// Parses the ISO 8601 timestamps the Amp API returns.
///
/// The documented examples use fractional seconds (`2026-01-01T00:00:00.000Z`),
/// but whole-second timestamps are valid ISO 8601 too and a parser configured
/// for one form rejects the other. Accepting both keeps a single stray
/// timestamp from failing an entire page.
///
/// Uses `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter` because
/// the format style is `Sendable`, which this type needs in order to be usable
/// from the actors that drive the watch UI.
public struct DateParsing: Sendable {
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFractionalSeconds = Date.ISO8601FormatStyle()

    public init() {}

    public func date(from string: String) -> Date? {
        if let date = try? Self.withFractionalSeconds.parse(string) { return date }
        return try? Self.withoutFractionalSeconds.parse(string)
    }

    /// A `JSONDecoder` date strategy backed by this parser.
    public var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = DateParsing().date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ISO 8601 date: \(raw)"
                )
            }
            return date
        }
    }
}
