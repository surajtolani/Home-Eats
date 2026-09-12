import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]
    @Query(sort: \GroceryReminder.createdAt) private var groceryReminders: [GroceryReminder]

    @State private var reminderTime: Date = Calendar.current.date(
        from: DateComponents(hour: 18, minute: 0)
    ) ?? .now

    // `settings` is read several times per `body` pass (the toggle, the day
    // picker, the reminder-time handler...). Inserting a new row from inside
    // it — as this used to do — mutates the model context, and therefore
    // `@Query settingsRows`, in the middle of that same body evaluation:
    // exactly the "modifying state during view update" pattern that's
    // caused real bugs elsewhere in this app. `SampleDataSeeder` already
    // guarantees this row exists at launch, so in practice `settingsRows`
    // is never actually empty here — `ensureSettingsExist()` (run from
    // `.task`, a safe point to mutate state) is just a backstop for the
    // unlikely case that seeding failed; `settings` itself only ever reads.
    private var settings: AppSettings {
        settingsRows.first ?? AppSettings()
    }

    private func ensureSettingsExist() {
        guard settingsRows.isEmpty else { return }
        modelContext.insert(AppSettings())
    }

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    var body: some View {
        Form {
            Section("Household") {
                TextField("Household name", text: Binding(
                    get: { settings.householdName },
                    set: { settings.householdName = $0 }
                ))
            }

            Section {
                Toggle("Weekly Planning Reminder", isOn: Binding(
                    get: { settings.reminderEnabled },
                    set: { newValue in
                        settings.reminderEnabled = newValue
                        Task { @MainActor in await NotificationScheduler.reschedule(using: settings) }
                    }
                ))

                if settings.reminderEnabled {
                    Picker("Day", selection: Binding(
                        get: { settings.reminderWeekday },
                        set: { newValue in
                            settings.reminderWeekday = newValue
                            Task { @MainActor in await NotificationScheduler.reschedule(using: settings) }
                        }
                    )) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(weekdaySymbols[weekday - 1]).tag(weekday)
                        }
                    }

                    DatePicker(
                        "Time",
                        selection: $reminderTime,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: reminderTime) { _, newValue in
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        settings.reminderHour = comps.hour ?? 18
                        settings.reminderMinute = comps.minute ?? 0
                        Task { @MainActor in await NotificationScheduler.reschedule(using: settings) }
                    }
                }
            } header: {
                Text("Planning Reminder")
            } footer: {
                Text("We'll send a notification to start planning the week's meals and eating-out nights.")
            }

            Section {
                if groceryReminders.isEmpty {
                    Text("No grocery reminders set.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groceryReminders) { reminder in
                    GroceryReminderRow(reminder: reminder, onChange: rescheduleGroceryReminders)
                }
                .onDelete { offsets in
                    for index in offsets { modelContext.delete(groceryReminders[index]) }
                    rescheduleGroceryReminders()
                }
                Button {
                    addGroceryReminder()
                } label: {
                    Label("Add a Reminder", systemImage: "plus")
                }
            } header: {
                Text("Grocery Reminders")
            } footer: {
                Text("Add one reminder for each time your family typically shops or orders groceries — some households do this more than once a week.")
            }

            Section {
                Toggle("iCloud Sync (coming soon)", isOn: Binding(
                    get: { settings.cloudSyncEnabled },
                    set: { settings.cloudSyncEnabled = $0 }
                ))
                .disabled(true)
            } footer: {
                Text("Home Eats stores everything on this device and works fully offline. Optional account sync across every family member's phone is planned for a later update.")
            }
        }
        .navigationTitle("Settings")
        .task {
            ensureSettingsExist()
            reminderTime = Calendar.current.date(
                from: DateComponents(hour: settings.reminderHour, minute: settings.reminderMinute)
            ) ?? .now
        }
    }

    private func addGroceryReminder() {
        modelContext.insert(GroceryReminder())
        rescheduleGroceryReminders()
    }

    private func rescheduleGroceryReminders() {
        Task { @MainActor in
            await NotificationScheduler.rescheduleGroceryReminders(groceryReminders)
        }
    }
}

/// One row of the "Grocery Reminders" section — an enabled toggle, a
/// weekday picker, and a time picker, all bound directly to one
/// `GroceryReminder`. Its own local `@State` for the time picker (mirroring
/// the single planning-reminder's `reminderTime` above) since `DatePicker`
/// needs a full `Date` to bind to, not separate hour/minute ints.
private struct GroceryReminderRow: View {
    @Bindable var reminder: GroceryReminder
    let onChange: () -> Void

    @State private var time: Date = .now

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { reminder.isEnabled },
                set: { reminder.isEnabled = $0; onChange() }
            )) {
                Text(reminder.isEnabled ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }

            if reminder.isEnabled {
                Picker("Day", selection: Binding(
                    get: { reminder.weekday },
                    set: { reminder.weekday = $0; onChange() }
                )) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }

                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .onChange(of: time) { _, newValue in
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        reminder.hour = comps.hour ?? reminder.hour
                        reminder.minute = comps.minute ?? reminder.minute
                        onChange()
                    }
            }
        }
        .padding(.vertical, 2)
        .task {
            time = reminder.timeAsDate
        }
    }
}
