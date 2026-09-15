import SwiftUI
import AmpKit

@main
struct AmpWatchApp: App {
    var body: some Scene {
        WindowGroup {
            if let screen = ScreenshotScene.requested {
                // Deterministic, network-free rendering for the screenshots CI
                // captures on the watchOS simulator.
                screen.view.environment(\.amp, screen.environment)
            } else {
                RootView(secrets: KeychainSecretStore(service: "com.soll.ampwatch"))
            }
        }
    }
}

/// Owns the session. Everything below reads the resulting `AmpEnvironment`;
/// when a credential changes, `reload` rebuilds the session and SwiftUI
/// re-renders the tree with a fresh client.
struct RootView: View {
    let secrets: any SecretStore
    @State private var session: AmpSession

    init(secrets: any SecretStore) {
        self.secrets = secrets
        _session = State(initialValue: Self.load(secrets))
    }

    var body: some View {
        NavigationStack {
            switch session {
            case .needsSetup:
                SetupView()
            case .ready:
                ThreadListView()
            }
        }
        .environment(\.amp, environment)
        .tint(AmpTheme.ember)
    }

    private var environment: AmpEnvironment {
        var client: any AmpClient = AmpSession.UnconfiguredClient()
        var sink: (any AmpPromptSink)?
        if case let .ready(readyClient, readySink) = session {
            client = readyClient
            sink = readySink
        }
        return AmpEnvironment(
            client: client,
            promptSink: sink,
            secrets: secrets,
            now: { Date() },
            reload: { session = Self.load(secrets) }
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
        default: .fixture()
        }
    }

    // Views are main-actor isolated under Swift 6, so building them is too.
    @MainActor @ViewBuilder
    var view: some View {
        let thread = Fixtures.threads()[0]
        switch self {
        case .threads, .threadsEmpty, .threadsError:
            NavigationStack { ThreadListView() }.tint(AmpTheme.ember)
        case .detail:
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
