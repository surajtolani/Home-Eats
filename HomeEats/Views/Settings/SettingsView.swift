import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @Query private var settingsRows: [AppSettings]
    @Query(sort: \GroceryReminder.createdAt) private var groceryReminders: [GroceryReminder]
    // Unfiltered — same "fetch everything, filter `syncState` in Swift"
    // caution as `GroupSyncService`'s own local fetches (see its doc
    // comments) — used only to decide whether to show the sign-out warning
    // below, not for display.
    @Query private var groupPlannedMeals: [GroupPlannedMeal]
    @Query private var groupMealSuggestions: [GroupMealSuggestion]
    @Query private var groupGroceryItems: [GroupSharedGroceryItem]

    @State private var reminderTime: Date = Calendar.current.date(
        from: DateComponents(hour: 18, minute: 0)
    ) ?? .now
    @State private var showSignIn = false
    @State private var showUnsyncedSignOutWarning = false

    /// Whether any group-sync row is still waiting to reach the server —
    /// used only to decide whether signing out needs a confirmation first;
    /// see `GroupSyncService.purgeAllLocalGroupData`'s doc comment for why
    /// sign-out purges these rows unconditionally regardless of this check.
    private var hasUnsyncedGroupChanges: Bool {
        groupPlannedMeals.contains { $0.syncState != .synced }
            || groupMealSuggestions.contains { $0.syncState != .synced }
            || groupGroceryItems.contains { $0.syncState != .synced }
    }

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
            // Account sign-in is entirely opt-in — see AccountSession's doc
            // comment and backend/README.md's "Accounts, friends, and
            // groups" section. Nothing else in this app has ever required
            // signing in, and nothing outside recipe-sharing does now
            // either; this section is just the front door for the people
            // who *do* want to add friends, build groups, or share a
            // recipe with someone.
            Section("Account") {
                if accountSession.isSignedIn, let user = accountSession.currentUser {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayNameOrPhoneNumber)
                            .font(.brandHeadline)
                        // Only show the phone number as a subtitle when
                        // there's an actual name above it to distinguish it
                        // from — otherwise `displayNameOrPhoneNumber`
                        // already fell back to showing it up top, and
                        // repeating it here would just be the same string
                        // twice.
                        if user.displayName?.isEmpty == false {
                            Text(user.phoneNumber)
                                .font(.brandCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        FriendsListView()
                    } label: {
                        Label("Friends", systemImage: "person.2")
                    }
                    NavigationLink {
                        GroupsListView()
                    } label: {
                        Label("Groups", systemImage: "person.3")
                    }
                    Button("Sign Out", role: .destructive) {
                        // Signing out purges every locally-cached group-sync
                        // row unconditionally, pending or not — see
                        // `GroupSyncService.purgeAllLocalGroupData`'s doc
                        // comment for why. Warn first if that would actually
                        // lose something, so a genuinely offline edit isn't
                        // silently dropped with no chance to notice.
                        if hasUnsyncedGroupChanges {
                            showUnsyncedSignOutWarning = true
                        } else {
                            accountSession.signOut()
                        }
                    }
                } else if accountSession.isSignedIn {
                    // A token is stored but GET /me hasn't resolved yet
                    // (see AccountSession.init) — a brief state right after
                    // launch, not worth its own error handling.
                    HStack {
                        ProgressView()
                        Text("Loading your account…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Sign In") { showSignIn = true }
                }
            } footer: {
                Text("Sign in with your phone number to add friends, build groups, and share recipes with them. Everything else in Home Eats works fully offline without an account.")
            }

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
        .sheet(isPresented: $showSignIn) {
            AccountSignInView()
        }
        .confirmationDialog(
            "You have unsynced changes",
            isPresented: $showUnsyncedSignOutWarning,
            titleVisibility: .visible
        ) {
            Button("Sign Out Anyway", role: .destructive) {
                accountSession.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some group meal-plan or grocery-list changes haven't synced yet. Signing out now will lose them.")
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
