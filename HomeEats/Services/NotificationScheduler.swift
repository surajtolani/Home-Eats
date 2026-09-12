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

    // MARK: - Grocery run reminders (recurring, possibly several a week)

    private static let groceryReminderPrefix = "grocery-reminder-"

    /// Cancels every previously-scheduled grocery reminder and re-schedules
    /// one repeating notification per enabled `GroceryReminder` row.
    /// Cancel-then-recreate-all (rather than diffing what changed) mirrors
    /// `reschedule(using:)` above and is simplest to keep correct: it's fine
    /// to call this on every add/edit/remove/toggle.
    static func rescheduleGroceryReminders(_ reminders: [GroceryReminder]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let staleIdentifiers = pending.map(\.identifier).filter { $0.hasPrefix(groceryReminderPrefix) }
        if !staleIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }

        let enabledReminders = reminders.filter(\.isEnabled)
        guard !enabledReminders.isEmpty else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        for reminder in enabledReminders {
            let content = UNMutableNotificationContent()
            content.title = "Grocery run reminder 🛒"
            content.body = "Time to check the grocery list and shop or order for the week."
            content.sound = .default

            var dateComponents = DateComponents()
            dateComponents.weekday = reminder.weekday
            dateComponents.hour = reminder.hour
            dateComponents.minute = reminder.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(
                identifier: groceryReminderPrefix + reminder.id.uuidString,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    // MARK: - One-time "place your order" reminder

    /// Schedules (replacing any previous one for this meal) a one-time
    /// notification at `date` for an order-in meal. Returns whether it was
    /// actually scheduled — `false` typically means notification
    /// permission was denied, which the caller surfaces so the reminder
    /// doesn't silently fail to fire.
    @discardableResult
    static func scheduleOrderReminder(for meal: PlannedMeal, at date: Date, restaurantName: String) async -> Bool {
        cancelOrderReminder(for: meal)
        guard await requestAuthorizationIfNeeded() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Time to order! 🥡"
        content.body = "Don't forget to place your \(restaurantName) order."
        content.sound = .default

        let triggerComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: orderReminderIdentifier(for: meal),
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    static func cancelOrderReminder(for meal: PlannedMeal) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [orderReminderIdentifier(for: meal)])
    }

    private static func orderReminderIdentifier(for meal: PlannedMeal) -> String {
        "order-reminder-\(meal.id.uuidString)"
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
