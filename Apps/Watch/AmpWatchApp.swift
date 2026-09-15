import SwiftUI
import AmpKit

@main
struct AmpWatchApp: App {
    @WKApplicationDelegateAdaptor(PushRegistrar.self) private var push

    var body: some Scene {
        WindowGroup {
            if let screen = ScreenshotScene.requested {
                // Deterministic, network-free rendering for the screenshots CI
                // captures on the watchOS simulator.
                screen.view.environment(\.amp, screen.environment)
            } else {
                RootView(secrets: KeychainSecretStore(service: "com.soll.ampwatch"), push: push)
            }
        }
    }
}

/// Owns the session. Everything below reads the resulting `AmpEnvironment`;
/// when a credential changes, `reload` rebuilds the session and SwiftUI
/// re-renders the tree with a fresh client.
///
/// Also the one place that sends on behalf of the system: the push
/// registration after launch, and the command behind a notification button.
struct RootView: View {
    let secrets: any SecretStore
    let push: PushRegistrar?
    @State private var session: AmpSession
    /// Bumped on every reload so a new sink re-registers the device token.
    @State private var generation = 0
    @State private var path = NavigationPath()
    /// One queue for the life of the process, on disk, so a prompt dictated
    /// with no link outlives the app being killed.
    @State private var outbox = Outbox(fileURL: Self.outboxFile)
    @State private var outboxStatus = OutboxStatus()
    @Environment(\.scenePhase) private var scenePhase

    init(secrets: any SecretStore, push: PushRegistrar? = nil) {
        self.secrets = secrets
        self.push = push
        _session = State(initialValue: Self.load(secrets))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch session {
                case .needsSetup:
                    SetupView()
                case .ready:
                    ThreadListView()
                }
            }
            .navigationDestination(for: PendingApproval.self) { ApprovalView(approval: $0) }
        }
        .environment(\.amp, environment)
        .tint(AmpTheme.ember)
        .task(id: "\(push?.deviceToken ?? "")|\(generation)") { await registerForPushes() }
        .task(id: push?.pendingCommand) { await sendPendingCommand() }
        .task(id: push?.pendingApproval) { openPendingApproval() }
        .task(id: generation) { await retryOutbox() }
        .onChange(of: scenePhase) { _, phase in
            // Raising the wrist is the moment the link is most likely back.
            if phase == .active { Task { await environment.flushOutbox() } }
        }
    }

    /// Retries queued commands while the app is on screen. watchOS suspends
    /// the app when the wrist drops, so this is not a background service; the
    /// next raise resumes it (see `scenePhase` above).
    private func retryOutbox() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.outboxRetryInterval))
            await environment.flushOutbox()
        }
    }

    static let outboxRetryInterval: TimeInterval = 20

    private static var outboxFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AmpWatch/outbox.json")
    }

    private func openPendingApproval() {
        guard let push, let approval = push.pendingApproval, case .ready = session else { return }
        push.pendingApproval = nil
        path.append(approval)
    }

    private func registerForPushes() async {
        guard let token = push?.deviceToken, case .ready(_, .some(_)) = session else { return }
        try? secrets.write(token, for: .deviceToken)
        // Best effort: the bridge only learns the token this way, and the next
        // launch tries again. A fixed id means an offline launch queues one
        // registration, not one per retry.
        _ = await environment.deliver(.register(deviceToken: token, environment: PushRegistrar.environment), id: "register")
    }

    private func sendPendingCommand() async {
        guard let push, let command = push.pendingCommand, case .ready(_, .some(_)) = session else { return }
        push.pendingCommand = nil
        _ = await environment.deliver(command)
    }

    private var environment: AmpEnvironment {
        var client: any AmpClient = AmpSession.UnconfiguredClient()
        var dispatcher: Dispatcher?
        if case let .ready(readyClient, readySink) = session {
            client = readyClient
            dispatcher = readySink.map { Dispatcher(outbox: outbox, sink: $0) }
        }
        return AmpEnvironment(
            client: client,
            dispatcher: dispatcher,
            outbox: outboxStatus,
            preferences: PreferencesStore(),
            glance: .shared,
            secrets: secrets,
            now: { Date() },
            reload: {
                session = Self.load(secrets)
                generation += 1
            }
        )
    }

    private static func load(_ secrets: any SecretStore) -> AmpSession {
        AmpSession.load(from: secrets, transport: URLSessionTransport())
    }
}

