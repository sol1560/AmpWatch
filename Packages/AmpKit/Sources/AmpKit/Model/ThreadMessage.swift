import Foundation

/// One message in a thread, extracted defensively from an unstable payload.
///
/// Only `id`, `version` and `createdAt` come from documented-stable fields.
/// `role` and `text` are best-effort: when the server changes its message shape
/// they degrade to `.unknown` / `nil` instead of failing the whole page.
public struct ThreadMessage: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
        case system
        case unknown
    }

    public let id: String
    public let version: Int?
    public let createdAt: Date?
    public let role: Role
    public let text: String?

    public init(
        id: String,
        version: Int? = nil,
        createdAt: Date? = nil,
        role: Role = .unknown,
        text: String? = nil
    ) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
        self.role = role
        self.text = text
    }
}

extension ThreadMessage {
    /// Builds a message from a raw API payload.
    ///
    /// `index` supplies a stable synthetic identity when the payload has no
    /// `messageID`, so SwiftUI lists stay diffable instead of collapsing rows.
    public static func extract(from value: JSONValue, index: Int, dates: DateParsing) -> ThreadMessage {
        let id = value["messageID"]?.stringValue
            ?? value["id"]?.stringValue
            ?? "message-\(index)"

        let createdAt = value["createdAt"]?.stringValue.flatMap(dates.date(from:))

        let role: Role
        switch value["role"]?.stringValue {
        case "user": role = .user
        case "assistant": role = .assistant
        case "system": role = .system
        default: role = .unknown
        }

        return ThreadMessage(
            id: id,
            version: value["messageVersion"]?.intValue,
            createdAt: createdAt,
            role: role,
            text: extractText(from: value)
        )
    }

    /// Pulls human-readable text out of the shapes Amp currently emits, in
    /// priority order: a `content` array of typed blocks, a plain `content`
    /// string, then a bare `text` field. Non-text blocks (tool calls, images)
    /// are skipped rather than rendered as noise.
    static func extractText(from value: JSONValue) -> String? {
        if let blocks = value["content"]?.arrayValue {
            let parts = blocks.compactMap { block -> String? in
                if let type = block["type"]?.stringValue, type != "text" { return nil }
                return block["text"]?.stringValue ?? block.stringValue
            }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let plain = value["content"]?.stringValue ?? value["text"]?.stringValue {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
