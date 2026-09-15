import Foundation
import SwiftUI
import AmpKit

/// Everything the views need from the outside world, in one injectable value.
///
/// `now` is a closure rather than `Date()` so screenshot runs can freeze the
/// clock; otherwise every captured image would differ in its relative
/// timestamps and be useless for review.
struct AmpEnvironment: Sendable {
    var client: any AmpClient
    var promptSink: (any AmpPromptSink)?
    var now: @Sendable () -> Date

    static func fixture(behavior: FixtureAmpClient.Behavior = .ok) -> AmpEnvironment {
        let fixture = FixtureAmpClient(behavior: behavior)
        return AmpEnvironment(
            client: fixture,
            promptSink: fixture,
            now: { Fixtures.referenceDate }
        )
    }
}

private struct AmpEnvironmentKey: EnvironmentKey {
    static let defaultValue = AmpEnvironment.fixture()
}

extension EnvironmentValues {
    var amp: AmpEnvironment {
        get { self[AmpEnvironmentKey.self] }
        set { self[AmpEnvironmentKey.self] = newValue }
    }
}

/// A loaded-or-not wrapper used by every screen, so loading, empty and error
/// states are handled in one place instead of three times over.
enum Loadable<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(AmpError)
}
