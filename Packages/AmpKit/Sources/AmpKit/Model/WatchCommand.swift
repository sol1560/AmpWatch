import Foundation

/// The built-in Amp agent modes a new thread can start in.
public enum AgentMode: String, Sendable, Codable, CaseIterable {
    case low, medium, high, ultra
}

/// Which APNs gateway can reach this build. Xcode installs talk to the
/// sandbox gateway; TestFlight and App Store installs to production. A token
/// sent to the wrong gateway is rejected with `BadDeviceToken`.
public enum PushEnvironment: String, Sendable, Codable {
    case sandbox, production
}

/// Which of a thread's tool calls the bridge holds for the watch. Off until
/// the watch says otherwise, so no thread waits on a wrist nobody is checking.
public enum ArmLevel: String, Sendable, Codable, CaseIterable {
    case off
    /// Shell commands that match `PendingApproval.destructivePatterns`.
    case risky
    /// Every shell command.
    case all

    /// Plain words for a picker row.
    public var label: String {
        switch self {
        case .off: "never"
        case .risky: "risky commands"
        case .all: "every command"
        }
    }
}

/// Everything the watch can ask the bridge to do. One definition, used by the
/// outbox, the sink and the UI; its wire form is `Plugin/commands.ts`.
public enum WatchCommand: Sendable, Hashable, Codable {
    /// Append a user message. `steer` prefers it over queued work when the
    /// thread is busy — the right default when redirecting a running agent.
    case prompt(threadID: String, text: String, steer: Bool)
    case cancel(threadID: String)
    case create(prompt: String, mode: AgentMode)
    /// `requestedAt` is when the bridge held the call; it never goes on the
    /// wire, but the outbox uses it to drop a decision the bridge has already
    /// stopped waiting for.
    case decide(approvalID: String, threadID: String, decision: ApprovalDecision, requestedAt: Date)
    /// Choose which of a thread's commands wait for the watch.
    case arm(threadID: String, level: ArmLevel)
    /// Tell the bridge where to send pushes. Sent on every launch, because the
    /// bridge keeps registrations in memory only.
    case register(deviceToken: String, environment: PushEnvironment)

    /// The thread this command acts on, if it acts on one.
    public var threadID: String? {
        switch self {
        case let .prompt(threadID, _, _), let .cancel(threadID), let .decide(_, threadID, _, _), let .arm(threadID, _): threadID
        case .create, .register: nil
        }
    }

    /// JSON object as the bridge expects it. Encoded by hand rather than via
    /// synthesized `Codable`, whose nested-enum shape would not match the
    /// plugin's flat `{type, …}` objects.
    public var wireObject: [String: String] {
        switch self {
        case let .prompt(threadID, text, steer):
            ["type": steer ? "steer" : "prompt", "threadID": threadID, "prompt": text]
        case let .cancel(threadID):
            ["type": "cancel", "threadID": threadID]
        case let .create(prompt, mode):
            ["type": "create", "prompt": prompt, "mode": mode.rawValue]
        case let .decide(approvalID, threadID, decision, _):
            ["type": "decide", "approvalID": approvalID, "threadID": threadID, "decision": decision.rawValue]
        case let .arm(threadID, level):
            ["type": "arm", "threadID": threadID, "level": level.rawValue]
        case let .register(deviceToken, environment):
            ["type": "register", "deviceToken": deviceToken, "environment": environment.rawValue]
        }
    }
}
