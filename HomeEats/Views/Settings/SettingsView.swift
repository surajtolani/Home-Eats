import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]

    @State private var reminderTime: Date = Calendar.current.date(
        from: DateComponents(hour: 18, minute: 0)
    ) ?? .now

    private var settings: AppSettings {
        if let existing = settingsRows.first { return existing }
        let created = AppSettings()
        modelContext.insert(created)
        return created
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
                        Task { await NotificationScheduler.reschedule(using: settings) }
                    }
                ))

                if settings.reminderEnabled {
                    Picker("Day", selection: Binding(
                        get: { settings.reminderWeekday },
                        set: { newValue in
                            settings.reminderWeekday = newValue
                            Task { await NotificationScheduler.reschedule(using: settings) }
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
                        Task { await NotificationScheduler.reschedule(using: settings) }
                    }
                }
            } header: {
                Text("Planning Reminder")
            } footer: {
                Text("We'll send a notification to start planning the week's meals and eating-out nights.")
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
        .onAppear {
            reminderTime = Calendar.current.date(
                from: DateComponents(hour: settings.reminderHour, minute: settings.reminderMinute)
            ) ?? .now
        }
    }
}
