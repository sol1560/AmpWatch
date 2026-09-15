import SwiftUI
import AmpKit

/// Amp's visual language, translated to a 40mm screen.
///
/// Sampled from ampcode.com: a deep desaturated green-charcoal ground, warm
/// parchment type, one saturated ember accent, and hairline rules. The web site
/// pairs an editorial serif for display type with a plain sans for body copy;
/// `display` reproduces that with SF Serif rather than shipping a font binary,
/// which keeps the watch app under its asset budget and keeps Dynamic Type
/// working.
///
/// The canvas is pure black rather than Amp's `#10201c` because on an OLED
/// watch a near-black fill is visibly lit in a dark room and costs battery in
/// always-on mode. The Amp ground survives as `surface`.
enum AmpTheme {
    static let canvas = Color.black
    static let surface = Color(red: 0.071, green: 0.102, blue: 0.090)   // #121A17
    static let parchment = Color(red: 0.875, green: 0.875, blue: 0.757) // #DFDFC1
    static let parchmentDim = Color(red: 0.675, green: 0.678, blue: 0.600) // #ACAD99
    static let ember = Color(red: 0.957, green: 0.482, blue: 0.208)     // #F47B35
    static let rule = Color.white.opacity(0.12)

    /// The accent for anything that is not a blocked thread.
    ///
    /// In always-on mode (`isLuminanceReduced`) the face is dimmed and lit for
    /// hours; a saturated fill there is the brightest thing in the room and
    /// costs battery for nothing the wearer is looking at. Ember survives only
    /// on the approval screen, where a thread is actually waiting on a human.
    static func accent(dimmed: Bool) -> Color {
        dimmed ? parchment : ember
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension ThreadActivity {
    func tint(dimmed: Bool = false) -> Color {
        switch self {
        case .live: AmpTheme.accent(dimmed: dimmed)
        case .recent: AmpTheme.parchment
        case .dormant, .unknown: AmpTheme.parchmentDim
        }
    }

    /// Wording that stays honest about what this value measures: recency of
    /// change, not a run state reported by the agent.
    var label: String {
        switch self {
        case .live: "moving"
        case .recent: "just quiet"
        case .dormant: "quiet"
        case .unknown: "unknown"
        }
    }
}

/// The hairline rule Amp uses to separate everything.
struct AmpRule: View {
    var body: some View {
        Rectangle()
            .fill(AmpTheme.rule)
            .frame(height: 1)
    }
}

/// A filled dot for `.live`, a hollow ring otherwise — so activity survives
/// greyscale always-on rendering and colour-blind vision, not just the tint.
struct ActivityDot: View {
    let activity: ThreadActivity
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        Group {
            if activity == .live {
                Circle().fill(activity.tint(dimmed: dimmed))
            } else {
                Circle().strokeBorder(activity.tint(dimmed: dimmed), lineWidth: 1.5)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(activity.label)
    }
}

/// `.tint(AmpTheme.ember)` that steps down to parchment in always-on mode.
/// For the buttons and links that are prominent by design (Send, Start,
/// Stop, Reply): they stay findable, they stop glowing.
struct AmpAccent: ViewModifier {
    @Environment(\.isLuminanceReduced) private var dimmed

    func body(content: Content) -> some View {
        content.tint(AmpTheme.accent(dimmed: dimmed))
    }
}

extension View {
    func ampAccent() -> some View {
        modifier(AmpAccent())
    }
}
