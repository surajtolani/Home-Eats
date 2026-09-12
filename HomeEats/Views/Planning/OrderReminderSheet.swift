import SwiftUI

/// Presented immediately after picking a restaurant for "Order In" — the
/// whole point of ordering in is usually placing the order by some specific
/// time, easy to forget once the day gets busy, so this offers to set a
/// one-time reminder right then rather than requiring a separate trip to
/// find and edit the meal afterward.
struct OrderReminderSheet: View {
    @Bindable var meal: PlannedMeal
    let restaurant: Restaurant

    @Environment(\.dismiss) private var dismiss
    @State private var reminderDate: Date
    @State private var permissionDenied = false

    init(meal: PlannedMeal, restaurant: Restaurant) {
        self.meal = meal
        self.restaurant = restaurant
        // Defaults to this meal's day at a reasonable "place the order"
        // time rather than the exact current moment, which would often
        // already be in the past by the time someone's picking a dinner
        // option earlier in the day.
        let calendar = Calendar.current
        let defaultTime = calendar.date(
            bySettingHour: 17, minute: 0, second: 0, of: meal.date
        ) ?? meal.date
        _reminderDate = State(initialValue: defaultTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Remind me at",
                        selection: $reminderDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } footer: {
                    if permissionDenied {
                        Text("Notifications are turned off for Home Eats — enable them in the Settings app to get this reminder.")
                            .foregroundStyle(.red)
                    } else {
                        Text("We'll send a one-time notification so ordering from \(restaurant.name) doesn't get forgotten.")
                    }
                }
            }
            .navigationTitle("Set a Reminder?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Reminder") {
                        Task { await setReminder() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func setReminder() async {
        let scheduled = await NotificationScheduler.scheduleOrderReminder(
            for: meal,
            at: reminderDate,
            restaurantName: restaurant.name
        )
        guard scheduled else {
            permissionDenied = true
            return
        }
        meal.orderReminderDate = reminderDate
        dismiss()
    }
}
