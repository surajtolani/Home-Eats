import Foundation
import UserNotifications
import SwiftUI

/// Schedules the weekly "plan your meals" reminder described in the spec.
/// The day/time is fully configurable (see `AppSettings`); tapping the
/// notification opens the app straight into the planning flow via
/// `PlanningReminderRouter`.
enum NotificationScheduler {
    static let weeklyReminderIdentifier = "weekly-planning-reminder"
    static let categoryIdentifier = "PLANNING_REMINDER"

    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Cancels and re-schedules the weekly reminder to match the given settings.
    static func reschedule(using settings: AppSettings) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [weeklyReminderIdentifier])

        guard settings.reminderEnabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Plan this week's meals 🍽️"
        content.body = "It's time to line up dinners (and eating-out nights) for the week ahead."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        var dateComponents = DateComponents()
        dateComponents.weekday = settings.reminderWeekday
        dateComponents.hour = settings.reminderHour
        dateComponents.minute = settings.reminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(
            identifier: weeklyReminderIdentifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    static func registerCategories() {
        let planNow = UNNotificationAction(
            identifier: "PLAN_NOW",
            title: "Start Planning",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [planNow],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// Bridges notification taps into SwiftUI navigation: when the weekly
/// reminder (or its "Start Planning" action) is triggered, this flips a flag
/// that the root view observes to jump straight to the planning flow.
@MainActor
final class PlanningReminderRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var shouldPresentPlanningFlow = false

    func install() {
        UNUserNotificationCenter.current().delegate = self
        NotificationScheduler.registerCategories()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == NotificationScheduler.weeklyReminderIdentifier else {
            return
        }
        await MainActor.run {
            shouldPresentPlanningFlow = true
        }
    }
}
