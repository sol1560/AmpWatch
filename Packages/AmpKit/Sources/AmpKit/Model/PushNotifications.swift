import Foundation

/// The notification categories the bridge sends (`Plugin/apns.ts`) and the
/// actions the watch attaches to each. One definition on each side; the
/// strings must match.
public enum PushCategory: String, CaseIterable, Sendable {
    case threadDone = "THREAD_DONE"
    case threadError = "THREAD_ERROR"
    case approval = "APPROVAL"

    public var actions: [PushAction] {
        switch self {
        case .threadDone: [.continueThread]
        case .threadError: [.retry]
        case .approval: [.approve, .reject]
        }
    }
}

/// A button on a notification. `identifier` is what the system hands back
/// when the user taps it.
public enum PushAction: String, CaseIterable, Sendable {
    case continueThread = "CONTINUE"
    case retry = "RETRY"
    case approve = "APPROVE"
    case reject = "REJECT"

    public var identifier: String { rawValue }

    public var title: String {
        switch self {
        case .continueThread: "Continue"
        case .retry: "Try again"
        case .approve: "Approve"
        case .reject: "Reject"
        }
    }

    /// Whether the action should be shown in a warning colour.
    public var isDestructive: Bool { self == .reject }
}

/// The custom keys the bridge puts next to `aps` in every push.
public struct PushPayload: Sendable, Equatable {
    public var threadID: String
    /// The held call, on `APPROVAL` pushes. Carried whole so the watch can
    /// judge it from the notification, with no round trip to the API.
    public var approval: PendingApproval?

    public init(threadID: String, approval: PendingApproval? = nil) {
        self.threadID = threadID
        self.approval = approval
    }

    /// Reads the payload out of a notification's `userInfo`. Missing or
    /// malformed thread IDs yield `nil`; the app then just opens. An approval
    /// that is missing any field is dropped rather than half-read: a decision
    /// made on a partial command is worse than no decision.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let threadID = userInfo["threadID"] as? String, threadID.hasPrefix("T-") else { return nil }
        self.threadID = threadID
        self.approval = Self.approval(from: userInfo["approval"], threadID: threadID)
    }

    private static func approval(from value: Any?, threadID: String) -> PendingApproval? {
        guard let fields = value as? [AnyHashable: Any],
              let id = fields["id"] as? String, !id.isEmpty,
              let toolName = fields["toolName"] as? String,
              let input = fields["input"] as? String,
              let requestedAt = fields["requestedAt"] as? Double
        else { return nil }
        return PendingApproval(
            id: id,
            threadID: threadID,
            toolName: toolName,
            input: input,
            requestedAt: Date(timeIntervalSince1970: requestedAt / 1000),
            // Absent means complete; the bridge only writes the key when it cut the text.
            inputIsComplete: (fields["inputIsComplete"] as? Bool) ?? true
        )
    }
}

/// What the app does with a notification the user acted on.
public enum PushResponse: Sendable, Equatable {
    /// Send this and stay where you are.
    case send(WatchCommand)
    /// Show the approval screen: the command needs a look before a decision.
    case review(PendingApproval)
    /// Nothing to send; the app just opens.
    case open
}

extension PushAction {
    /// Maps a notification response to what the app should do.
    ///
    /// Approve from the notification banner is only honoured when the command
    /// is one the watch would have offered a plain Approve for. Anything the
    /// approval screen would warn about, or refuse to show, goes to that
    /// screen instead — the banner never lets a warning be skipped.
    public static func response(actionIdentifier: String, payload: PushPayload) -> PushResponse {
        guard let action = PushAction(rawValue: actionIdentifier) else {
            // A plain tap: land on the approval if there is one, else the list.
            return payload.approval.map(PushResponse.review) ?? .open
        }
        switch action {
        case .continueThread:
            return .send(.prompt(threadID: payload.threadID, text: "Continue.", steer: false))
        case .retry:
            return .send(.prompt(threadID: payload.threadID, text: "Try again.", steer: false))
        case .approve:
            guard let approval = payload.approval else { return .open }
            guard approval.recommendation() == .decide else { return .review(approval) }
            return .send(.decide(approvalID: approval.id, threadID: payload.threadID, decision: .approve))
        case .reject:
            guard let approval = payload.approval else { return .open }
            return .send(.decide(approvalID: approval.id, threadID: payload.threadID, decision: .reject))
        }
    }
}

public enum DeviceToken {
    /// APNs device tokens travel as lower-case hex; the bridge validates
    /// exactly that shape.
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
