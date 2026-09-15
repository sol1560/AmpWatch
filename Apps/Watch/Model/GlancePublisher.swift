import Foundation
import UserNotifications
import WidgetKit
import AmpKit

/// Writes the glance the complications read, and asks WidgetKit to redraw.
///
/// The thread list is the only writer: every successful load publishes. The
/// widget extension never calls the API, so a complication is exactly as
/// fresh as the last time the app was on screen, and says so.
struct GlancePublisher: Sendable {
    let store: GlanceStore

    /// The app-group file when the container exists, otherwise the app's own
    /// support directory so the app keeps working on a build without the
    /// entitlement — the complication just stays on its placeholder.
    static var shared: GlancePublisher {
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(GlanceFile.name)
        return GlancePublisher(store: GlanceFile.shared ?? GlanceStore(fileURL: fallback))
    }

    func publish(threads: [ThreadSummary], usage: [String: ThreadUsage], now: Date) async {
        let glance = Glance.make(threads: threads, usage: usage, awaiting: await Self.awaitingApprovals(now: now), now: now)
        // Best effort: a glance that fails to write leaves the old one, and
        // the widget's staleness check handles the rest.
        try? store.save(glance)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Held tool calls the user has not acted on: their notifications are
    /// still in Notification Center. Tapping one — the banner button or the
    /// notification itself — removes it, so this needs no bookkeeping of its
    /// own. One the bridge has already given up on (older than the decision
    /// window) is not waiting on anyone and is left out.
    private static func awaitingApprovals(now: Date) async -> Int {
        await UNUserNotificationCenter.current().deliveredNotifications()
            .filter { $0.request.content.categoryIdentifier == PushCategory.approval.rawValue }
            .filter { now.timeIntervalSince($0.date) <= Outbox.decisionTTL }
            .count
    }
}
