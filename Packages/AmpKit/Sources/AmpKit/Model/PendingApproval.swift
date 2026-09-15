import Foundation

/// A tool call waiting on a human decision.
///
/// The watch can approve shell commands with this, so the model carries enough
/// information for the UI to refuse to render a decision the user cannot
/// actually make.
public struct PendingApproval: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let threadID: String
    public let toolName: String
    /// The tool's input, rendered for display by the bridge.
    public let input: String
    /// When the bridge observed the tool call. Used to show how long the agent
    /// has been blocked, and to expire a stale approval.
    public let requestedAt: Date
    /// Whether `input` is the whole thing. The bridge sets this to false when
    /// it truncated a large payload.
    public let inputIsComplete: Bool

    public init(
        id: String,
        threadID: String,
        toolName: String,
        input: String,
        requestedAt: Date,
        inputIsComplete: Bool = true
    ) {
        self.id = id
        self.threadID = threadID
        self.toolName = toolName
        self.input = input
        self.requestedAt = requestedAt
        self.inputIsComplete = inputIsComplete
    }
}

/// A pattern worth warning about before the user taps Approve on a 40mm screen.
public struct DestructiveSignal: Sendable, Hashable {
    public let label: String
    /// The exact substring that matched, so the UI can point at it rather than
    /// making an unexplained accusation.
    public let match: String
}

extension PendingApproval {
    /// How the approval screen should behave.
    ///
    /// `deferred` is not a softer `approve`: it is what the UI must default to
    /// when the user cannot see the whole command. Approving what you cannot
    /// read is the failure mode this type exists to prevent.
    public enum Recommendation: Sendable, Equatable {
        /// Safe to present Approve as the primary action.
        case decide
        /// Present Approve, but warn first and do not make it the default.
        case warn([DestructiveSignal])
        /// Do not offer Approve at all; offer Defer and "open on phone".
        case deferToLargerScreen(reason: String)
        /// The bridge stopped waiting and rejected the call itself. Nothing
        /// the watch sends now can change that, so offer nothing.
        case expired
    }

    /// How long the bridge holds a call before rejecting it on its own.
    ///
    /// `APPROVAL_TIMEOUT_MS` in `Plugin/amp-watch-bridge.ts` is the other
    /// half of this number; a test keeps them equal.
    public static let decisionWindow: TimeInterval = 10 * 60

    /// The moment after which a decision lands on nothing.
    public var deadline: Date { requestedAt.addingTimeInterval(Self.decisionWindow) }

    public func isExpired(now: Date) -> Bool { now > deadline }

    /// What the notification banner shows of the command. Approve from the
    /// banner is only honoured when the whole command fits there, mirroring
    /// `MAX_SUMMARY` in `Plugin/apns.ts`.
    public static let bannerLength = 160

    public var fitsInBanner: Bool {
        toolName.count + 2 + input.count <= Self.bannerLength
    }

    /// Substring patterns, matched case-insensitively.
    ///
    /// Substrings rather than regexes: a regex that is subtly wrong would fail
    /// open, and failing open here means silently approving a destructive
    /// command. Missing an exotic form is acceptable; the UI still shows the
    /// full text.
    static let destructivePatterns: [(pattern: String, label: String)] = [
        ("rm -rf", "recursive delete"),
        ("rm -fr", "recursive delete"),
        ("push --force", "force push"),
        ("push -f", "force push"),
        ("reset --hard", "discards local work"),
        ("drop table", "drops a table"),
        ("drop database", "drops a database"),
        ("truncate table", "empties a table"),
        ("mkfs", "formats a disk"),
        ("dd if=", "raw disk write"),
        ("::delete", "bulk delete"),
        ("--no-verify", "bypasses safety checks"),
        ("chmod 777", "removes permissions"),
        ("curl", "downloads and may execute remote code"),
        ("id_rsa", "touches a private key"),
        (".env", "touches secrets"),
        ("credentials", "touches credentials"),
    ]

    /// Destructive patterns found in the tool input.
    public var destructiveSignals: [DestructiveSignal] {
        let haystack = input.lowercased()
        var seen = Set<String>()
        return Self.destructivePatterns.compactMap { pattern, label in
            guard haystack.contains(pattern), seen.insert(label).inserted else { return nil }
            return DestructiveSignal(label: AmpStrings.text("destructive.\(label)"), match: pattern)
        }
    }

    /// The longest input the watch should ask someone to judge.
    ///
    /// Roughly what fits a few scrolls on a 45mm screen. Beyond it, the honest
    /// answer is "decide this somewhere else".
    public static let maxReadableInputLength = 600

    public func recommendation(now: Date) -> Recommendation {
        guard !isExpired(now: now) else { return .expired }
        guard inputIsComplete else {
            return .deferToLargerScreen(reason: AmpStrings.text("approval.truncated"))
        }
        guard input.count <= Self.maxReadableInputLength else {
            return .deferToLargerScreen(reason: AmpStrings.text("approval.too_long"))
        }
        let signals = destructiveSignals
        return signals.isEmpty ? .decide : .warn(signals)
    }

    /// The command that answers this approval.
    public func decision(_ decision: ApprovalDecision) -> WatchCommand {
        .decide(approvalID: id, threadID: threadID, decision: decision, requestedAt: requestedAt)
    }

    public func waitedSeconds(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(requestedAt))
    }
}

/// What the user decided.
public enum ApprovalDecision: String, Sendable, Codable {
    case approve
    case reject
    /// Leave it pending. Not a decision — explicitly modelled so "I looked and
    /// chose not to decide" is distinguishable from "no answer yet".
    case defer_ = "defer"
}
