import SwiftUI
import WidgetKit
import AmpKit

/// Every complication face, drawn inside the app from one fixture glance.
///
/// A watch face cannot be scripted from `simctl`, so this is how CI shows a
/// reviewer what the complications say. It is reachable only through the
/// screenshot harness; it is not a screen the user navigates to.
struct GlanceGalleryView: View {
    let kind: GlanceKind
    @Environment(\.amp) private var amp

    private var glance: Glance {
        Glance.make(
            threads: Fixtures.threads(),
            usage: [Fixtures.usage().threadID: Fixtures.usage()],
            awaiting: 1,
            now: amp.now()
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section(WatchStrings.text(kind == .awaiting ? "Waiting on you" : "Spend today"), kind: kind)
                AmpRule()
                Text("Stale")
                    .font(AmpTheme.body(11, weight: .medium))
                    .foregroundStyle(AmpTheme.parchmentDim)
                face(.accessoryRectangular, kind: kind, glance: nil, id: "face-stale")
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Faces")
        .accessibilityIdentifier(kind == .awaiting ? "glance" : "glance-spend")
    }

    private func section(_ title: String, kind: GlanceKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AmpTheme.body(11, weight: .medium))
                .foregroundStyle(AmpTheme.parchmentDim)
            HStack(alignment: .top, spacing: 8) {
                face(.accessoryCircular, kind: kind, glance: glance)
                face(.accessoryRectangular, kind: kind, glance: glance)
            }
            face(.accessoryInline, kind: kind, glance: glance)
        }
    }

    private func face(_ family: WidgetFamily, kind: GlanceKind, glance: Glance?, id: String? = nil) -> some View {
        GlanceView(kind: kind, family: family, glance: glance, now: amp.now(), identifier: id)
            .foregroundStyle(AmpTheme.parchment)
            .padding(family == .accessoryCircular ? 4 : 6)
            .frame(width: family == .accessoryCircular ? 54 : nil, height: family == .accessoryCircular ? 54 : nil)
            .frame(maxWidth: family == .accessoryCircular ? nil : .infinity, alignment: .leading)
            .background(AmpTheme.surface, in: family == .accessoryCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
    }
}
