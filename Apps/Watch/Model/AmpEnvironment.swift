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
///
/// Writes go through `deliver`, never straight to a sink: that is what makes
/// a prompt survive a dropped link.
struct AmpEnvironment: Sendable {
    var client: any AmpClient
    /// `nil` until a bridge URL is set; then the only write path.
    var dispatcher: Dispatcher?
    var outbox: OutboxStatus
    var preferences: PreferencesStore
    /// Where the thread list publishes what the complications show. `nil`
    /// for fixtures, so a screenshot run never writes to the app group.
    var glance: GlancePublisher?
    var secrets: any SecretStore
    var now: @Sendable () -> Date
    var reload: @MainActor () -> Void
    var speech: (any SpeechTranscriber)? = nil

    /// Queues `command` and tries to send it. `nil` means there is no bridge
    /// to send to at all, which the caller should say out loud.
    @MainActor
    func deliver(_ command: WatchCommand, id: String = UUID().uuidString) async -> DeliveryOutcome? {
        guard let dispatcher else { return nil }
        let outcome = await dispatcher.submit(command, id: id, at: now())
        outbox.update(pending: await dispatcher.outbox.count, outcome: outcome)
        return outcome
    }

    /// Retries whatever is queued, and tells the status object what happened.
    @MainActor
    func flushOutbox() async {
        guard let dispatcher else { return }
        let result = await dispatcher.flush()
        outbox.update(pending: result.remaining, dropped: result.dropped.map(\.reason), delivered: !result.delivered.isEmpty)
    }

    static func fixture(
        behavior: FixtureAmpClient.Behavior = .ok,
        secrets: any SecretStore = InMemorySecretStore(Fixtures.secrets),
        preferences: WatchPreferences = .defaults,
        queued: [WatchCommand] = [],
        speech: (any SpeechTranscriber)? = nil
    ) -> AmpEnvironment {
        let fixture = FixtureAmpClient(behavior: behavior)
        // Queued items stay queued: the sink they would drain into is offline.
        let outbox = Outbox(now: { Fixtures.referenceDate })
        let sink: any AmpPromptSink = queued.isEmpty ? fixture : FixtureAmpClient(behavior: .failing(.transport("offline")))
        Task {
            for (index, command) in queued.enumerated() {
                await outbox.enqueue(OutboxItem(id: "fixture-\(index)", command: command, createdAt: Fixtures.referenceDate))
            }
        }
        return AmpEnvironment(
            client: fixture,
            dispatcher: Dispatcher(outbox: outbox, sink: sink),
            outbox: OutboxStatus(pending: queued.count),
            preferences: .inMemory(preferences),
            secrets: secrets,
            now: { Fixtures.referenceDate },
            reload: {},
            speech: speech
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

/// What the list header says about the outbox. Observable so the banner
/// updates when a background flush drains the queue.
///
/// Not actor-isolated so the environment's static default can build one; in
/// practice only `AmpEnvironment.deliver` and `flushOutbox` write to it, both
/// on the main actor.
@Observable
final class OutboxStatus: @unchecked Sendable {
    private(set) var pending: Int
    /// Plain words about the last item that never made it. Cleared by the next
    /// delivery, because by then the user has seen it.
    private(set) var note: String?

    init(pending: Int = 0, note: String? = nil) {
        self.pending = pending
        self.note = note
    }

    func update(pending: Int, outcome: DeliveryOutcome) {
        switch outcome {
        case let .dropped(reason): update(pending: pending, dropped: [reason])
        case .delivered: update(pending: pending, dropped: [], delivered: true)
        case .queued: update(pending: pending, dropped: [])
        }
    }

    func update(pending: Int, dropped: [OutboxDrop], delivered: Bool = false) {
        self.pending = pending
        if let last = dropped.last {
            note = Self.note(for: last)
        } else if delivered {
            note = nil
        }
    }

    static func note(for drop: OutboxDrop) -> String {
        switch drop {
        case .expired: WatchStrings.text("outbox.expired")
        case .exhausted: WatchStrings.format("outbox.exhausted", Outbox.maxAttempts)
        }
    }
}

extension PreferencesStore {
    /// A store that starts with `preferences` and never touches the real
    /// defaults: for screenshots and previews.
    static func inMemory(_ preferences: WatchPreferences) -> PreferencesStore {
        let store = PreferencesStore(defaults: UserDefaults(suiteName: "ampwatch.fixture.\(UUID().uuidString)")!)
        store.save(preferences)
        return store
    }
}
