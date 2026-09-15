import SwiftUI
import WidgetKit
import AmpKit

// Compiled into both the app and the widget extension: the widget renders
// these on the face, the app renders them in the `glance` screenshot scene so
// CI can show what the face will look like. Nothing here touches AmpTheme —
// accessory complications take their colour from the watch face, and the
// only styling that survives is weight, serif and `widgetAccentable`.

/// Which of the two complications is being drawn.
enum GlanceKind {
    /// Threads waiting on you (held tool calls) and threads moving.
    case awaiting
    /// What today's threads have cost.
    case spend
}

/// One complication, in one family, from one glance (or none).
struct GlanceView: View {
    let kind: GlanceKind
    let family: WidgetFamily
    let glance: Glance?
    let now: Date
    /// For the UI tests; the widget never sets it.
    var identifier: String? = nil

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .accessibilityIdentifier(identifier ?? "face-\(kind == .awaiting ? "awaiting" : "spend")-\(familyName)")
    }

    private var familyName: String {
        switch family {
        case .accessoryCircular: "circular"
        case .accessoryInline: "inline"
        default: "rectangular"
        }
    }

    // MARK: Circular — one number, one word

    private var circular: some View {
        VStack(spacing: -2) {
            Text(bigNumber)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .widgetAccentable()
            Text(bigCaption)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
        }
    }

    private var bigNumber: String {
        guard let glance, !stale else { return "–" }
        switch kind {
        case .awaiting: return String(glance.awaiting > 0 ? glance.awaiting : glance.live)
        case .spend: return Money.compact(usd: glance.spentTodayUSD)
        }
    }

    private var bigCaption: String {
        guard let glance, !stale else { return "amp" }
        switch kind {
        case .awaiting: return glance.awaiting > 0 ? "held" : "live"
        case .spend: return "today"
        }
    }

    // MARK: Rectangular — three short lines

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .widgetAccentable()
            Text(detail)
                .font(.system(size: 13, design: .serif))
                .lineLimit(1)
            Text(footer)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: String {
        guard let glance, !stale else { return "Amp" }
        switch kind {
        case .awaiting:
            return glance.awaiting > 0 ? "\(glance.awaiting) waiting on you" : "\(glance.live) moving"
        case .spend:
            return "\(Money.compact(usd: glance.spentTodayUSD)) today"
        }
    }

    private var detail: String {
        guard let glance, !stale else { return "Open to refresh" }
        switch kind {
        case .awaiting:
            return glance.headline ?? "Nothing running"
        case .spend:
            return glance.spentTodayThreads == 1 ? "1 thread" : "\(glance.spentTodayThreads) threads"
        }
    }

    private var footer: String {
        guard let glance, !stale else { return "" }
        if kind == .awaiting, glance.awaiting > 0 {
            return "\(glance.live) moving · \(RelativeTime.short(from: glance.updatedAt, to: now))"
        }
        return "as of \(RelativeTime.short(from: glance.updatedAt, to: now)) ago"
    }

    // MARK: Inline — one sentence

    private var inline: some View {
        Text(inlineText)
            .lineLimit(1)
    }

    /// Inline gets one short line next to the time; the full sentence is
    /// what VoiceOver reads.
    private var inlineText: String {
        guard let glance, !stale else { return "Amp: open to refresh" }
        switch kind {
        case .awaiting:
            return glance.awaiting > 0 ? "\(glance.awaiting) held · \(glance.live) moving" : "\(glance.live) moving"
        case .spend:
            return "\(Money.compact(usd: glance.spentTodayUSD)) today"
        }
    }

    /// Doubles as the VoiceOver label for every family.
    private var spokenSummary: String {
        guard let glance, !stale else { return "Amp: open to refresh" }
        switch kind {
        case .awaiting:
            if glance.awaiting > 0 {
                return "Amp: \(glance.awaiting) waiting on you, \(glance.live) moving"
            }
            return "Amp: \(glance.live) moving"
        case .spend:
            return "Amp: \(Money.compact(usd: glance.spentTodayUSD)) today"
        }
    }

    private var stale: Bool {
        glance?.isStale(now: now) ?? true
    }
}
