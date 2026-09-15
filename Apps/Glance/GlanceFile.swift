import Foundation
import AmpKit

/// Where the app leaves the glance and the widget picks it up. One definition,
/// compiled into both targets, so the two can never disagree on the path.
enum GlanceFile {
    /// Declared in both entitlements files. With automatic signing Xcode
    /// registers the group on the developer account; CI builds unsigned.
    static let appGroup = "group.com.soll.ampwatch"
    static let name = "glance.json"

    /// `nil` on a build without the app-group entitlement.
    static var shared: GlanceStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { GlanceStore(fileURL: $0.appendingPathComponent(name)) }
    }
}
