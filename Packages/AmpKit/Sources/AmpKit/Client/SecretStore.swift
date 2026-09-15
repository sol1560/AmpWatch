import Foundation

/// The secrets the watch holds. Each is a credential in its own right:
/// the token reads the workspace, the webhook URL writes to threads, and the
/// device token lets the bridge address this watch through APNs.
public enum SecretKey: String, CaseIterable, Sendable {
    case accessToken = "access-token"
    case webhookURL = "webhook-url"
    case deviceToken = "device-token"
}

/// Where secrets live. The watch app backs this with the Keychain; tests and
/// the screenshot harness use `InMemorySecretStore`.
///
/// Values are strings rather than typed because every consumer needs to cope
/// with a missing or malformed value anyway (the user typed it on a watch).
/// `AmpSession` does the parsing once, in one place.
public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    /// `nil` removes the secret.
    func write(_ value: String?, for key: SecretKey) throws
}

extension SecretStore {
    public func removeAll() throws {
        for key in SecretKey.allCases {
            try write(nil, for: key)
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String]

    public init(_ values: [SecretKey: String] = [:]) {
        self.values = values
    }

    public func read(_ key: SecretKey) throws -> String? {
        lock.withLock { values[key] }
    }

    public func write(_ value: String?, for key: SecretKey) throws {
        lock.withLock { values[key] = value }
    }
}

/// How a secret is shown on screen: enough to recognise it, never enough to
/// reuse it. Screenshots of the settings screen end up in CI artifacts.
public enum SecretDisplay {
    public static func masked(_ secret: String, visibleSuffix: Int = 4) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > visibleSuffix else { return String(repeating: "•", count: trimmed.count) }
        return "…" + trimmed.suffix(visibleSuffix)
    }

    /// Webhook URLs are capability URLs; even the host is worth hiding less
    /// than the path, so show host only.
    public static func maskedURL(_ url: URL) -> String {
        url.host ?? "set"
    }
}
