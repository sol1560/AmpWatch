import Foundation

/// Deterministic sample data for SwiftUI previews and for the screenshots CI
/// captures on the watchOS simulator.
///
/// Every timestamp is derived from `Fixtures.referenceDate`, so a screenshot
/// taken today is byte-comparable with one taken next month. Never point this
/// at `Date()`.
public enum Fixtures {
    /// 2026-03-14T09:41:00Z — Apple's canonical demo time.
    public static let referenceDate = Date(timeIntervalSince1970: 1_773_480_060)

    public static func threads(now: Date = referenceDate) -> [ThreadSummary] {
        [
            ThreadSummary(
                id: "T-01a0a325-7a11-73eb-a5a7-46c40b37076d",
                title: "Fix the flaky watchOS simulator boot in CI",
                createdAt: now.addingTimeInterval(-3600),
                updatedAt: now.addingTimeInterval(-12),
                creatorUserID: "user_soll",
                repositories: [Repository(url: "https://github.com/soll/AmpWatch")]
            ),
            ThreadSummary(
                id: "T-9b2c7d10-4f88-4d21-91aa-2c5f8e0b1c34",
                title: "Trim the bundle by 200 kB",
                createdAt: now.addingTimeInterval(-7200),
                updatedAt: now.addingTimeInterval(-240),
                creatorUserID: "user_soll",
                repositories: [Repository(url: "https://github.com/soll/storefront")]
            ),
            ThreadSummary(
                id: "T-4e1f0a55-2277-4bd9-8f10-77a9c3b4e601",
                title: "Encrypt PII at rest",
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-5400),
                creatorUserID: "user_soll",
                repositories: [Repository(url: "https://github.com/soll/ledger", dir: "services/api")]
            ),
            ThreadSummary(
                id: "T-77c3ba91-08de-41f3-b2e8-5a6d9f2c4471",
                title: nil,
                createdAt: now.addingTimeInterval(-540_000),
                updatedAt: now.addingTimeInterval(-432_000),
                creatorUserID: "user_soll"
            ),
        ]
    }

    public static func messages(now: Date = referenceDate) -> [ThreadMessage] {
        [
            ThreadMessage(
                id: "m1",
                version: 1,
                createdAt: now.addingTimeInterval(-3600),
                role: .user,
                text: "The watchOS simulator sometimes fails to boot on macos-15. Make CI pick a runtime that is actually installed."
            ),
            ThreadMessage(
                id: "m2",
                version: 1,
                createdAt: now.addingTimeInterval(-3480),
                role: .assistant,
                text: "The workflow hard-coded watchOS 11.5. The runner image now ships 26.1 and 26.2, so I made the script query simctl and pick the newest available runtime."
            ),
            ThreadMessage(
                id: "m3",
                version: 1,
                createdAt: now.addingTimeInterval(-60),
                role: .assistant,
                text: "Booted Apple Watch Ultra 3 (49mm) on watchOS 26.2. Tests pass, screenshots uploaded."
            ),
        ]
    }

    /// Obviously fake credentials for the settings screenshot. The UI masks
    /// them anyway; these must never resemble a real token format closely
    /// enough to trip a secret scanner.
    public static let secrets: [SecretKey: String] = [
        .accessToken: "fixture-token-ends-in-7f3a",
        .webhookURL: "https://hooks.example.test/w/fixture",
    ]

    /// Held calls for the approval screenshots: one to decide, one to warn
    /// about, one the watch must refuse to decide, one the bridge has
    /// already given up on.
    public static func approvals(now: Date = referenceDate) -> [PendingApproval] {
        let threadID = threads(now: now)[0].id
        return [
            PendingApproval(
                id: "TU-01fixtureplain",
                threadID: threadID,
                toolName: "shell_command",
                input: "/repo/Packages/AmpKit $ swift test --filter ThreadActivityTests",
                requestedAt: now.addingTimeInterval(-40)
            ),
            PendingApproval(
                id: "TU-02fixtureforce",
                threadID: threadID,
                toolName: "shell_command",
                input: "/repo $ git push --force origin main",
                requestedAt: now.addingTimeInterval(-95)
            ),
            PendingApproval(
                id: "TU-03fixturelong",
                threadID: threadID,
                toolName: "shell_command",
                input: "/repo $ python3 - <<'EOF'\nimport json, pathlib\nfor path in pathlib.Path('Sources').rglob('*.swift'):\n    text = path.read_text()\n    if 'Date()' in text:\n        print(path)\n",
                requestedAt: now.addingTimeInterval(-8),
                inputIsComplete: false
            ),
            PendingApproval(
                id: "TU-04fixturelate",
                threadID: threadID,
                toolName: "shell_command",
                input: "/repo $ swift build",
                requestedAt: now.addingTimeInterval(-(PendingApproval.decisionWindow + 65))
            ),
        ]
    }

    public static func usage() -> ThreadUsage {
        ThreadUsage(
            threadID: "T-01a0a325-7a11-73eb-a5a7-46c40b37076d",
            usage: 1.87,
            models: [
                ModelUsage(
                    provider: "anthropic",
                    model: "claude-fable-5.1",
                    requests: 42,
                    inputTokens: 128_400,
                    outputTokens: 18_200,
                    usage: 1.42
                ),
                ModelUsage(
                    provider: "openai",
                    model: "gpt-5.6",
                    requests: 11,
                    inputTokens: 44_100,
                    outputTokens: 6_050,
                    usage: 0.45
                ),
            ]
        )
    }
}

/// In-memory `AmpClient` + `AmpPromptSink` for previews, screenshots and tests.
public actor FixtureAmpClient: AmpClient, AmpPromptSink {
    public enum Behavior: Sendable {
        case ok
        case empty
        case grouped
        case failing(AmpError)
    }

    private let behavior: Behavior
    private let now: Date
    public private(set) var sent: [WatchCommand] = []

    public init(behavior: Behavior = .ok, now: Date = Fixtures.referenceDate) {
        self.behavior = behavior
        self.now = now
    }

    public func threads(limit: Int, cursor: String?) async throws -> Page<ThreadSummary> {
        try check()
        if case .empty = behavior { return Page(items: []) }
        if case .grouped = behavior {
            let samples = Fixtures.threads(now: now)
            let extra = ThreadSummary(
                id: "T-grouped-example", title: "多语言与语音功能：让手表上的对话更容易阅读",
                updatedAt: now.addingTimeInterval(-90),
                repositories: samples[0].repositories
            )
            return Page(items: [samples[1], samples[3], extra, samples[0]], nextCursor: "fixture-next")
        }
        return Page(items: Array(Fixtures.threads(now: now).prefix(limit)))
    }

    public func messages(threadID: String, limit: Int, cursor: String?) async throws -> Page<ThreadMessage> {
        try check()
        if case .empty = behavior { return Page(items: []) }
        return Page(items: Array(Fixtures.messages(now: now).suffix(limit)))
    }

    public func usage(threadID: String) async throws -> ThreadUsage {
        try check()
        return Fixtures.usage()
    }

    public func send(_ command: WatchCommand, idempotencyKey: String?) async throws {
        try check()
        sent.append(command)
    }

    private func check() throws {
        if case let .failing(error) = behavior { throw error }
    }
}
