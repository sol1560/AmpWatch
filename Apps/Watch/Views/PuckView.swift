import SwiftUI
import AmpKit

/// An honest destination until Amp exposes a supported Puck connection.
struct PuckView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Not available on watch")
                    .font(AmpTheme.display(18))
                    .accessibilityIdentifier("puck-unavailable")
                Text("AmpWatch cannot talk to Puck. The current API and watch bridge do not provide a Puck connection.")
                AmpRule()
                Text("On your phone, open Amp’s sidebar and tap Puck. On the web, open Puck at ampcode.com.")
                Text("The + button on this watch creates a regular thread through the bridge, not a Puck conversation.")
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
            .font(AmpTheme.body(14))
            .foregroundStyle(AmpTheme.parchment)
            .padding(.horizontal, 8)
        }
        .navigationTitle("Puck")
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .accessibilityIdentifier("puck")
    }
}
