import UIKit
import UserNotifications

/// The one reason this SwiftUI app has a `UIApplicationDelegate` at all:
/// APNs remote-notification registration
/// (`didRegisterForRemoteNotificationsWithDeviceToken`/
/// `didFailToRegisterForRemoteNotificationsWithError`) has no SwiftUI-native
/// equivalent — `@UIApplicationDelegateAdaptor`'d from `HomeEatsApp`. Also
/// doubles as the `UNUserNotificationCenterDelegate` so a push that arrives
/// while the app is already open still shows a banner (the system's default
/// foreground behavior is to show nothing at all) — the same delegate
/// object serves both roles since neither needs any other app state. See
/// `PushNotificationService`'s own doc comment for the fuller "why real
/// push notifications need this at all" story.
final class HomeEatsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationService.didReceiveDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on the iOS Simulator (no real APNs connection) and
        // whenever the device has no network — nothing actionable for the
        // user here, so this just logs rather than surfacing error UI for a
        // background registration step nobody directly triggered.
        print("Remote notification registration failed: \(error)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
