import Foundation

/// The built-in Amp agent modes a new thread can start in.
public enum AgentMode: String, Sendable, Codable, CaseIterable {
    case low, medium, high, ultra
}

/// Everything the watch can ask the bridge to do. One definition, used by the
/// outbox, the sink and the UI; its wire form is `Plugin/commands.ts`.
public enum WatchCommand: Sendable, Hashable, Codable {
    /// Append a user message. `steer` prefers it over queued work when the
    /// thread is busy — the right default when redirecting a running agent.
    case prompt(threadID: String, text: String, steer: Bool)
    case cancel(threadID: String)
    case create(prompt: String, mode: AgentMode)
    case decide(approvalID: String, threadID: String, decision: ApprovalDecision)

    /// The thread this command acts on, if it acts on one.
    public var threadID: String? {
        switch self {
        case let .prompt(threadID, _, _), let .cancel(threadID), let .decide(_, threadID, _): threadID
        case .create: nil
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
        case let .decide(approvalID, threadID, decision):
            ["type": "decide", "approvalID": approvalID, "threadID": threadID, "decision": decision.rawValue]
        }
    }
}
