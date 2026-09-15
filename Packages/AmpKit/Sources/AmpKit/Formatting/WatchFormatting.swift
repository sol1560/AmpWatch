import Foundation

/// Localized product copy owned by AmpKit. Server and user supplied text must
/// never pass through this helper.
public enum AmpStrings {
    public static func text(_ key: String, localeIdentifier: String? = nil) -> String {
        let bundle: Bundle
        if let localeIdentifier {
            let directory = "\(localeIdentifier.lowercased()).lproj"
            if let localized = Bundle(url: Bundle.module.bundleURL.appendingPathComponent(directory)) {
                bundle = localized
            } else {
                bundle = .module
            }
        } else {
            bundle = .module
        }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}

/// Compact relative timestamps sized for a watch row: at most three characters
/// plus a unit, never a sentence.
public enum RelativeTime {
    public static func short(from date: Date?, to now: Date) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return AmpStrings.text("relative.now") }
        if seconds < 60 { return AmpStrings.format("relative.seconds", Int(seconds)) }
        let minutes = seconds / 60
        if minutes < 60 { return AmpStrings.format("relative.minutes", Int(minutes)) }
        let hours = minutes / 60
        if hours < 24 { return AmpStrings.format("relative.hours", Int(hours)) }
        let days = hours / 24
        if days < 7 { return AmpStrings.format("relative.days", Int(days)) }
        return AmpStrings.format("relative.weeks", Int(days / 7))
    }
}

/// Thread cost, rendered to the precision that is actually meaningful at that
/// magnitude: sub-dollar amounts need cents, large amounts do not.
public enum Money {
    public static func compact(usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 0.01 { return "<$0.01" }
        if usd < 10 { return String(format: "$%.2f", usd) }
        if usd < 1000 { return String(format: "$%.0f", usd) }
        return String(format: "$%.1fk", usd / 1000)
    }
}

/// Token counts, which routinely run into the millions and must not wrap.
public enum TokenCount {
    public static func compact(_ value: Double) -> String {
        let count = max(0, value)
        if count < 1000 { return String(Int(count)) }
        if count < 1_000_000 { return String(format: "%.1fk", count / 1000) }
        return String(format: "%.1fM", count / 1_000_000)
    }
}