/// Selects one screen and one data state from a launch argument.
///
/// `xcrun simctl launch … --args -ampwatch-screen usage` renders exactly that
/// screen, so CI can capture every state — including the empty and error states
/// a happy-path run would never reach — without driving the UI.
enum ScreenshotScene: String, CaseIterable {
    case threads
    case threadsEmpty = "threads-empty"
    case threadsError = "threads-error"
    case detail
    case compose
    case usage
    case setup
    case settings
    case newThread = "new-thread"
    case approval
    case approvalDestructive = "approval-destructive"
    case approvalDeferred = "approval-deferred"
    case threadsQueued = "threads-queued"
    case threadsOverCap = "threads-over-cap"
    case detailOverCap = "detail-over-cap"
    case phrases
    case templates
    case glance
    case glanceSpend = "glance-spend"

    static let launchArgument = "-ampwatch-screen"

    static var requested: ScreenshotScene? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument),
              index + 1 < arguments.count
        else { return nil }
        return ScreenshotScene(rawValue: arguments[index + 1])
    }

    var environment: AmpEnvironment {
        switch self {
        case .threadsEmpty: .fixture(behavior: .empty)
        case .threadsError: .fixture(behavior: .failing(.unauthorized))
        case .setup: .fixture(secrets: InMemorySecretStore())
        case .threadsQueued: .fixture(queued: [
            .prompt(threadID: Fixtures.threads()[0].id, text: "Continue", steer: true),
            .cancel(threadID: Fixtures.threads()[1].id),
        ])
        // The fixture thread has spent $1.87; a $1.50 cap puts it over.
        case .threadsOverCap, .detailOverCap: .fixture(preferences: Self.overCapPreferences)
        default: .fixture()
        }
    }

    private static var overCapPreferences: WatchPreferences {
        var preferences = WatchPreferences.defaults
        preferences.budgetCapUSD = 1.5
        return preferences
    }

    // Views are main-actor isolated under Swift 6, so building them is too.
    @MainActor @ViewBuilder
    var view: some View {
        let thread = Fixtures.threads()[0]
        switch self {
        case .threads, .threadsEmpty, .threadsError, .threadsQueued, .threadsOverCap:
            NavigationStack { ThreadListView() }.tint(AmpTheme.ember)
        case .detail, .detailOverCap:
            NavigationStack { ThreadDetailView(thread: thread) }.tint(AmpTheme.ember)
        case .compose:
            NavigationStack { ComposeView(thread: thread) }.tint(AmpTheme.ember)
        case .usage:
            NavigationStack { UsageView(thread: thread) }.tint(AmpTheme.ember)
        case .setup:
            NavigationStack { SetupView() }.tint(AmpTheme.ember)
        case .settings:
            NavigationStack { SettingsView() }.tint(AmpTheme.ember)
        case .newThread:
            NavigationStack { NewThreadView() }.tint(AmpTheme.ember)
        case .approval:
            NavigationStack { ApprovalView(approval: Fixtures.approvals()[0]) }.tint(AmpTheme.ember)
        case .approvalDestructive:
            NavigationStack { ApprovalView(approval: Fixtures.approvals()[1]) }.tint(AmpTheme.ember)
        case .approvalDeferred:
            NavigationStack { ApprovalView(approval: Fixtures.approvals()[2]) }.tint(AmpTheme.ember)
        case .phrases:
            NavigationStack { PhrasesView() }.tint(AmpTheme.ember)
        case .templates:
            NavigationStack { TemplatesView() }.tint(AmpTheme.ember)
        case .glance:
            NavigationStack { GlanceGalleryView(kind: .awaiting) }.tint(AmpTheme.ember)
        case .glanceSpend:
            NavigationStack { GlanceGalleryView(kind: .spend) }.tint(AmpTheme.ember)
        }
    }
}

#Preview("Threads") {
    NavigationStack { ThreadListView() }.environment(\.amp, .fixture())
}

#Preview("Setup") {
    RootView(secrets: InMemorySecretStore())
}

#Preview("Usage") {
    NavigationStack { UsageView(thread: Fixtures.threads()[0]) }
        .environment(\.amp, .fixture())
}
