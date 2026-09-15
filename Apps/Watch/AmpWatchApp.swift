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
                RootView()
                    .environment(\.amp, .live())
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            ThreadListView()
        }
        .tint(AmpTheme.ember)
    }
}

extension AmpEnvironment {
    /// The real app wiring.
    ///
    /// Still fixture-backed: credential storage and the live `AmpAPIClient` /
    /// `WebhookPromptSink` wiring land in the next milestone. Everything above
    /// this line already talks to `AmpClient`, so only this function changes.
    static func live() -> AmpEnvironment {
        let fixture = FixtureAmpClient(behavior: .ok, now: Fixtures.referenceDate)
        return AmpEnvironment(
            client: fixture,
            promptSink: fixture,
            now: { Fixtures.referenceDate }
        )
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
        default: .fixture()
        }
    }

    @ViewBuilder
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
        }
    }
}

#Preview("Threads") {
    RootView().environment(\.amp, .fixture())
}

#Preview("Usage") {
    NavigationStack { UsageView(thread: Fixtures.threads()[0]) }
        .environment(\.amp, .fixture())
}
