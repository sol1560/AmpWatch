import Foundation
import SwiftUI
import AmpKit

/// Everything the views need from the outside world, in one injectable value.
///
/// `now` is a closure rather than `Date()` so screenshot runs can freeze the
/// clock; otherwise every captured image would differ in its relative
/// timestamps and be useless for review.
///
/// `secrets` and `reload` exist for the settings screen only: after the user
/// changes a credential the root view rebuilds the session, and every other
/// view gets a new environment with a new client. Views never read secrets.
struct AmpEnvironment: Sendable {
    var client: any AmpClient
    var promptSink: (any AmpPromptSink)?
    var secrets: any SecretStore
    var now: @Sendable () -> Date
    var reload: @MainActor () -> Void

    static func fixture(
        behavior: FixtureAmpClient.Behavior = .ok,
        secrets: any SecretStore = InMemorySecretStore(Fixtures.secrets)
    ) -> AmpEnvironment {
        let fixture = FixtureAmpClient(behavior: behavior)
        return AmpEnvironment(
            client: fixture,
            promptSink: fixture,
            secrets: secrets,
            now: { Fixtures.referenceDate },
            reload: {}
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
