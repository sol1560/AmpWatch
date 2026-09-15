import SwiftUI
import WatchKit
import UserNotifications
import AmpKit

/// Registers the watch for pushes, keeps the device token for this launch,
/// and turns the buttons on a notification into commands.
///
/// It owns nothing about the session: `RootView` watches `deviceToken` and
/// `pendingCommand` and sends through whatever sink the session has. That
/// keeps the delegate free of credentials and keeps the send path in one place.
@MainActor
@Observable
final class PushRegistrar: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Lower-case hex token from the last successful registration this launch.
    private(set) var deviceToken: String?
    /// Why registration did not happen, for the settings screen.
    private(set) var registrationProblem: String?
    /// A command produced by a notification button; `RootView` drains it.
    var pendingCommand: WatchCommand?

    /// Xcode installs can only be reached through the sandbox gateway.
    static var environment: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    func applicationDidFinishLaunching() {
        // The screenshot harness runs without a session and must not prompt
        // for permission: a system alert would sit over every capture.
        guard ScreenshotScene.requested == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(PushCategory.allCases.map(Self.category)))
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if granted {
                    WKApplication.shared().registerForRemoteNotifications()
                } else {
                    registrationProblem = "Notifications are off for Amp in the Watch app."
                }
            } catch {
                registrationProblem = error.localizedDescription
            }
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        self.deviceToken = DeviceToken.hex(deviceToken)
        registrationProblem = nil
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: any Error) {
        registrationProblem = error.localizedDescription
    }

    private static func category(_ category: PushCategory) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: category.rawValue,
            actions: category.actions.map { action in
                UNNotificationAction(
                    identifier: action.identifier,
                    title: action.title,
                    options: action.isDestructive ? [.destructive] : []
                )
            },
            intentIdentifiers: [],
            options: []
        )
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The app being open is no reason to hide "your thread finished".
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
        let command = PushAction.command(actionIdentifier: response.actionIdentifier, payload: payload)
        guard let command else { return }
        await MainActor.run { pendingCommand = command }
    }
}
