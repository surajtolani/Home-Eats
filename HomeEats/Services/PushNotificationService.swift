import Foundation
import UIKit

/// Real push notifications (APNs) — a banner on the phone even when Home
/// Eats isn't open — for things that happen to you from outside the app: a
/// friend request, a group invite. Direct user request: until now the only
/// "notification" this app ever produced was `NotificationScheduler`'s
/// local, on-device weekly planning reminder; anything from another person
/// only ever showed up in the in-app Notifications feed (`GET
/// /notifications`, `NotificationsSession`), never as an actual phone
/// notification, which meant it was easy to miss entirely unless someone
/// happened to open the app and look.
///
/// Three steps, run from `HomeEatsApp`'s own `.task` at launch (unconditionally,
/// same "ask once, up front" pattern `scheduleReminderIfConfigured()` right
/// next to it already uses for the local reminder) and again from
/// `AccountSession.completeSignIn` right after signing in:
/// 1. `requestAuthorizationAndRegisterForRemoteNotifications()` — asks
///    permission (the same system prompt `NotificationScheduler
///    .requestAuthorizationIfNeeded()` already uses for the local reminder;
///    one OS-level permission covers both local and remote notifications,
///    so this doesn't show a second, separate prompt), then calls
///    `UIApplication.shared.registerForRemoteNotifications()`.
/// 2. The actual device token arrives asynchronously from APNs, handed to
///    `didReceiveDeviceToken(_:)` by `HomeEatsAppDelegate
///    .application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` —
///    there's no SwiftUI-native hook for this callback, which is the one
///    reason this app has a `UIApplicationDelegate` at all (see that
///    type's own doc comment).
/// 3. Once both a token and a signed-in account exist,
///    `registerWithBackendIfPossible()` sends it to the backend
///    (`AccountsAPIClient.registerDeviceToken`, `POST /me/device-token`) so
///    the backend knows where to actually deliver a push for this user.
///    Called from both places a missing piece could just have arrived (a
///    fresh token, or a fresh sign-in) rather than tracked with a single
///    "ready" flag — simpler, and idempotent either way (re-registering the
///    same token is a harmless no-op server-side).
///
/// **Real delivery still needs server-side APNs credentials this client
/// can't provide** — a Team ID, Key ID, and `.p8` Auth Key from an Apple
/// Developer account, configured as env vars on the backend deployment —
/// see backend/lib/apns.js's own doc comment. Until those are set,
/// everything above still works end to end (permission, registration,
/// token upload); there's just nothing on the other end to actually send a
/// push yet.
@MainActor
enum PushNotificationService {
    private(set) static var deviceToken: String?

    static func requestAuthorizationAndRegisterForRemoteNotifications() async {
        guard await NotificationScheduler.requestAuthorizationIfNeeded() else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called by `HomeEatsAppDelegate` the moment APNs hands back a real
    /// token. Hex-encoded (`"a1b2c3..."`) — the shape `POST
    /// /me/device-token` (and every APNs client library) expects, not the
    /// raw `Data` APNs itself hands over.
    static func didReceiveDeviceToken(_ tokenData: Data) {
        deviceToken = tokenData.map { String(format: "%02x", $0) }.joined()
        Task { await registerWithBackendIfPossible() }
    }

    /// Safe to call any time (app launch, right after sign-in, right after
    /// a fresh token arrives) — a silent no-op if either piece isn't ready
    /// yet. `AccountsAPIClient.registerDeviceToken`'s own `sendRaw` throws
    /// `.unauthorized` when there's no stored sign-in token, swallowed here
    /// the same way a background sync failure is elsewhere in this app —
    /// nothing the user directly tapped triggered this, so there's no
    /// inline error UI to show for it either.
    static func registerWithBackendIfPossible() async {
        guard let deviceToken else { return }
        try? await AccountsAPIClient.registerDeviceToken(deviceToken)
    }
}
