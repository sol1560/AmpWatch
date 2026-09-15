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
    public var approvalID: String?

    public init(threadID: String, approvalID: String? = nil) {
        self.threadID = threadID
        self.approvalID = approvalID
    }

    /// Reads the payload out of a notification's `userInfo`. Missing or
    /// malformed thread IDs yield `nil`; the app then just opens.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let threadID = userInfo["threadID"] as? String, threadID.hasPrefix("T-") else { return nil }
        self.threadID = threadID
        self.approvalID = userInfo["approvalID"] as? String
    }
}

extension PushAction {
    /// The command a tapped action sends, or `nil` when the payload does not
    /// carry what the action needs (an approval without an approval ID) or
    /// when the response was a plain tap, which only opens the app.
    public static func command(actionIdentifier: String, payload: PushPayload) -> WatchCommand? {
        guard let action = PushAction(rawValue: actionIdentifier) else { return nil }
        switch action {
        case .continueThread:
            return .prompt(threadID: payload.threadID, text: "Continue.", steer: false)
        case .retry:
            return .prompt(threadID: payload.threadID, text: "Try again.", steer: false)
        case .approve, .reject:
            guard let approvalID = payload.approvalID else { return nil }
            return .decide(approvalID: approvalID, threadID: payload.threadID, decision: action == .approve ? .approve : .reject)
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
