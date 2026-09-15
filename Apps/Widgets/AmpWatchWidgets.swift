import SwiftUI
import WidgetKit
import AmpKit

/// Two complications, one file, no network.
///
/// The extension reads the glance the app last wrote to the app group and
/// draws it. It has no token, no bridge URL and no way to fetch, so the
/// worst it can leak is one thread title, and the worst it can be is stale —
/// which it says on the face.
@main
struct AmpWidgetBundle: WidgetBundle {
    var body: some Widget {
        AwaitingWidget()
        SpendWidget()
    }
}

struct AwaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.soll.ampwatch.awaiting", provider: GlanceProvider()) { entry in
            GlanceEntryView(kind: .awaiting, entry: entry)
        }
        .configurationDisplayName("Waiting on you")
        .description("Held tool calls and threads that are moving.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.soll.ampwatch.spend", provider: GlanceProvider()) { entry in
            GlanceEntryView(kind: .spend, entry: entry)
        }
        .configurationDisplayName("Spend today")
        .description("What today's threads have cost, as of the last time Amp was open.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: Glance?
}

/// Reads the file; never fetches. The app reloads timelines after every
/// list load, and the timeline itself only exists so "as of 12m ago" and the
/// staleness cut-off keep moving while the app is closed.
struct GlanceProvider: TimelineProvider {
    private var store: GlanceStore? { GlanceFile.shared }

    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Fixtures.referenceDate, glance: Self.sample(now: Fixtures.referenceDate))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let now = Date()
        completion(GlanceEntry(date: now, glance: context.isPreview ? Self.sample(now: now) : store?.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        let glance = store?.load()
        // One entry per five minutes for the next half hour: enough for the
        // "as of" line to stay honest, few enough to stay inside the budget
        // WidgetKit gives a complication.
        let entries = stride(from: 0, through: 30, by: 5).map { minutes in
            GlanceEntry(date: now.addingTimeInterval(TimeInterval(minutes * 60)), glance: glance)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// What the gallery shows before the app has ever published.
    static func sample(now: Date) -> Glance {
        Glance(
            live: 1,
            awaiting: 1,
            spentTodayUSD: 1.87,
            spentTodayThreads: 3,
            headline: "Fix the flaky watchOS simulator boot in CI",
            updatedAt: now
        )
    }
}

struct GlanceEntryView: View {
    @Environment(\.widgetFamily) private var family
    let kind: GlanceKind
    let entry: GlanceEntry

    var body: some View {
        GlanceView(kind: kind, family: family, glance: entry.glance, now: entry.date)
            .containerBackground(for: .widget) { Color.clear }
    }
}
